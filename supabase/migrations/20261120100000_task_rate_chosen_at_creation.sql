alter table public.tasks
  add column if not exists settlement_fx_conversion_id uuid references public.books_fx_conversions(id) on delete restrict;

alter table public.tasks drop constraint if exists tasks_settlement_rate_check;
alter table public.tasks
  add constraint tasks_settlement_rate_check check (
    (settlement_fx_rate is null and settlement_fx_rate_source is null)
    or (
      settlement_fx_rate is not null and settlement_fx_rate > 0
      and settlement_fx_rate_source in ('same_currency', 'stored', 'manual', 'hotel_approved', 'hotel_edited', 'books_exchange')
    )
  );

alter table public.tasks drop constraint if exists tasks_settlement_exchange_link_check;
alter table public.tasks
  add constraint tasks_settlement_exchange_link_check check (
    settlement_fx_rate_source <> 'books_exchange' or settlement_fx_conversion_id is not null
  );

alter table public.worker_task_invoices drop constraint if exists worker_task_invoices_fx_rate_source_check;
alter table public.worker_task_invoices
  add constraint worker_task_invoices_fx_rate_source_check
  check (fx_rate_source in ('same_currency', 'stored', 'manual', 'hotel_approved', 'hotel_edited', 'books_exchange'));

alter table public.worker_task_payments drop constraint if exists worker_task_payments_fx_rate_source_check;
alter table public.worker_task_payments
  add constraint worker_task_payments_fx_rate_source_check
  check (fx_rate_source in ('same_currency', 'stored', 'manual', 'hotel_approved', 'hotel_edited', 'books_exchange'));

create or replace function public.resolve_task_settlement()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  fx_row record;
  conversion_row public.books_fx_conversions%rowtype;
  is_hotel_manager boolean;
begin
  if tg_op = 'UPDATE' then
    if exists (select 1 from public.worker_task_invoices where task_id = new.id) then
      raise exception 'Settlement terms cannot change after the task invoice is created';
    end if;
    if pg_trigger_depth() > 1 then return new; end if;
  end if;

  new.settlement_currency_code := coalesce(new.settlement_currency_code, new.currency_code);

  if new.settlement_currency_code = new.currency_code then
    new.settlement_fx_rate := 1;
    new.settlement_fx_rate_source := 'same_currency';
    new.settlement_fx_rate_fetched_at := null;
    new.settlement_fx_conversion_id := null;
    return new;
  end if;

  if new.settlement_currency_code not in ('UGX', 'USD') then
    raise exception 'Settlement currency must be UGX or USD, or the task currency';
  end if;

  if new.settlement_fx_rate_source in ('hotel_approved', 'hotel_edited', 'books_exchange') then
    select exists (
      select 1
        from public.user_profiles profile
        join public.books_memberships membership on membership.user_id = profile.user_id
       where profile.user_id = auth.uid()
         and profile.role = 'manager'
         and membership.organization_id = new.organization_id
    ) into is_hotel_manager;
    if not is_hotel_manager then
      raise exception 'Only the hotel manager can approve or edit the settlement rate';
    end if;
  end if;

  if new.settlement_fx_rate_source = 'books_exchange' then
    select * into conversion_row from public.books_fx_conversions where id = new.settlement_fx_conversion_id;
    if not found or conversion_row.organization_id <> new.organization_id then
      raise exception 'Currency exchange not found for this hotel';
    end if;
    if conversion_row.from_currency_code <> new.currency_code or new.settlement_currency_code <> 'UGX' then
      raise exception 'A currency exchange can only set a rate from the task currency to UGX';
    end if;
    new.settlement_fx_rate := round(conversion_row.to_ugx_amount / conversion_row.from_amount, 8);
    new.settlement_fx_rate_fetched_at := conversion_row.exchange_at;
    return new;
  end if;

  select * into fx_row
    from public.books_task_payment_fx_rate(new.currency_code::char(3), new.settlement_currency_code::char(3));

  if new.settlement_fx_rate_source = 'hotel_edited' then
    if coalesce(new.settlement_fx_rate, 0) <= 0 then
      raise exception 'Edited settlement rate must be greater than zero';
    end if;
    new.settlement_fx_rate_fetched_at := fx_row.rate_fetched_at;
    new.settlement_fx_conversion_id := null;
  else
    if fx_row.rate_status <> 'stored' then
      raise exception 'FX_RATE_UNAVAILABLE: No current stored % to % rate exists. Refresh the exchange rates and try again.', new.currency_code, new.settlement_currency_code;
    end if;
    new.settlement_fx_rate := fx_row.fx_rate;
    new.settlement_fx_rate_fetched_at := fx_row.rate_fetched_at;
    new.settlement_fx_conversion_id := null;
    new.settlement_fx_rate_source := case
      when new.settlement_fx_rate_source = 'hotel_approved' then 'hotel_approved'
      else 'stored'
    end;
  end if;

  return new;
end;
$$;

alter table public.task_responses
  add column if not exists accepted_settlement_fx_rate numeric(20,8),
  add column if not exists accepted_settlement_fx_rate_source text;

create or replace function public.record_task_acceptance_rate()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
begin
  if new.action <> 'accept' then return new; end if;

  select * into task_row from public.tasks where id = new.task_id;
  if found and task_row.settlement_currency_code <> task_row.currency_code then
    new.accepted_settlement_fx_rate := task_row.settlement_fx_rate;
    new.accepted_settlement_fx_rate_source := task_row.settlement_fx_rate_source;
  end if;
  return new;
end;
$$;

drop trigger if exists record_task_acceptance_rate on public.task_responses;
create trigger record_task_acceptance_rate
  before insert on public.task_responses
  for each row execute function public.record_task_acceptance_rate();

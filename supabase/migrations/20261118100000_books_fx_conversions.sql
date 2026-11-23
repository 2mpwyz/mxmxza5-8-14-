create or replace function public.assert_books_journal_balanced()
returns trigger language plpgsql set search_path = public
as $$
declare difference numeric;
begin
  select coalesce(sum(round((debit - credit) * exchange_rate, 4)), 0) into difference
  from public.books_journal_lines where transaction_id = new.transaction_id;
  if difference <> 0 then raise exception 'Journal transaction must balance debits and credits'; end if;
  return new;
end; $$;

create table if not exists public.books_fx_conversions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.books_organizations(id) on delete cascade,
  conversion_date date not null default current_date,
  from_currency_code text not null check (from_currency_code ~ '^[A-Z]{3}$' and from_currency_code <> 'UGX'),
  from_amount numeric(20,4) not null check (from_amount > 0),
  to_ugx_amount numeric(20,4) not null check (to_ugx_amount > 0),
  carrying_ugx_per_unit numeric(20,8) not null check (carrying_ugx_per_unit > 0),
  realized_fx_difference numeric(20,4) not null,
  provider text,
  reference text,
  journal_transaction_id uuid not null unique references public.books_journal_transactions(id) on delete restrict,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.books_fx_conversions enable row level security;

drop policy if exists books_fx_conversions_member on public.books_fx_conversions;
create policy books_fx_conversions_member on public.books_fx_conversions for select
  using (organization_id in (select public.user_books_organization_ids()));

drop trigger if exists books_fx_conversions_immutable on public.books_fx_conversions;
create trigger books_fx_conversions_immutable before update or delete on public.books_fx_conversions
for each row execute function public.prevent_books_journal_mutation();

create or replace function public.record_books_fx_conversion(
  p_organization_id uuid,
  p_conversion_date date,
  p_from_currency_code text,
  p_from_amount numeric,
  p_to_ugx_amount numeric,
  p_carrying_ugx_per_unit numeric,
  p_provider text,
  p_reference text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  from_currency text := upper(trim(p_from_currency_code));
  from_amount numeric(20,4) := round(p_from_amount, 4);
  to_amount numeric(20,4) := round(p_to_ugx_amount, 4);
  carrying_rate numeric(20,8) := round(p_carrying_ugx_per_unit, 8);
  carried_ugx numeric(20,4);
  gain_loss numeric(20,4);
  cash_account_id uuid;
  gain_account_id uuid;
  loss_account_id uuid;
  journal_id uuid;
  conversion_id uuid := gen_random_uuid();
  reference_text text := nullif(trim(p_reference), '');
begin
  if auth.uid() is null then raise exception 'Sign in to record currency exchanges'; end if;
  if p_organization_id is null
     or not public.hotel_user_manages_organization(p_organization_id, auth.uid()) then
    raise exception 'Only this hotel''s manager can record currency exchanges';
  end if;
  if from_currency !~ '^[A-Z]{3}$' or from_currency = 'UGX' then
    raise exception 'Choose the foreign currency exchanged from';
  end if;
  if from_amount <= 0 or to_amount <= 0 then raise exception 'Exchange amounts must be greater than zero'; end if;
  if carrying_rate is null or carrying_rate <= 0 then
    raise exception 'Enter the UGX value per unit of the foreign currency given up';
  end if;

  select id into cash_account_id from public.books_accounts
   where organization_id = p_organization_id and code = '1000';
  if cash_account_id is null then raise exception 'Cash and bank account 1000 is missing'; end if;

  insert into public.books_accounts (organization_id, code, name, type, is_system) values
    (p_organization_id, '4900', 'Exchange gains', 'income', true),
    (p_organization_id, '5900', 'Exchange losses', 'expense', true)
  on conflict (organization_id, code) do nothing;

  select id into gain_account_id from public.books_accounts where organization_id = p_organization_id and code = '4900';
  select id into loss_account_id from public.books_accounts where organization_id = p_organization_id and code = '5900';

  carried_ugx := round(from_amount * carrying_rate, 4);
  gain_loss := round(to_amount - carried_ugx, 4);

  insert into public.books_journal_transactions (
    organization_id, source_type, source_id, transaction_date, description, created_by
  ) values (
    p_organization_id, 'fx_conversion', conversion_id, coalesce(p_conversion_date, current_date),
    'Currency exchange ' || from_currency || ' to UGX' || coalesce(': ' || reference_text, ''),
    auth.uid()
  )
  returning id into journal_id;

  insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate) values
    (journal_id, cash_account_id, to_amount, 0, 'UGX', 1),
    (journal_id, cash_account_id, 0, from_amount, from_currency, carrying_rate);

  if gain_loss > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, gain_account_id, 0, gain_loss, 'UGX', 1);
  elsif gain_loss < 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, loss_account_id, -gain_loss, 0, 'UGX', 1);
  end if;

  insert into public.books_fx_conversions (
    id, organization_id, conversion_date, from_currency_code, from_amount, to_ugx_amount,
    carrying_ugx_per_unit, realized_fx_difference, provider, reference, journal_transaction_id, created_by
  ) values (
    conversion_id, p_organization_id, coalesce(p_conversion_date, current_date), from_currency, from_amount, to_amount,
    carrying_rate, gain_loss, nullif(trim(p_provider), ''), reference_text, journal_id, auth.uid()
  );

  return conversion_id;
end;
$function$;

revoke all on function public.record_books_fx_conversion(uuid, date, text, numeric, numeric, numeric, text, text) from public, anon;
grant execute on function public.record_books_fx_conversion(uuid, date, text, numeric, numeric, numeric, text, text) to authenticated;

alter table public.worker_task_payments
  add column if not exists hotel_fx_conversion_id uuid references public.books_fx_conversions(id) on delete restrict;

drop function if exists public.record_worker_task_payment(uuid, text, text);

create or replace function public.record_worker_task_payment(
  p_task_id uuid,
  p_payment_method text,
  p_payment_reference text,
  p_fx_conversion_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  task_row public.tasks%rowtype;
  invoice_row public.books_invoices%rowtype;
  invoice_link public.worker_task_invoices%rowtype;
  conversion_row public.books_fx_conversions%rowtype;
  worker_user_id uuid;
  worker_name text;
  hotel_vat_registered boolean;
  reference_text text := nullif(trim(p_payment_reference), '');
  payment_id uuid;
  expense_id uuid;
  worker_contact_id uuid;
  hotel_recoverable boolean;
begin
  if auth.uid() is null then raise exception 'Sign in to record payments'; end if;
  if reference_text is null then raise exception 'A payment reference is required'; end if;

  select * into task_row from public.tasks where id = p_task_id for update;
  if not found then raise exception 'Task not found'; end if;
  if task_row.organization_id is null
     or not public.hotel_user_manages_organization(task_row.organization_id, auth.uid()) then
    raise exception 'Only this hotel''s manager can record task payments';
  end if;
  if task_row.status <> 'completed' then raise exception 'Task must be approved before payment'; end if;
  if not exists (
    select 1 from public.task_reports report
     where report.task_id = task_row.id and report.status = 'approved'
  ) then
    raise exception 'Task report must be approved before payment';
  end if;
  if task_row.final_amount is null or task_row.final_amount <= 0 then
    raise exception 'Task has no agreed amount';
  end if;
  if task_row.assigned_to is null then raise exception 'Task has no assigned worker'; end if;
  if exists (select 1 from public.worker_task_payments where task_id = task_row.id) then
    raise exception 'Payment is already recorded for this task';
  end if;

  select profile.user_id,
         coalesce(nullif(trim(concat_ws(' ', profile.first_name, profile.last_name)), ''), 'Worker')
    into worker_user_id, worker_name
    from public.user_profiles profile where profile.id = task_row.assigned_to;
  if worker_user_id is null then raise exception 'Assigned worker profile not found'; end if;

  select organization.vat_registered into hotel_vat_registered
    from public.books_organizations organization where organization.id = task_row.organization_id;

  perform public.create_worker_task_invoice(task_row.id, null);
  select * into invoice_link from public.worker_task_invoices where task_id = task_row.id;
  select * into invoice_row from public.books_invoices where id = invoice_link.invoice_id for update;
  if invoice_row.status not in ('sent', 'overdue') then raise exception 'Task invoice is not open for payment'; end if;

  if p_fx_conversion_id is not null then
    select * into conversion_row from public.books_fx_conversions where id = p_fx_conversion_id;
    if not found or conversion_row.organization_id <> task_row.organization_id then
      raise exception 'Currency exchange not found for this hotel';
    end if;
    if conversion_row.from_currency_code <> invoice_link.hotel_currency_code then
      raise exception 'Currency exchange must convert from the task currency';
    end if;
    if invoice_link.worker_currency_code <> 'UGX' then
      raise exception 'Currency exchanges can only fund payments made in UGX';
    end if;
  end if;

  insert into public.worker_task_payments (
    task_id, hotel_organization_id, worker_user_id, amount, tax_amount, currency_code,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at,
    converted_amount, converted_tax_amount, payment_method, payment_reference,
    recorded_by, confirmation_status, hotel_fx_conversion_id
  ) values (
    task_row.id, task_row.organization_id, worker_user_id, task_row.final_amount, invoice_link.hotel_tax_amount, invoice_link.hotel_currency_code,
    invoice_link.worker_currency_code, invoice_link.fx_rate, invoice_link.fx_rate_source, invoice_link.fx_rate_fetched_at,
    invoice_row.total, invoice_row.tax_amount, p_payment_method, reference_text,
    auth.uid(), 'pending_confirmation', p_fx_conversion_id
  )
  returning id into payment_id;

  select contact.id into worker_contact_id
    from public.books_contacts contact
   where contact.organization_id = task_row.organization_id
     and contact.name = worker_name
     and contact.type in ('vendor', 'both')
   limit 1;
  if worker_contact_id is null then
    insert into public.books_contacts (organization_id, name, type)
    values (task_row.organization_id, worker_name, 'vendor')
    returning id into worker_contact_id;
  end if;

  hotel_recoverable := coalesce(hotel_vat_registered, false) and invoice_link.hotel_tax_amount > 0;
  if hotel_recoverable then
    insert into public.books_accounts (organization_id, code, name, type, is_system)
    values (task_row.organization_id, '1400', 'Input VAT recoverable', 'asset', true)
    on conflict (organization_id, code) do nothing;
  end if;

  insert into public.books_expenses (
    organization_id, contact_id, description, expense_date, currency_code, amount, tax_amount,
    vat_recoverable, payment_status
  ) values (
    task_row.organization_id, worker_contact_id, 'Worker payment: ' || task_row.title, current_date,
    invoice_link.worker_currency_code, invoice_row.total - invoice_row.tax_amount, invoice_row.tax_amount,
    hotel_recoverable, 'paid'
  )
  returning id into expense_id;

  update public.worker_task_payments
     set hotel_expense_id = expense_id
   where id = payment_id;

  insert into public.notifications (user_id, task_id, type, message, action_url)
  values (
    worker_user_id, task_row.id, 'task_updated',
    'The hotel recorded payment for "' || task_row.title || '". Review the payment and confirm receipt in Books.',
    '/books'
  );

  return payment_id;
end;
$function$;

revoke all on function public.record_worker_task_payment(uuid, text, text, uuid) from public, anon;
grant execute on function public.record_worker_task_payment(uuid, text, text, uuid) to authenticated;

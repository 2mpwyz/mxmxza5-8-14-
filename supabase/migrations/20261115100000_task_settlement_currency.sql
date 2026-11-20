alter table public.tasks
  add column if not exists settlement_currency_code text,
  add column if not exists settlement_fx_rate numeric(20,8),
  add column if not exists settlement_fx_rate_source text,
  add column if not exists settlement_fx_rate_fetched_at timestamptz;

alter table public.task_proposals
  add column if not exists proposed_settlement_currency_code text,
  add column if not exists proposed_settlement_fx_rate numeric(20,8),
  add column if not exists proposed_settlement_fx_rate_source text,
  add column if not exists proposed_settlement_fx_rate_fetched_at timestamptz;

with legacy as (
  select t.id,
         t.currency_code,
         coalesce(link.worker_currency_code::text, t.currency_code) as settlement_currency,
         link.fx_rate,
         link.fx_rate_source,
         link.fx_rate_fetched_at
    from public.tasks t
    left join public.worker_task_invoices link on link.task_id = t.id
   where t.settlement_currency_code is null
)
update public.tasks t
   set settlement_currency_code = legacy.settlement_currency,
       settlement_fx_rate = case when legacy.settlement_currency = legacy.currency_code then 1 else legacy.fx_rate end,
       settlement_fx_rate_source = case when legacy.settlement_currency = legacy.currency_code then 'same_currency' else legacy.fx_rate_source end,
       settlement_fx_rate_fetched_at = case when legacy.settlement_currency = legacy.currency_code then null else legacy.fx_rate_fetched_at end
  from legacy
 where legacy.id = t.id;

alter table public.tasks
  alter column settlement_currency_code set not null,
  add constraint tasks_settlement_currency_format_check check (settlement_currency_code ~ '^[A-Z]{3}$'),
  add constraint tasks_settlement_rate_check check (
    (settlement_fx_rate is null and settlement_fx_rate_source is null)
    or (
      settlement_fx_rate is not null and settlement_fx_rate > 0
      and settlement_fx_rate_source in ('same_currency', 'stored', 'manual', 'hotel_approved', 'hotel_edited')
    )
  ),
  add constraint tasks_settlement_same_currency_check check (
    settlement_currency_code <> currency_code
    or coalesce(settlement_fx_rate = 1 and settlement_fx_rate_source = 'same_currency', false)
  );

alter table public.task_proposals
  add constraint task_proposals_settlement_currency_format_check check (
    proposed_settlement_currency_code is null or proposed_settlement_currency_code ~ '^[A-Z]{3}$'
  ),
  add constraint task_proposals_settlement_rate_check check (
    (proposed_settlement_currency_code is null and proposed_settlement_fx_rate is null and proposed_settlement_fx_rate_source is null)
    or (
      proposed_settlement_currency_code is not null
      and proposed_settlement_fx_rate is not null and proposed_settlement_fx_rate > 0
      and proposed_settlement_fx_rate_source in ('same_currency', 'stored', 'hotel_approved', 'hotel_edited')
    )
  );

create or replace function public.default_task_settlement()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.settlement_currency_code := coalesce(new.settlement_currency_code, new.currency_code);
  if new.settlement_currency_code <> new.currency_code and new.settlement_currency_code not in ('UGX', 'USD') then
    raise exception 'Settlement currency must be UGX or USD, or the task currency';
  end if;
  if new.settlement_currency_code = new.currency_code then
    new.settlement_fx_rate := 1;
    new.settlement_fx_rate_source := 'same_currency';
    new.settlement_fx_rate_fetched_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists default_task_settlement on public.tasks;
create trigger default_task_settlement
  before insert on public.tasks
  for each row execute function public.default_task_settlement();

create or replace function public.resolve_proposal_settlement_rate()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
  fx_row record;
  is_hotel_manager boolean;
begin
  if new.proposed_settlement_currency_code is null then
    new.proposed_settlement_fx_rate := null;
    new.proposed_settlement_fx_rate_source := null;
    new.proposed_settlement_fx_rate_fetched_at := null;
    return new;
  end if;

  select * into task_row from public.tasks where id = new.task_id;
  if not found then raise exception 'Task not found'; end if;

  if new.proposed_settlement_currency_code = task_row.currency_code then
    new.proposed_settlement_fx_rate := 1;
    new.proposed_settlement_fx_rate_source := 'same_currency';
    new.proposed_settlement_fx_rate_fetched_at := null;
    return new;
  end if;

  if new.proposed_settlement_currency_code not in ('UGX', 'USD') then
    raise exception 'Settlement currency must be UGX or USD, or the task currency';
  end if;

  select * into fx_row
    from public.books_task_payment_fx_rate(task_row.currency_code::char(3), new.proposed_settlement_currency_code::char(3));

  if new.proposed_settlement_fx_rate_source in ('hotel_approved', 'hotel_edited') then
    select exists (
      select 1
        from public.user_profiles profile
        join public.books_memberships membership on membership.user_id = profile.user_id
       where profile.user_id = auth.uid()
         and profile.role = 'manager'
         and membership.organization_id = task_row.organization_id
    ) into is_hotel_manager;
    if not is_hotel_manager then
      raise exception 'Only the hotel manager can approve or edit the settlement rate';
    end if;
  end if;

  if new.proposed_settlement_fx_rate_source = 'hotel_edited' then
    if coalesce(new.proposed_settlement_fx_rate, 0) <= 0 then
      raise exception 'Edited settlement rate must be greater than zero';
    end if;
    new.proposed_settlement_fx_rate_fetched_at := fx_row.rate_fetched_at;
  else
    if fx_row.rate_status <> 'stored' then
      raise exception 'FX_RATE_UNAVAILABLE: No current stored % to % rate exists. Refresh the exchange rates and try again.', task_row.currency_code, new.proposed_settlement_currency_code;
    end if;
    new.proposed_settlement_fx_rate := fx_row.fx_rate;
    new.proposed_settlement_fx_rate_fetched_at := fx_row.rate_fetched_at;
    new.proposed_settlement_fx_rate_source := case
      when new.proposed_settlement_fx_rate_source = 'hotel_approved' then 'hotel_approved'
      else 'stored'
    end;
  end if;

  return new;
end;
$$;

drop trigger if exists resolve_proposal_settlement_rate on public.task_proposals;
create trigger resolve_proposal_settlement_rate
  before insert or update of proposed_settlement_currency_code, proposed_settlement_fx_rate, proposed_settlement_fx_rate_source
  on public.task_proposals
  for each row execute function public.resolve_proposal_settlement_rate();

CREATE OR REPLACE FUNCTION public.create_todo_on_proposal_acceptance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.status = 'accepted' AND (OLD.status IS NULL OR OLD.status != 'accepted') THEN
    IF NEW.proposed_settlement_currency_code IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.todo_list tl
      WHERE tl.task_id = NEW.task_id AND tl.worker_id = NEW.worker_id
    ) THEN
      UPDATE public.tasks
         SET settlement_currency_code = NEW.proposed_settlement_currency_code,
             settlement_fx_rate = NEW.proposed_settlement_fx_rate,
             settlement_fx_rate_source = NEW.proposed_settlement_fx_rate_source,
             settlement_fx_rate_fetched_at = NEW.proposed_settlement_fx_rate_fetched_at
       WHERE id = NEW.task_id;
    END IF;

    INSERT INTO public.todo_list (
      task_id,
      worker_id,
      title,
      description,
      priority,
      due_date,
      details,
      status
    )
    SELECT
      t.id,
      NEW.worker_id,
      t.title,
      t.description,
      t.priority,
      COALESCE(NEW.proposed_due_date, t.due_date),
      jsonb_build_object(
        'category_original', t.category,
        'estimated_time_original', t.estimated_time,
        'payment_terms_original', t.payment_terms,
        'budget_original', t.budget,
        'category', COALESCE(NEW.proposed_category, t.category),
        'estimated_time', COALESCE(NEW.proposed_estimated_time, t.estimated_time),
        'payment_terms', COALESCE(NEW.proposed_payment_terms, t.payment_terms),
        'budget', NEW.quoted_price,
        'timeline', NEW.proposed_timeline,
        'negotiation_notes', NEW.proposal_notes,
        'currency', t.currency_code,
        'settlement_currency', t.settlement_currency_code,
        'settlement_fx_rate', t.settlement_fx_rate
      ),
      'pending'::character varying
    FROM public.tasks t
    WHERE t.id = NEW.task_id
    AND NOT EXISTS (
      SELECT 1 FROM public.todo_list tl
      WHERE tl.task_id = NEW.task_id AND tl.worker_id = NEW.worker_id
    );

    INSERT INTO public.notifications (user_id, task_id, type, message)
    SELECT
      up.user_id,
      NEW.task_id,
      'proposal_accepted'::character varying,
      'Your proposal has been accepted! Check your todo list for the agreed terms.'
    FROM public.user_profiles up
    WHERE up.id = NEW.worker_id;
  END IF;

  RETURN NEW;
END;
$$;

notify pgrst, 'reload schema';

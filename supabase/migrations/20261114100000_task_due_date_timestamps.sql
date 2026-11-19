do $$
begin
  if (select data_type from information_schema.columns
       where table_schema = 'public' and table_name = 'tasks' and column_name = 'due_date') = 'date' then
    alter table public.tasks
      alter column due_date type timestamptz
      using ((due_date + time '23:59:59') at time zone 'Africa/Kampala');
  end if;

  if (select data_type from information_schema.columns
       where table_schema = 'public' and table_name = 'todo_list' and column_name = 'due_date') = 'date' then
    alter table public.todo_list
      alter column due_date type timestamptz
      using ((due_date + time '23:59:59') at time zone 'Africa/Kampala');
  end if;
end $$;

alter table public.task_proposals
  add column if not exists proposed_due_date timestamptz;

alter table public.tasks
  add column if not exists currency_code text;

update public.tasks t
   set currency_code = coalesce(
     (select organization.base_currency::text from public.books_organizations organization where organization.id = t.organization_id),
     'UGX'
   )
 where t.currency_code is null;

alter table public.tasks
  alter column currency_code set not null;

alter table public.tasks
  drop constraint if exists tasks_currency_code_format_check;
alter table public.tasks
  add constraint tasks_currency_code_format_check check (currency_code ~ '^[A-Z]{3}$');

update public.todo_list tl
   set details = jsonb_set(coalesce(tl.details, '{}'::jsonb), '{currency}', to_jsonb(t.currency_code))
  from public.tasks t
 where t.id = tl.task_id
   and (tl.details->>'currency') is null;

CREATE OR REPLACE FUNCTION public.create_todo_on_proposal_acceptance()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'accepted' AND (OLD.status IS NULL OR OLD.status != 'accepted') THEN
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
        'currency', t.currency_code
      ),
      'pending'::character varying
    FROM tasks t
    WHERE t.id = NEW.task_id
    AND NOT EXISTS (
      SELECT 1 FROM todo_list tl
      WHERE tl.task_id = NEW.task_id AND tl.worker_id = NEW.worker_id
    );

    INSERT INTO public.notifications (user_id, task_id, type, message)
    SELECT
      up.user_id,
      NEW.task_id,
      'proposal_accepted'::character varying,
      'Your proposal has been accepted! Check your todo list for the agreed terms.'
    FROM user_profiles up
    WHERE up.id = NEW.worker_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.create_worker_task_invoice(target_task_id uuid, manual_fx_rate numeric)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  task_row public.tasks%rowtype;
  invoice_row public.books_invoices%rowtype;
  existing_link public.worker_task_invoices%rowtype;
  worker_user_id uuid;
  hotel_name text;
  hotel_base_currency char(3);
  hotel_currency char(3);
  worker_organization_id uuid;
  worker_currency char(3);
  worker_vat_registered boolean;
  worker_tax_country text;
  fx_row record;
  applied_rate numeric;
  applied_source text;
  applied_fetched_at timestamptz;
  gross_amount numeric;
  vat_rate_id uuid;
  vat_rate_percentage numeric := 0;
  subtotal_amount numeric;
  hotel_tax numeric := 0;
  customer_id uuid;
  journal_id uuid;
  receivable_id uuid;
  revenue_id uuid;
  vat_payable_id uuid;
begin
  select * into task_row from public.tasks where id = target_task_id for update;
  if not found then raise exception 'Task not found'; end if;

  select * into existing_link from public.worker_task_invoices where task_id = target_task_id;
  if found then return existing_link.invoice_id; end if;

  if task_row.organization_id is null or task_row.assigned_to is null
     or coalesce(task_row.final_amount, 0) <= 0 then
    return null;
  end if;
  if manual_fx_rate is not null and manual_fx_rate <= 0 then
    raise exception 'Manual FX rate must be greater than zero';
  end if;

  select profile.user_id into worker_user_id
    from public.user_profiles profile where profile.id = task_row.assigned_to;
  if worker_user_id is null then raise exception 'Assigned worker profile not found'; end if;

  select organization.name, organization.base_currency
    into hotel_name, hotel_base_currency
    from public.books_organizations organization where organization.id = task_row.organization_id;

  hotel_currency := task_row.currency_code;

  worker_organization_id := public.ensure_worker_books_organization(worker_user_id, hotel_base_currency);
  select organization.base_currency, organization.vat_registered, organization.tax_country_code
    into worker_currency, worker_vat_registered, worker_tax_country
    from public.books_organizations organization where organization.id = worker_organization_id;

  select * into fx_row from public.books_task_payment_fx_rate(hotel_currency, worker_currency);
  if fx_row.rate_status in ('same_currency', 'stored') then
    applied_rate := fx_row.fx_rate;
    applied_source := fx_row.rate_status;
    applied_fetched_at := fx_row.rate_fetched_at;
  elsif manual_fx_rate is not null then
    applied_rate := manual_fx_rate;
    applied_source := 'manual';
  elsif fx_row.rate_status = 'stale' then
    raise exception 'FX_RATE_STALE: The stored % to % rate is older than 7 days. Enter a manual rate to continue.', hotel_currency, worker_currency;
  else
    raise exception 'FX_RATE_MISSING: No stored % to % rate exists. Enter a manual rate to continue.', hotel_currency, worker_currency;
  end if;

  gross_amount := round(task_row.final_amount * applied_rate, public.checkout_currency_minor_units(worker_currency));
  if gross_amount <= 0 then raise exception 'Converted task amount is zero'; end if;

  if worker_vat_registered then
    select rate.id, rate.rate_percentage into vat_rate_id, vat_rate_percentage
      from public.books_tax_rates rate
     where rate.organization_id = worker_organization_id
       and rate.country_code = worker_tax_country
       and rate.tax_scope = 'invoice'
       and rate.is_active
       and rate.confirmed_at is not null
       and rate.effective_from <= current_date
       and (rate.effective_to is null or rate.effective_to >= current_date)
     order by rate.effective_from desc, rate.confirmed_at desc
     limit 1;
    if vat_rate_id is null then
      raise exception 'Confirm a VAT rate in your Books tax settings before this task can be approved';
    end if;
    subtotal_amount := round(
      gross_amount / (1 + vat_rate_percentage / 100),
      public.checkout_currency_minor_units(worker_currency)
    );
    hotel_tax := task_row.final_amount - round(
      task_row.final_amount / (1 + vat_rate_percentage / 100),
      public.checkout_currency_minor_units(hotel_currency)
    );
  else
    subtotal_amount := gross_amount;
  end if;

  select contact.id into customer_id from public.books_contacts contact
   where contact.organization_id = worker_organization_id
     and lower(contact.name) = lower(hotel_name)
     and contact.type in ('customer', 'both')
   order by contact.created_at
   limit 1;
  if customer_id is null then
    insert into public.books_contacts (organization_id, name, type)
    values (worker_organization_id, hotel_name, 'customer')
    returning id into customer_id;
  end if;

  insert into public.books_invoices (
    organization_id, contact_id, invoice_number, issue_date, due_date, currency_code,
    subtotal, tax_amount, tax_rate_id, status, notes
  ) values (
    worker_organization_id, customer_id, 'TASK-' || task_row.id::text, current_date, current_date, worker_currency,
    subtotal_amount, gross_amount - subtotal_amount, vat_rate_id, 'sent', 'Approved task: ' || task_row.title
  )
  returning * into invoice_row;

  insert into public.worker_task_invoices (
    task_id, invoice_id, worker_organization_id, hotel_organization_id,
    hotel_currency_code, hotel_amount, hotel_tax_amount,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at
  ) values (
    task_row.id, invoice_row.id, worker_organization_id, task_row.organization_id,
    hotel_currency, task_row.final_amount, hotel_tax,
    worker_currency, applied_rate, applied_source, applied_fetched_at
  );

  select account.id into receivable_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '1100';
  select account.id into revenue_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '4000';
  select account.id into vat_payable_id from public.books_accounts account
   where account.organization_id = worker_organization_id and account.code = '2100';
  if receivable_id is null or revenue_id is null or (invoice_row.tax_amount > 0 and vat_payable_id is null) then
    raise exception 'Required worker Books account is missing';
  end if;

  insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
  values (worker_organization_id, 'worker_task_invoice', invoice_row.id, current_date, 'Task invoice ' || invoice_row.invoice_number, worker_user_id)
  returning id into journal_id;

  insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
  values (journal_id, receivable_id, invoice_row.total, 0, worker_currency, 1),
         (journal_id, revenue_id, 0, invoice_row.subtotal, worker_currency, 1);
  if invoice_row.tax_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, debit, credit, currency_code, exchange_rate)
    values (journal_id, vat_payable_id, 0, invoice_row.tax_amount, worker_currency, 1);
  end if;

  return invoice_row.id;
end;
$$;

notify pgrst, 'reload schema';

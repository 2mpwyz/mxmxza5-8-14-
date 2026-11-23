create or replace function public.record_worker_task_payment(p_task_id uuid, p_payment_method text, p_payment_reference text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  task_row public.tasks%rowtype;
  invoice_row public.books_invoices%rowtype;
  invoice_link public.worker_task_invoices%rowtype;
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

  insert into public.worker_task_payments (
    task_id, hotel_organization_id, worker_user_id, amount, tax_amount, currency_code,
    worker_currency_code, fx_rate, fx_rate_source, fx_rate_fetched_at,
    converted_amount, converted_tax_amount, payment_method, payment_reference,
    recorded_by, confirmation_status
  ) values (
    task_row.id, task_row.organization_id, worker_user_id, task_row.final_amount, invoice_link.hotel_tax_amount, invoice_link.hotel_currency_code,
    invoice_link.worker_currency_code, invoice_link.fx_rate, invoice_link.fx_rate_source, invoice_link.fx_rate_fetched_at,
    invoice_row.total, invoice_row.tax_amount, p_payment_method, reference_text,
    auth.uid(), 'pending_confirmation'
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
    invoice_link.hotel_currency_code, task_row.final_amount - invoice_link.hotel_tax_amount, invoice_link.hotel_tax_amount,
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

revoke all on function public.record_worker_task_payment(uuid, text, text) from public, anon;
grant execute on function public.record_worker_task_payment(uuid, text, text) to authenticated;

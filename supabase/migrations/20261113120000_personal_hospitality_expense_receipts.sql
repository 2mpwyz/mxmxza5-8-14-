create or replace function public.hospitality_purchase_invoice_id(
  target_source_type text,
  target_source_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select case target_source_type
    when 'menu_order' then (
      select menu_order.books_invoice_id from public.menu_orders menu_order where menu_order.id = target_source_id
    )
    when 'hotel_booking' then (
      select booking.books_invoice_id from public.hotel_bookings booking where booking.id = target_source_id
    )
    when 'special_event_payment' then (
      select payment.books_invoice_id from public.special_event_payments payment where payment.id = target_source_id
    )
  end
$$;
revoke all on function public.hospitality_purchase_invoice_id(text, uuid) from public, anon, authenticated;

create or replace function public.copy_hospitality_receipt_to_personal_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'books_invoices' then
    update public.books_expenses expense
       set receipt_url = new.receipt_url
      from public.books_personal_purchase_records purchase_record
     where purchase_record.expense_id = expense.id
       and public.hospitality_purchase_invoice_id(purchase_record.source_type, purchase_record.source_id) = new.id
       and expense.receipt_url is distinct from new.receipt_url;
  else
    update public.books_expenses expense
       set receipt_url = invoice.receipt_url
      from public.books_invoices invoice
     where expense.id = new.expense_id
       and invoice.id = public.hospitality_purchase_invoice_id(new.source_type, new.source_id)
       and invoice.receipt_url is not null
       and expense.receipt_url is distinct from invoice.receipt_url;
  end if;
  return null;
end;
$$;
revoke all on function public.copy_hospitality_receipt_to_personal_expense() from public, anon, authenticated;

drop trigger if exists menu_receipt_to_personal_expense on public.books_invoices;
drop trigger if exists hospitality_receipt_to_personal_expense on public.books_invoices;
create trigger hospitality_receipt_to_personal_expense
after update of receipt_url on public.books_invoices
for each row
when (new.invoice_number ~ '^(MENU|HOTEL|EVENT)-' and new.receipt_url is not null)
execute function public.copy_hospitality_receipt_to_personal_expense();

drop trigger if exists purchase_menu_receipt_to_personal_expense on public.books_personal_purchase_records;
drop trigger if exists purchase_hospitality_receipt_to_personal_expense on public.books_personal_purchase_records;
create trigger purchase_hospitality_receipt_to_personal_expense
after insert or update of expense_id on public.books_personal_purchase_records
for each row
when (new.source_type in ('menu_order', 'hotel_booking', 'special_event_payment') and new.expense_id is not null)
execute function public.copy_hospitality_receipt_to_personal_expense();

update public.books_expenses expense
   set receipt_url = invoice.receipt_url
  from public.books_personal_purchase_records purchase_record
  join public.books_invoices invoice
    on invoice.id = public.hospitality_purchase_invoice_id(purchase_record.source_type, purchase_record.source_id)
 where purchase_record.expense_id = expense.id
   and expense.receipt_url is null
   and invoice.receipt_url is not null;

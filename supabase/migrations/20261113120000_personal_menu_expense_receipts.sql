create or replace function public.copy_menu_receipt_to_personal_expense()
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
     where purchase_record.source_type = 'menu_order'
       and purchase_record.expense_id = expense.id
       and purchase_record.hotel_organization_id = new.organization_id
       and exists (
         select 1
           from public.menu_orders menu_order
          where menu_order.id = purchase_record.source_id
            and new.invoice_number = 'MENU-' || menu_order.order_number
       )
       and expense.receipt_url is distinct from new.receipt_url;
  else
    update public.books_expenses expense
       set receipt_url = invoice.receipt_url
      from public.menu_orders menu_order
      join public.books_invoices invoice
        on invoice.organization_id = new.hotel_organization_id
       and invoice.invoice_number = 'MENU-' || menu_order.order_number
     where menu_order.id = new.source_id
       and new.source_type = 'menu_order'
       and expense.id = new.expense_id
       and invoice.receipt_url is not null
       and expense.receipt_url is distinct from invoice.receipt_url;
  end if;
  return null;
end;
$$;

drop trigger if exists menu_receipt_to_personal_expense on public.books_invoices;
create trigger menu_receipt_to_personal_expense
after update of receipt_url on public.books_invoices
for each row
when (new.invoice_number like 'MENU-%' and new.receipt_url is not null)
execute function public.copy_menu_receipt_to_personal_expense();

drop trigger if exists purchase_menu_receipt_to_personal_expense on public.books_personal_purchase_records;
create trigger purchase_menu_receipt_to_personal_expense
after insert or update of expense_id on public.books_personal_purchase_records
for each row
when (new.source_type = 'menu_order' and new.expense_id is not null)
execute function public.copy_menu_receipt_to_personal_expense();

update public.books_expenses expense
   set receipt_url = invoice.receipt_url
  from public.books_personal_purchase_records purchase_record
  join public.menu_orders menu_order
    on menu_order.id = purchase_record.source_id
  join public.books_invoices invoice
    on invoice.organization_id = purchase_record.hotel_organization_id
   and invoice.invoice_number = 'MENU-' || menu_order.order_number
 where purchase_record.source_type = 'menu_order'
   and purchase_record.expense_id = expense.id
   and expense.receipt_url is null
   and invoice.receipt_url is not null;

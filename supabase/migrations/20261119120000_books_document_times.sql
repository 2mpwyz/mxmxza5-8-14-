alter table public.books_invoices add column if not exists issue_at timestamptz;
alter table public.books_expenses add column if not exists expense_at timestamptz;

alter table public.books_invoices alter column issue_at set default now();
alter table public.books_expenses alter column expense_at set default now();

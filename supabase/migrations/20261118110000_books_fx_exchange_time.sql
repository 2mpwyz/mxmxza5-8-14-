alter table public.books_fx_conversions
  add column if not exists exchange_at timestamptz;

drop function if exists public.record_books_fx_conversion(uuid, date, text, numeric, numeric, numeric, text, text);

create or replace function public.record_books_fx_conversion(
  p_organization_id uuid,
  p_conversion_date date,
  p_from_currency_code text,
  p_from_amount numeric,
  p_to_ugx_amount numeric,
  p_carrying_ugx_per_unit numeric,
  p_provider text,
  p_reference text,
  p_exchange_at timestamptz default null
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
    id, organization_id, conversion_date, exchange_at, from_currency_code, from_amount, to_ugx_amount,
    carrying_ugx_per_unit, realized_fx_difference, provider, reference, journal_transaction_id, created_by
  ) values (
    conversion_id, p_organization_id, coalesce(p_conversion_date, current_date), coalesce(p_exchange_at, now()),
    from_currency, from_amount, to_amount, carrying_rate, gain_loss, nullif(trim(p_provider), ''), reference_text,
    journal_id, auth.uid()
  );

  return conversion_id;
end;
$function$;

revoke all on function public.record_books_fx_conversion(uuid, date, text, numeric, numeric, numeric, text, text, timestamptz) from public, anon;
grant execute on function public.record_books_fx_conversion(uuid, date, text, numeric, numeric, numeric, text, text, timestamptz) to authenticated;

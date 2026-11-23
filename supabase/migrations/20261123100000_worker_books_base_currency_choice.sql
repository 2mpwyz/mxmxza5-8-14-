alter table public.user_profiles
  add column if not exists books_base_currency char(3);

alter table public.user_profiles
  drop constraint if exists user_profiles_books_base_currency_format_check;
alter table public.user_profiles
  add constraint user_profiles_books_base_currency_format_check
  check (books_base_currency is null or books_base_currency ~ '^[A-Z]{3}$');

comment on column public.user_profiles.books_base_currency is
  'Worker-chosen Books reporting currency. Never used to decide payout conversion; tasks.settlement_currency_code does that.';
comment on column public.worker_task_invoices.worker_currency_code is
  'Payout (settlement) currency copied from tasks.settlement_currency_code. Not the worker Books base currency. Candidate for rename to payout_currency_code.';
comment on column public.worker_task_payments.worker_currency_code is
  'Payout (settlement) currency copied from tasks.settlement_currency_code. Not the worker Books base currency. Candidate for rename to payout_currency_code.';

-- The hotel currency argument is kept for call compatibility but is ignored:
-- a worker's base currency is their own choice, defaulting to UGX.
create or replace function public.ensure_worker_books_organization(target_user_id uuid, org_currency char(3) default null)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  worker_organization_id uuid;
  worker_profile record;
  registered_business_name text;
  worker_entity_type text;
begin
  perform pg_advisory_xact_lock(hashtextextended('worker-books:' || target_user_id::text, 0));
  select workspace.organization_id into worker_organization_id
    from public.books_worker_workspaces workspace
   where workspace.user_id = target_user_id;
  if worker_organization_id is not null then
    return worker_organization_id;
  end if;

  select profile.role, profile.first_name, profile.last_name, profile.buyer_business_name,
         profile.tax_entity_type, profile.books_base_currency
    into worker_profile
    from public.user_profiles profile
   where profile.user_id = target_user_id;
  if worker_profile.role is distinct from 'worker' then
    raise exception 'Worker Books are available to worker accounts';
  end if;

  registered_business_name := nullif(trim(worker_profile.buyer_business_name), '');
  worker_entity_type := coalesce(
    worker_profile.tax_entity_type,
    case when registered_business_name is null then 'sole_proprietor' end
  );

  insert into public.books_organizations (name, owner_id, tax_entity_type, base_currency)
  values (
    coalesce(
      registered_business_name,
      nullif(trim(concat_ws(' ', worker_profile.first_name, worker_profile.last_name)), ''),
      'Worker Books'
    ),
    target_user_id,
    worker_entity_type,
    coalesce(worker_profile.books_base_currency, 'UGX')
  )
  returning id into worker_organization_id;

  insert into public.books_memberships (organization_id, user_id, role)
  values (worker_organization_id, target_user_id, 'owner');

  insert into public.books_accounts (organization_id, code, name, type, is_system) values
    (worker_organization_id, '1000', 'Cash and bank', 'asset', true),
    (worker_organization_id, '1100', 'Accounts receivable', 'asset', true),
    (worker_organization_id, '2000', 'Accounts payable', 'liability', true),
    (worker_organization_id, '2100', 'VAT payable', 'liability', true),
    (worker_organization_id, '3000', 'Owner equity', 'equity', true),
    (worker_organization_id, '4000', 'Sales revenue', 'income', true),
    (worker_organization_id, '5000', 'Operating expenses', 'expense', true)
  on conflict (organization_id, code) do nothing;

  perform public.seed_books_tax_rates(worker_organization_id);

  insert into public.books_worker_workspaces (user_id, organization_id)
  values (target_user_id, worker_organization_id);

  update public.user_profiles profile
     set tax_entity_type = worker_entity_type
   where profile.user_id = target_user_id
     and profile.tax_entity_type is distinct from worker_entity_type;

  return worker_organization_id;
end;
$$;
revoke all on function public.ensure_worker_books_organization(uuid, char(3)) from public, anon, authenticated;

create or replace function public.set_worker_books_base_currency(p_currency text)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  chosen char(3) := upper(trim(p_currency));
  worker_organization_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to access Books'; end if;
  if chosen !~ '^[A-Z]{3}$' then raise exception 'Choose a valid 3-letter currency code'; end if;
  if not exists (select 1 from public.user_profiles where user_id = auth.uid() and role = 'worker') then
    raise exception 'Worker Books are available to worker accounts';
  end if;

  update public.user_profiles set books_base_currency = chosen where user_id = auth.uid();

  select workspace.organization_id into worker_organization_id
    from public.books_worker_workspaces workspace where workspace.user_id = auth.uid();
  if worker_organization_id is not null then
    if exists (select 1 from public.books_journal_transactions where organization_id = worker_organization_id) then
      raise exception 'Your Books already has recorded transactions, so the base currency can no longer be changed';
    end if;
    update public.books_organizations set base_currency = chosen where id = worker_organization_id;
  end if;

  return chosen;
end;
$$;
revoke all on function public.set_worker_books_base_currency(text) from public, anon;
grant execute on function public.set_worker_books_base_currency(text) to authenticated;

notify pgrst, 'reload schema';

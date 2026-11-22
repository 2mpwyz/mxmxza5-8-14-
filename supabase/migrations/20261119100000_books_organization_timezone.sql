alter table public.books_organizations
  add column if not exists timezone text not null default 'Africa/Kampala';

create or replace function public.update_books_timezone(
  target_organization_id uuid,
  target_timezone text
)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if nullif(btrim(target_timezone), '') is null
     or not exists (select 1 from pg_timezone_names where name = btrim(target_timezone)) then
    raise exception 'Select a valid timezone';
  end if;
  if not exists (
    select 1 from public.books_memberships as membership
     where membership.organization_id = target_organization_id
       and membership.user_id = auth.uid()
       and membership.role in ('owner', 'admin')
  ) then
    raise exception 'Only a Books owner or administrator can change the timezone';
  end if;
  update public.books_organizations
     set timezone = btrim(target_timezone)
   where id = target_organization_id;
end;
$$;
revoke all on function public.update_books_timezone(uuid, text) from public, anon;
grant execute on function public.update_books_timezone(uuid, text) to authenticated;

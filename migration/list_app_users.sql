-- Let a platform admin see who has an account, so grants can be handed out from
-- a page instead of the SQL editor.
--
-- auth.users is not reachable through PostgREST, by design — it holds password
-- hashes, recovery tokens and confirmation state. This exposes four harmless
-- columns and nothing else, and only to a platform admin.
--
-- The `where public.is_platform_admin()` is the whole guard. For anyone else the
-- function returns an empty set rather than raising, so a caller cannot even
-- tell the difference between "no users" and "not allowed" — and no row ever
-- leaves the database.
--
-- SECURITY DEFINER is required to read auth.users at all. search_path is pinned
-- and every table reference is schema-qualified, so nothing here resolves
-- against something a caller controls.

create or replace function public.list_app_users()
returns table (
  id              uuid,
  email           text,
  created_at      timestamptz,
  last_sign_in_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select u.id, u.email::text, u.created_at, u.last_sign_in_at
  from auth.users u
  where public.is_platform_admin()
  order by u.email;
$$;

revoke execute on function public.list_app_users() from public, anon;
grant  execute on function public.list_app_users() to authenticated;

-- Check: as a platform admin this returns every account; impersonate anyone
-- else and it returns nothing.
--
--   select count(*) from public.list_app_users();

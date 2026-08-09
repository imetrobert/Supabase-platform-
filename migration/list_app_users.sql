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

-- Checking it works
--
-- Calling this bare in the SQL Editor returns 0, and that is correct, not a
-- fault: the editor runs as `postgres` with no signed-in user, so auth.uid() is
-- NULL and is_platform_admin() is false. The guard is doing its job. To see
-- anything you have to say who you are.

create temp table if not exists _chk(seq int, label text, result text);
delete from _chk;

select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role','authenticated')::text
   from auth.users where email = 'robert@imetrobert.com'), false);
insert into _chk select 1, 'platform admin sees users (want 3)',
  count(*)::text from public.list_app_users();

select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role','authenticated')::text
   from auth.users where email = 'oboulian@gmail.com'), false);
insert into _chk select 2, 'ordinary account sees users (want 0)',
  count(*)::text from public.list_app_users();

select set_config('request.jwt.claims', '', false);
insert into _chk select 3, 'nobody signed in sees users (want 0)',
  count(*)::text from public.list_app_users();

select seq, label, result from _chk order by seq;

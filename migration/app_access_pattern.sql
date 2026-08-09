-- Two-level access control: one master user list, per-app authorization.
--
-- auth.users stays the single identity list shared by every app in the project.
-- public.app_access decides which of those users may enter which app. A user with
-- a login but no grant for an app sees nothing from that app's tables.
--
-- This exists because several apps share one Supabase project. The usual policy
-- `auth.role() = 'authenticated'` means "any logged-in user", which is airtight in
-- a single-tenant project and wide open in a shared one — every user of every app
-- can read every table. That is the gap this closes.
--
-- Live as of 2026-08-09 for the claims-tracker app. Apply the same shape to the
-- other apps in the project (etf-*, job-*, invoices, survey_responses), which are
-- still on the permissive policy.

-- 1. The allowlist ----------------------------------------------------------

create table if not exists public.app_access (
  user_id    uuid not null references auth.users(id) on delete cascade,
  app        text not null,
  granted_at timestamptz not null default now(),
  primary key (user_id, app)
);

alter table public.app_access enable row level security;

-- A user may read their own grants and nothing else. Access is handed out from
-- the dashboard (postgres role), never by an app.
drop policy if exists "app_access read own" on public.app_access;
create policy "app_access read own"
  on public.app_access for select to authenticated
  using (user_id = auth.uid());

-- 2. The helper every app's policies call ------------------------------------

-- SECURITY DEFINER so it can read app_access past that table's own RLS.
-- search_path is pinned so the function cannot be tricked into resolving
-- `app_access` to some other table the caller controls.
create or replace function public.has_app_access(app_name text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.app_access
    where user_id = auth.uid() and app = app_name
  );
$$;

revoke execute on function public.has_app_access(text) from public, anon;
grant  execute on function public.has_app_access(text) to authenticated;

-- 3. Applying it to a table ---------------------------------------------------
-- Replace 'claims' and 'claims-tracker' for other apps. Grant only the verbs the
-- app actually uses: claims-tracker never deletes (it marks rows 'duplicate' or
-- 'excluded' via UPDATE), so it has no DELETE policy and deletes stay blocked.

alter table public.claims enable row level security;

drop policy if exists "claims select (claims-tracker)" on public.claims;
drop policy if exists "claims insert (claims-tracker)" on public.claims;
drop policy if exists "claims update (claims-tracker)" on public.claims;

create policy "claims select (claims-tracker)"
  on public.claims for select to authenticated
  using (public.has_app_access('claims-tracker'));

create policy "claims insert (claims-tracker)"
  on public.claims for insert to authenticated
  with check (public.has_app_access('claims-tracker'));

create policy "claims update (claims-tracker)"
  on public.claims for update to authenticated
  using (public.has_app_access('claims-tracker'))
  with check (public.has_app_access('claims-tracker'));

-- 4. Granting a user access ---------------------------------------------------
-- Looked up by email so there is no chance of pasting the wrong UUID.

insert into public.app_access (user_id, app)
select id, 'claims-tracker'
from auth.users
where email = 'robert@imetrobert.com'
on conflict (user_id, app) do nothing;

-- Revoking is the mirror image:
--   delete from public.app_access
--   where app = 'claims-tracker'
--     and user_id = (select id from auth.users where email = '...');

-- 5. Auditing -----------------------------------------------------------------
-- Who can get into what:
--   select u.email, a.app, a.granted_at
--   from public.app_access a join auth.users u on u.id = a.user_id
--   order by a.app, u.email;
--
-- Which tables are still on the permissive policy:
--   select tablename, policyname, qual
--   from pg_policies
--   where schemaname = 'public' and qual like '%auth.role()%';

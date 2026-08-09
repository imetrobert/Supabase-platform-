-- Access control for a Supabase project shared by several apps.
--
-- Applied in full on 2026-08-09. Every table in `public` is gated by this model;
-- verify with the audit query at the bottom, which must return no rows.
--
-- The problem it solves: Supabase Auth is per-project, not per-app. Every app
-- pointing at this project shares one set of users, so the usual policy
-- `auth.role() = 'authenticated'` means "anyone with an account on any of my
-- apps". That is airtight in a single-tenant project and wide open here — this
-- project has six apps and three accounts.
--
-- Two dimensions, kept deliberately separate:
--
--   1. CAN YOU ENTER?    app_access(user_id, app)  ->  has_app_access('etf')
--   2. WHAT CAN YOU SEE? role + row ownership      ->  app_role('etf'),
--                                                      user_id = auth.uid()


-- 1. The grant table ---------------------------------------------------------

create table if not exists public.app_access (
  user_id    uuid not null references auth.users(id) on delete cascade,
  app        text not null,
  role       text not null default 'member',
  granted_at timestamptz not null default now(),
  granted_by uuid references auth.users(id),
  primary key (user_id, app)
);

do $$ begin
  alter table public.app_access
    add constraint app_access_role_chk check (role in ('member','app_admin'));
exception when duplicate_object then null; end $$;

alter table public.app_access enable row level security;

-- 'platform' is a reserved app name meaning the access-control system itself.
-- app_admin on it is what lets someone hand out grants.

drop policy if exists "app_access read own" on public.app_access;
create policy "app_access read own" on public.app_access
  for select to authenticated
  using (user_id = auth.uid() or public.is_platform_admin());

drop policy if exists "app_access admin writes" on public.app_access;
create policy "app_access admin writes" on public.app_access
  for all to authenticated
  using (public.is_platform_admin())
  with check (public.is_platform_admin());


-- 2. The functions every policy calls ----------------------------------------
--
-- SECURITY DEFINER so they can read app_access past that table's own RLS, with
-- search_path pinned so they cannot be tricked into resolving `app_access` to
-- something the caller controls. Running as the table owner also means no
-- policy recursion.

create or replace function public.has_app_access(app_name text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.app_access
    where user_id = auth.uid() and app = app_name
  );
$$;

create or replace function public.app_role(app_name text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select role from public.app_access where user_id = auth.uid() and app = app_name;
$$;

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.app_access
    where user_id = auth.uid() and app = 'platform' and role = 'app_admin'
  );
$$;

revoke execute on function public.has_app_access(text)  from public, anon;
revoke execute on function public.app_role(text)        from public, anon;
revoke execute on function public.is_platform_admin()   from public, anon;
grant  execute on function public.has_app_access(text)  to authenticated;
grant  execute on function public.app_role(text)        to authenticated;
grant  execute on function public.is_platform_admin()   to authenticated;


-- 3. The two policy shapes ---------------------------------------------------
--
-- Every table uses one of these. Resist inventing a third: the value of this
-- model is that one audit query can check the whole project.
--
-- SHARED — reference data that is the same for everyone in the app. Market
-- prices, scraped job postings, ingest bookkeeping. Facts about the world, not
-- personal records.
--
--   for all to authenticated
--   using      (public.has_app_access('APP'))
--   with check (public.has_app_access('APP'))
--
-- PERSONAL — one person's rows. Note the asymmetry: reads widen for an
-- app_admin so someone running the app on the owner's behalf can support it,
-- but writes stay ownership-only, so not even an admin can create or alter a
-- row belonging to somebody else.
--
--   for select to authenticated
--   using (public.has_app_access('APP')
--          and (public.app_role('APP') = 'app_admin' or user_id = auth.uid()))
--
--   for insert to authenticated
--   with check (public.has_app_access('APP') and user_id = auth.uid())
--
-- Grant only the verbs the app actually uses. claims-tracker never deletes — it
-- marks rows 'duplicate' or 'excluded' via UPDATE — so it has no DELETE policy
-- and deletes stay blocked. job_postings likewise has DELETE but no SELECT,
-- which is odd but is what the app was built against.


-- 4. What is deployed --------------------------------------------------------
--
--   app             tables                                        shape
--   -------------   -------------------------------------------   ------------
--   claims-tracker  claims                                        shared
--   etf             8 × etf_*                                     shared
--   invoicing       invoices, survey_responses                    shared
--   job             7 × job_*                                     shared (1)
--   cartmatch       3 × cartmatch_*                               personal
--   fb-marketplace  profiles                                      personal
--
--   (1) job is shared-shape today because it has one user. It is intended to be
--       multi-user, so its personal tables — job_profile, job_applications,
--       job_dismissed, job_matches — still need a user_id column, a backfill of
--       the existing 1,346 rows, and the personal shape above.
--
--       Blocked on one thing: something generates job_matches and job_postings
--       on a schedule, and if that writer does not set user_id, every new match
--       arrives owned by nobody and the personal policy hides it from everyone.
--       The writer has to be changed alongside the schema, not after it.
--
--       job_postings, job_sources and job_runs stay shared — the scraped world
--       and ingest bookkeeping are identical for every user.


-- 5. Granting and revoking ---------------------------------------------------
-- By email, so there is no chance of pasting the wrong uuid.

--   insert into public.app_access (user_id, app, role)
--   select id, 'job', 'member' from auth.users where email = 'someone@example.com'
--   on conflict (user_id, app) do update set role = excluded.role;

--   delete from public.app_access
--   where app = 'job'
--     and user_id = (select id from auth.users where email = 'someone@example.com');

-- Neither needs a deploy. The change takes effect on that person's next page
-- load, and is enforced by the database rather than by browser code.


-- 6. Audit -------------------------------------------------------------------

-- Who can reach what:
--   select u.email, a.app, a.role, a.granted_at
--   from public.app_access a join auth.users u on u.id = a.user_id
--   order by a.app, u.email;

-- Anything still open to every logged-in account. MUST RETURN NO ROWS:
--   select tablename, policyname, cmd, coalesce(qual, with_check) as expr
--   from pg_policies
--   where schemaname = 'public'
--     and (coalesce(qual, with_check, 'true') = 'true'
--          or coalesce(qual,'') || coalesce(with_check,'') like '%auth.role()%')
--   order by tablename, policyname;

-- Tables with RLS switched off entirely — worse than an open policy, since no
-- policy audit would catch them. MUST RETURN NO ROWS:
--   select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
--   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;

-- A caveat worth keeping honest: whoever holds platform/app_admin can grant
-- themselves app_admin on any app and then read everything in it. That is
-- inherent to controlling access, not a flaw in this model. granted_at and
-- granted_by make such a change visible rather than silent; they do not
-- prevent it. Enforcing it would need a second approver.

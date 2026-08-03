-- Inventory / structure capture for a Supabase project.
--
-- Run each section separately in the SQL editor and commit the output. Together
-- they produce everything needed to fill in an inventory/<project-ref>.md and a
-- schema/<project-ref>/ snapshot.
--
-- DESIGNED FOR A PHONE. The Supabase SQL editor on iOS is often the only tool
-- available, so every section returns a small number of rows with the detail
-- packed into one wide text column, rather than many narrow columns that force
-- horizontal scrolling. Sections are ordered cheapest-first: section 1 alone is
-- enough to know what exists.
--
-- If you are working from a phone through the Supabase AI chat, use
-- ./capture-blocks.sql instead — same information, but each block returns a
-- single text cell that is one copy action rather than a table to scroll.
--
-- READ-ONLY. Nothing here writes, locks, or changes anything.
--
-- VERIFIED 2026-08-03: every section was run against a throwaway PostgreSQL
-- instance loaded with ../schema/ipnajvgwtjrlecbqfwrh/invoicing-app.sql, and the
-- three detector queries (function overloads in section 5, the RLS check in
-- section 4, security_invoker in section 6) were each confirmed to actually FIRE
-- by injecting the fault they look for. A detector that has only ever returned
-- zero rows has not been tested.
--   Caveat: that instance was PostgreSQL 16; the live project is 17.6. Every
--   catalog used here is long-stable across both, but this has not been run
--   against the real database yet.
--
-- Excludes Supabase's own schemas (auth, storage, realtime, vault, extensions,
-- graphql, supabase_functions...) and only reports what you own.


-- ─────────────────────────────────────────────────────────────────────────────
-- 1 — What exists, and is RLS on?
-- ─────────────────────────────────────────────────────────────────────────────
-- Start here. One row per table/view. The rls column is the one to read first:
-- a table with rls=false in a project reachable by the publishable key is
-- readable by anyone, full stop.

select
  c.relname                                            as name,
  case c.relkind when 'r' then 'table'
                 when 'v' then 'view'
                 when 'm' then 'matview'
                 when 'p' then 'partitioned' end       as kind,
  c.relrowsecurity                                     as rls,
  c.relforcerowsecurity                                as rls_forced,
  (select count(*) from pg_policy p where p.polrelid = c.oid) as policies,
  pg_size_pretty(pg_total_relation_size(c.oid))        as size
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind in ('r','v','m','p')
order by c.relkind, c.relname;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2 — Columns, one row per table
-- ─────────────────────────────────────────────────────────────────────────────
-- Packed into a single text column so a table's whole shape is readable without
-- scrolling. Sufficient to rebuild a create table by hand.

select
  c.relname as "table",
  string_agg(
    a.attname
      || ' ' || format_type(a.atttypid, a.atttypmod)
      || case when a.attnotnull then ' NOT NULL' else '' end
      || coalesce(' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid), ''),
    E'\n' order by a.attnum
  ) as columns
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
where n.nspname = 'public' and c.relkind in ('r','p')
group by c.relname
order by c.relname;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3 — Constraints and indexes
-- ─────────────────────────────────────────────────────────────────────────────
-- Watch for uniqueness that ought to exist and does not. A token or slug column
-- without a unique index is a bug waiting to happen if the reading code takes
-- data[0] instead of .single().

select
  c.relname as "table",
  string_agg(con.conname || ': ' || pg_get_constraintdef(con.oid), E'\n' order by con.conname) as constraints
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
group by c.relname
order by c.relname;

select
  tablename as "table",
  string_agg(indexdef, E'\n' order by indexname) as indexes
from pg_indexes
where schemaname = 'public'
group by tablename
order by tablename;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4 — RLS policies, in full
-- ─────────────────────────────────────────────────────────────────────────────
-- The important read. For each policy ask: does this predicate actually
-- identify the caller, or does it only describe the row?
--
-- Also check permissive vs RESTRICTIVE. Permissive policies compose with OR —
-- any one passing grants access. Restrictive compose with AND and must ALL
-- pass. A restrictive policy sitting among permissive ones is easy to misread
-- as one more grant when it is actually a gate on every other policy.
--
-- `using (some_column is not null)` and `using (auth.role() = 'authenticated')`
-- are both row descriptions. Neither ties the row to the person asking. On a
-- shared project the second one means every app's users share one trust
-- boundary. See ../policies/patterns.md.

select
  tablename as "table",
  string_agg(
    policyname
      || ' [' || case when permissive = 'PERMISSIVE' then 'permissive' else 'RESTRICTIVE' end
      || ' ' || cmd || ' to ' || array_to_string(roles, ',') || ']'
      || coalesce(E'\n  USING ' || qual, '')
      || coalesce(E'\n  WITH CHECK ' || with_check, ''),
    E'\n' order by policyname
  ) as policies
from pg_policies
where schemaname = 'public'
group by tablename
order by tablename;

-- Tables with RLS enabled but zero policies (deny-all — often unintentional),
-- and tables with RLS disabled entirely (open to anyone with the key).
select
  c.relname as name,
  case when not c.relrowsecurity then 'RLS DISABLED — open to any caller'
       else 'RLS on, NO POLICIES — denies everyone except service_role' end as finding
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
  and (not c.relrowsecurity
       or not exists (select 1 from pg_policy p where p.polrelid = c.oid))
order by c.relname;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5 — Functions
-- ─────────────────────────────────────────────────────────────────────────────
-- Two things to check on every SECURITY DEFINER function:
--
--   definer + no search_path      → hygiene problem, fix it
--   two overloads, same arg name  → PostgREST cannot choose between them and
--                                   EVERY rpc() call fails, silently. SQL still
--                                   works, because SQL resolves by type. This
--                                   exact bug killed the invoice click counter
--                                   for two months.
--
-- The dupes query at the end is the cheap check for the second one.

select
  p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as function,
  case when p.prosecdef then 'DEFINER' else 'invoker' end as security,
  coalesce(array_to_string(p.proconfig, ', '), '— none —') as config,
  pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
order by p.proname;

-- Overloads sharing a parameter name: breaks PostgREST rpc() resolution.
select p.proname, count(*) as overloads,
       string_agg(pg_get_function_identity_arguments(p.oid), ' | ') as signatures
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
group by p.proname
having count(*) > 1;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6 — Views: security_invoker
-- ─────────────────────────────────────────────────────────────────────────────
-- A view without security_invoker runs with its OWNER's rights, so it reads its
-- base tables with RLS bypassed. PostgREST exposes views at /rest/v1/<view>, so
-- such a view is a full read of its base table waiting for someone to grant
-- select on it. Revokes alone are not enough: a later blanket grant, or a tool
-- re-applying Supabase's default privileges, silently re-opens it.

select
  c.relname as view,
  coalesce((select option_value from pg_options_to_table(c.reloptions)
            where option_name = 'security_invoker'), 'off — RUNS AS OWNER') as security_invoker
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'v'
order by c.relname;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7 — Grants
-- ─────────────────────────────────────────────────────────────────────────────
-- Expect anon and authenticated to hold broad DML on every table: that is
-- Supabase's default for the public schema, not a misconfiguration. RLS is what
-- actually gates access. Read this section together with section 4 — broad
-- grants are only safe while the policies are right.

select
  table_name,
  string_agg(grantee || ': ' || privs, E'\n' order by grantee) as grants
from (
  select table_name, grantee,
         string_agg(distinct lower(privilege_type), ',' order by lower(privilege_type)) as privs
  from information_schema.role_table_grants
  where table_schema = 'public'
    and grantee in ('anon','authenticated','service_role','PUBLIC')
  group by table_name, grantee
) t
group by table_name
order by table_name;

-- Who can execute which functions — the anon row is the one that matters.
select
  p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as function,
  string_agg(r.rolname, ', ' order by r.rolname) as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join (select unnest(array['anon','authenticated','service_role']) as rolname) r
where n.nspname = 'public'
  and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
group by p.proname, pg_get_function_identity_arguments(p.oid)
order by 1;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8 — Triggers
-- ─────────────────────────────────────────────────────────────────────────────

select
  c.relname as "table",
  string_agg(t.tgname || ': ' || pg_get_triggerdef(t.oid), E'\n' order by t.tgname) as triggers
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and not t.tgisinternal
group by c.relname
order by c.relname;


-- ─────────────────────────────────────────────────────────────────────────────
-- 9 — Row counts
-- ─────────────────────────────────────────────────────────────────────────────
-- Estimates from the planner, not exact counts — no sequential scans. -1 means
-- the table has never been analyzed.

select c.relname as "table", c.reltuples::bigint as approx_rows
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.reltuples desc;


-- ─────────────────────────────────────────────────────────────────────────────
-- Not covered here — check in the dashboard
-- ─────────────────────────────────────────────────────────────────────────────
-- Auth settings: whether signups are open, which providers are on, how many
--   users exist. On a shared project this decides the blast radius of any
--   `auth.role() = 'authenticated'` policy, so it is not optional.
-- Storage buckets and their policies.
-- Edge Functions, scheduled jobs, database webhooks.
-- Which keys are in circulation and where they are stored.

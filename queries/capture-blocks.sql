-- Capture blocks — one query per block, for pasting into the Supabase SQL editor
-- or its AI chat one at a time.
--
-- Same information as inventory.sql, shaped differently. inventory.sql returns
-- normal result tables and is better on a laptop. These return ONE text column
-- in ONE row, so the whole answer is a single copy on a phone and survives being
-- pasted through a chat interface without a table getting mangled.
--
-- Run them in order. Blocks 1, 3 and 7 are the high-value ones: what exists, how
-- it is protected, and who can log in.
--
-- READ-ONLY. Nothing here writes, locks, or changes anything.
--
-- VERIFIED 2026-08-03: all seven run clean against a throwaway PostgreSQL 16
-- instance loaded with the invoicing snapshot plus stand-in survey_responses,
-- etf_*, job_*, profiles and auth tables. The detectors in blocks 3 and 4 were
-- confirmed to FIRE by seeding the faults they look for (a table with RLS off, a
-- table with RLS on and no policies, and a duplicate function overload).
-- The live project is 17.6; these catalogs are stable across both.
--
-- Block 7 reads auth.users and auth.identities. It reports COUNTS and email
-- DOMAINS only — no addresses, no user IDs — so its output is safe to paste
-- back into a chat.

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCK 1 — what exists
-- ─────────────────────────────────────────────────────────────────────────────
select string_agg(line, E'\n' order by line) as inventory
from (
  select c.relname
      || ' [' || case c.relkind when 'r' then 'table' when 'v' then 'view'
                                when 'm' then 'matview' when 'p' then 'part' end || ']'
      || ' rls=' || case when c.relkind in ('r','p') then c.relrowsecurity::text else '-' end
      || ' pol=' || (select count(*) from pg_policy p where p.polrelid = c.oid)::text
      || ' cols=' || (select count(*) from pg_attribute a
                      where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped)::text
      || ' rows~' || case when c.reltuples < 0 then '?' else c.reltuples::bigint::text end as line
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r','v','m','p')
) t;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCK 2 — columns of every table
-- ─────────────────────────────────────────────────────────────────────────────
select string_agg(blk, E'\n\n' order by tbl) as columns
from (
  select c.relname as tbl,
         c.relname || E':\n' || string_agg(
           '  ' || a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
           || case when a.attnotnull then ' NOTNULL' else '' end
           || coalesce(' DEF ' || pg_get_expr(d.adbin, d.adrelid), ''),
           E'\n' order by a.attnum) as blk
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
  where n.nspname = 'public' and c.relkind in ('r','p')
  group by c.relname
) t;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCK 3 — RLS policies, and tables needing attention
-- ─────────────────────────────────────────────────────────────────────────────
select coalesce((
  select string_agg(
    tablename || '.' || policyname
    || ' [' || cmd || ' to ' || array_to_string(roles, ',') || ']'
    || E'\n    USING ' || coalesce(qual, '(none)')
    || E'\n    CHECK ' || coalesce(with_check, '(none)'),
    E'\n\n' order by tablename, policyname)
  from pg_policies where schemaname = 'public'), '(no policies at all)')
|| E'\n\n--- TABLES NEEDING ATTENTION ---\n'
|| coalesce((
  select string_agg(c.relname || ': ' ||
    case when not c.relrowsecurity then 'RLS DISABLED - readable by anyone with the anon key'
         else 'RLS on but ZERO POLICIES - denies everyone except service_role' end,
    E'\n' order by c.relname)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and (not c.relrowsecurity
         or not exists (select 1 from pg_policy p where p.polrelid = c.oid))
), '(none - every table has RLS on with at least one policy)') as policies;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCK 4 — functions, and the overload check
-- ─────────────────────────────────────────────────────────────────────────────
select coalesce((
  select string_agg(
    p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
    || ' ' || case when p.prosecdef then 'DEFINER' else 'invoker' end
    || ' ' || coalesce(array_to_string(p.proconfig, ','), 'search_path=NOT-SET')
    || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')::text
    || ' authed=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text,
    E'\n' order by p.proname)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'), '(no functions)')
|| E'\n\n--- OVERLOADS SHARING A NAME (breaks every rpc() call) ---\n'
|| coalesce((
  select string_agg(proname || ': ' || sigs, E'\n')
  from (select p.proname,
               string_agg(pg_get_function_identity_arguments(p.oid), ' | ') as sigs
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
        group by p.proname having count(*) > 1) d), '(none - good)') as functions;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCK 5 — views and grants
-- ─────────────────────────────────────────────────────────────────────────────
select coalesce((
  select string_agg('VIEW ' || c.relname || ' security_invoker='
    || coalesce((select option_value from pg_options_to_table(c.reloptions)
                 where option_name = 'security_invoker'), 'OFF - runs as owner, bypasses RLS'),
    E'\n' order by c.relname)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'v'), '(no views)')
|| E'\n\n--- TABLE GRANTS ---\n'
|| coalesce((
  select string_agg(table_name || ' -> ' || g, E'\n' order by table_name)
  from (select table_name,
               string_agg(grantee || '(' || privs || ')', ' ' order by grantee) as g
        from (select table_name, grantee,
                     string_agg(distinct lower(privilege_type), ',' order by lower(privilege_type)) as privs
              from information_schema.role_table_grants
              where table_schema = 'public'
                and grantee in ('anon','authenticated','service_role','PUBLIC')
              group by table_name, grantee) x
        group by table_name) y), '(none)') as views_and_grants;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCK 6 — constraints, indexes, triggers
-- ─────────────────────────────────────────────────────────────────────────────
select coalesce((
  select string_agg(x.tbl || ': ' || x.d, E'\n' order by x.tbl)
  from (select c.relname as tbl,
               string_agg(con.conname || ' ' || pg_get_constraintdef(con.oid), ' | '
                          order by con.conname) as d
        from pg_constraint con
        join pg_class c on c.oid = con.conrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' group by c.relname) x), '(none)')
|| E'\n\n--- INDEXES ---\n'
|| coalesce((select string_agg(indexdef, E'\n' order by tablename, indexname)
             from pg_indexes where schemaname = 'public'), '(none)')
|| E'\n\n--- TRIGGERS ---\n'
|| coalesce((select string_agg(pg_get_triggerdef(t.oid), E'\n' order by t.tgname)
             from pg_trigger t
             join pg_class c on c.oid = t.tgrelid
             join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and not t.tgisinternal), '(none)') as constraints;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCK 7 — who can actually log in
-- ─────────────────────────────────────────────────────────────────────────────
select 'auth users total: ' || (select count(*) from auth.users)::text
|| E'\nsigned in at least once: ' || (select count(*) from auth.users where last_sign_in_at is not null)::text
|| E'\nfirst created: ' || coalesce((select min(created_at)::text from auth.users), '-')
|| E'\nmost recent created: ' || coalesce((select max(created_at)::text from auth.users), '-')
|| E'\n\n--- ACCOUNTS (domain only, no addresses) ---\n'
|| coalesce((select string_agg(d || ': ' || c::text, E'\n' order by d)
             from (select split_part(email, '@', 2) as d, count(*) as c
                   from auth.users group by 1) x), '(none)')
|| E'\n\n--- PROVIDERS ---\n'
|| coalesce((select string_agg(provider || ': ' || c::text, E'\n' order by provider)
             from (select provider, count(*) as c from auth.identities group by 1) y), '(none)')
  as auth_reality;

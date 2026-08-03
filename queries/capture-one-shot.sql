-- ONE-SHOT CAPTURE — the whole structure of a project in a single statement.
--
-- Two queries, in this order:
--   A (below)  everything from the catalog: tables, columns, RLS, functions,
--              views, grants, constraints, indexes, triggers.
--   B (bottom) the auth picture: account counts, providers.
--
-- WHY B IS SEPARATE, and not merged into A despite the extra paste:
-- PostgreSQL resolves every table reference in a statement before running any
-- of it. If auth.users cannot be read — restricted role, renamed relation — the
-- WHOLE statement errors and returns nothing, taking the catalog capture down
-- with it. Verified: a single unresolvable reference aborts the entire query.
-- A touches only pg_catalog and information_schema, which are always readable,
-- so A cannot fail this way. Keeping them apart means a problem with auth costs
-- you section B, not the entire capture.
--
-- Both return ONE text cell — one copy action, no table to scroll, nothing for
-- a chat interface to reformat.
--
-- Do NOT ask the AI chat to summarize the result. Paste the cell verbatim. The
-- point of this file is to record what the database actually says; a summary
-- records what a model said about it, which is a different and much weaker
-- claim.
--
-- READ-ONLY. No create, alter, drop, insert, update or delete anywhere.
--
-- VERIFIED 2026-08-03 against a throwaway PostgreSQL 16 instance carrying the
-- invoicing snapshot plus stand-ins for the uncaptured tables. Every detector
-- was confirmed to FIRE by seeding the fault it looks for: a table with RLS
-- off, a table with RLS on and no policies, a view without security_invoker,
-- and a duplicate function overload. Output was ~4.6 KB for seven tables.
-- Live projects are 17.6; these catalogs are stable across both.
--
-- Section 4 reports permissive vs RESTRICTIVE per policy. Restrictive is
-- shouted because it is the surprising one: permissive policies compose with OR
-- and any single pass grants access, restrictive compose with AND and must all
-- pass, so a restrictive policy gates every other policy on the table.
--
-- Section B reports COUNTS and email DOMAINS only — never addresses, never user
-- IDs — so its output is safe to paste back through a chat.


-- ─────────────────────────────────────────────────────────────────────────────
-- A — full structure
-- ─────────────────────────────────────────────────────────────────────────────

select
'SUPABASE CAPTURE  |  ' || now()::text || '  |  ' || version()

|| E'\n\n===== 1. WHAT EXISTS =====\n'
|| coalesce((select string_agg(line, E'\n' order by line) from (
     select c.relname
       || ' [' || case c.relkind when 'r' then 'table' when 'v' then 'view'
                                 when 'm' then 'matview' when 'p' then 'part' end || ']'
       || ' rls=' || case when c.relkind in ('r','p') then c.relrowsecurity::text else '-' end
       || ' pol=' || (select count(*) from pg_policy p where p.polrelid = c.oid)::text
       || ' cols=' || (select count(*) from pg_attribute a
                       where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped)::text
       || ' rows~' || case when c.reltuples < 0 then '?' else c.reltuples::bigint::text end as line
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r','v','m','p')) z), '(nothing in public)')

|| E'\n\n===== 2. NON-DEFAULT SCHEMAS =====\n'
|| coalesce((select string_agg(n.nspname, ', ' order by n.nspname)
     from pg_namespace n
     where n.nspname not in ('public','information_schema','pg_catalog','pg_toast')
       and n.nspname not like 'pg_temp%' and n.nspname not like 'pg_toast%'
       and n.nspname not in ('auth','storage','realtime','vault','extensions','graphql',
                             'graphql_public','supabase_functions','supabase_migrations',
                             'net','cron','pgsodium','pgsodium_masks','_realtime',
                             'pgbouncer','_analytics')), '(none beyond Supabase built-ins)')

|| E'\n\n===== 3. COLUMNS =====\n'
|| coalesce((select string_agg(blk, E'\n\n' order by tbl) from (
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
     group by c.relname) z), '(no tables)')

|| E'\n\n===== 4. RLS POLICIES =====\n'
|| coalesce((select string_agg(
     tablename || '.' || policyname
     || ' [' || case when permissive = 'PERMISSIVE' then 'permissive' else 'RESTRICTIVE' end
     || ' ' || cmd || ' to ' || array_to_string(roles, ',') || ']'
     || E'\n    USING ' || coalesce(qual, '(none)')
     || E'\n    CHECK ' || coalesce(with_check, '(none)'),
     E'\n\n' order by tablename, policyname)
   from pg_policies where schemaname = 'public'), '(NO POLICIES AT ALL)')

|| E'\n\n----- TABLES NEEDING ATTENTION -----\n'
|| coalesce((select string_agg(c.relname || ': ' ||
     case when not c.relrowsecurity then 'RLS DISABLED - readable by anyone with the anon key'
          else 'RLS on but ZERO POLICIES - denies everyone except service_role' end,
     E'\n' order by c.relname)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and (not c.relrowsecurity
          or not exists (select 1 from pg_policy p where p.polrelid = c.oid))),
   '(none - every table has RLS on with at least one policy)')

|| E'\n\n===== 5. FUNCTIONS =====\n'
|| coalesce((select string_agg(
     p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
     || ' ' || case when p.prosecdef then 'DEFINER' else 'invoker' end
     || ' ' || coalesce(array_to_string(p.proconfig, ','), 'search_path=NOT-SET')
     || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')::text
     || ' authed=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text,
     E'\n' order by p.proname)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'), '(no functions)')

|| E'\n\n----- OVERLOADS SHARING A NAME (breaks every rpc() call) -----\n'
|| coalesce((select string_agg(proname || ': ' || sigs, E'\n') from (
     select p.proname, string_agg(pg_get_function_identity_arguments(p.oid), ' | ') as sigs
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' group by p.proname having count(*) > 1) z),
   '(none - good)')

|| E'\n\n===== 6. VIEWS =====\n'
|| coalesce((select string_agg(c.relname || ' security_invoker='
     || coalesce((select option_value from pg_options_to_table(c.reloptions)
                  where option_name = 'security_invoker'), 'OFF - runs as owner, BYPASSES RLS'),
     E'\n' order by c.relname)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v'), '(no views)')

|| E'\n\n===== 7. GRANTS =====\n'
|| coalesce((select string_agg(table_name || ' -> ' || g, E'\n' order by table_name) from (
     select table_name, string_agg(grantee || '(' || privs || ')', ' ' order by grantee) as g
     from (select table_name, grantee,
                  string_agg(distinct lower(privilege_type), ',' order by lower(privilege_type)) as privs
           from information_schema.role_table_grants
           where table_schema = 'public'
             and grantee in ('anon','authenticated','service_role','PUBLIC')
           group by table_name, grantee) x
     group by table_name) z), '(none)')

|| E'\n\n===== 8. CONSTRAINTS =====\n'
|| coalesce((select string_agg(x.tbl || ': ' || x.d, E'\n' order by x.tbl) from (
     select c.relname as tbl,
            string_agg(con.conname || ' ' || pg_get_constraintdef(con.oid), ' | '
                       order by con.conname) as d
     from pg_constraint con
     join pg_class c on c.oid = con.conrelid
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' group by c.relname) x), '(none)')

|| E'\n\n===== 9. INDEXES =====\n'
|| coalesce((select string_agg(indexdef, E'\n' order by tablename, indexname)
     from pg_indexes where schemaname = 'public'), '(none)')

|| E'\n\n===== 10. TRIGGERS =====\n'
|| coalesce((select string_agg(pg_get_triggerdef(t.oid), E'\n' order by t.tgname)
     from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and not t.tgisinternal), '(none)')

|| E'\n\n===== END ====='
  as supabase_capture;

-- ─────────────────────────────────────────────────────────────────────────────
-- B — auth reality check
-- ─────────────────────────────────────────────────────────────────────────────
-- On a shared project this decides the blast radius of any
-- `auth.role() = 'authenticated'` policy. Whether signups are open is the one
-- thing still not answerable in SQL — that is Authentication > Providers in the
-- dashboard.

select 'AUTH  |  ' || now()::text
|| E'\n\ntotal accounts: ' || (select count(*) from auth.users)::text
|| E'\nsigned in at least once: ' || (select count(*) from auth.users where last_sign_in_at is not null)::text
|| E'\nnewest account created: ' || coalesce((select max(created_at)::text from auth.users), '-')
|| E'\n\n----- ACCOUNTS BY EMAIL DOMAIN (no addresses) -----\n'
|| coalesce((select string_agg(d || ': ' || c::text, E'\n' order by d)
     from (select split_part(email,'@',2) as d, count(*) as c from auth.users group by 1) x), '(none)')
|| E'\n\n----- PROVIDERS -----\n'
|| coalesce((select string_agg(provider || ': ' || c::text, E'\n' order by provider)
     from (select provider, count(*) as c from auth.identities group by 1) y), '(none)')
  as auth_capture;

-- Is anything on this project readable by someone who should not see it?
--
-- Run the four checks below in the SQL Editor. Each is independent — run them
-- one at a time if a tool chokes on one, because a failure in one must not hide
-- the others. Every check should come back empty.
--
-- Checks 3 and 4 exist because checks 1 and 2 were once believed to be enough.
-- They were not: on 2026-08-09 every table on this project was correctly gated
-- and two views were still handing the data out — one of them to the internet.
-- See the note at the bottom.


-- 1. Tables with row level security switched off entirely.
--    Worse than a permissive policy, because no policy audit would ever see it.

select c.relname as table_without_rls
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
order by 1;


-- 2. Policies open to every logged-in account.
--    `auth.role() = 'authenticated'` reads as a restriction and is not one on a
--    shared project: it means anyone with an account on ANY app here.

select tablename, policyname, cmd, coalesce(qual, with_check) as expr
from pg_policies
where schemaname = 'public'
  and (coalesce(qual, with_check, 'true') = 'true'
       or coalesce(qual, '') || coalesce(with_check, '') like '%auth.role()%')
order by tablename, policyname;


-- 3. Views that bypass the policies underneath them.
--    A view created without security_invoker reads its tables with its OWNER's
--    rights. Grant it to authenticated and every gated table beneath it is
--    readable by anyone signed into anything on this project. Views have no
--    policies of their own, so check 2 cannot see this.

select c.relname as view_bypassing_rls,
       pg_get_userbyid(c.relowner) as owner
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('v', 'm')
  and coalesce((select option_value from pg_options_to_table(c.reloptions)
                where option_name = 'security_invoker'), 'false') not in ('true', 'on')
order by 1;


-- 4. Anything anon can read that nothing will then filter.
--
--    NOT simply "what can anon select". Supabase grants table-level SELECT to
--    anon and authenticated across public by default and leans on RLS to filter
--    the rows, so a bare privilege check returns almost every relation and
--    teaches you to skim past it. A check that always fires is not a check.
--
--    What actually matters is a grant with nothing behind it: a table with RLS
--    switched off, or a view that does not defer to the caller. Either way the
--    grant is the only gate, and anon is the publishable key that ships in
--    public HTML.
--
--    This is precisely the shape invoices_et had.
--
--    c.oid rather than 'public.' || relname: has_table_privilege re-parses a
--    text name through the search path, which on this project failed with a
--    misleading "relation public.pg_stat_statements_info does not exist" — an
--    extension artifact, nothing being audited, but it took the check out
--    entirely. The oid form cannot hit it.

select c.relname as unprotected_and_readable_by_anon,
       case when c.relkind = 'r' then 'table with RLS disabled'
            else 'view without security_invoker' end as why
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and has_table_privilege('anon', c.oid, 'SELECT')
  and (
    (c.relkind = 'r' and not c.relrowsecurity)
    or (c.relkind in ('v','m')
        and coalesce((select option_value from pg_options_to_table(c.reloptions)
                      where option_name = 'security_invoker'), 'false') not in ('true','on'))
  )
order by 1;


-- 5. SECURITY DEFINER functions that are reachable and not pinned down.
--
--    These run as their owner, so they see past every policy on this project.
--    That is what makes has_app_access() and list_app_users() work at all, and
--    it is also why a careless one is worse than any open policy: checks 1-4
--    inspect tables and views, and cannot see a function that hands out their
--    contents.
--
--    Two ways one goes wrong, and this returns only those — a check that fires
--    on the healthy case teaches you to skim past it:
--
--      no pinned search_path — an unqualified name inside the body resolves
--      through the CALLER's search path, so the caller chooses which table the
--      function reads while running as the owner
--
--      executable by anon — the publishable key ships in public HTML, so this
--      is the internet holding the owner's rights
--
--    MUST RETURN NO ROWS.

select p.proname as definer_function,
       pg_get_function_identity_arguments(p.oid) as args,
       case when has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'callable by anon' else 'search_path not pinned' end as why
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prosecdef
  and (has_function_privilege('anon', p.oid, 'EXECUTE')
       or not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                      where c like 'search\_path=%'))
order by 1;

--    The companion to that check is reading the list itself, which no query can
--    do for you. There should be five, they should all be recognisable, and
--    invite_app_user is the one to look at hardest — it holds the secret key
--    and can create accounts:
--
--      select p.proname, pg_get_function_identity_arguments(p.oid) as args,
--             array_to_string(p.proconfig, ', ') as config
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--      where n.nspname = 'public' and p.prosecdef order by 1;
--
--    Expected: app_role, has_app_access, invite_app_user, is_platform_admin,
--    list_app_users. Anything else on that list is either new and deliberate,
--    or the most urgent thing on this project.


-- 6. The checks above are static analysis. The real question is what a caller
--    actually gets, and only the database can answer that. Impersonate and
--    count — see verify_access.sql for the full pattern:
--
--      select set_config('request.jwt.claims', '', false);
--      set role anon;
--      select count(*) from public.claims;    -- and invoices, profiles, ...
--      reset role;
--
--    Run against anon, and against an account holding no grant for the app in
--    question. Both must return 0.
--
--    Verified 2026-08-09 — anon reads 0 rows from claims, invoices,
--    job_postings, profiles and cartmatch_retailer_reliability.


-- Fixing a view found by check 3:
--
--   alter view public.<name> set (security_invoker = true);
--
-- Check first that every table it reads has a SELECT policy the caller can
-- satisfy. job_postings had none — the app only ever reached it through the
-- view — so flipping the view without adding a policy would have emptied the
-- app rather than secured it.
--
-- Fixing something found by check 4 is `revoke select on public.<name> from
-- anon`, unless it is meant to be public. Public data should be a view that
-- excludes anything sensitive, reached through a function that takes a token —
-- never a blanket grant on a view built from the whole table.


-- ---------------------------------------------------------------------------
-- What these checks cost us before they existed — 2026-08-09
--
-- job_ranked: no security_invoker, granted to authenticated. Every job_* table
-- was correctly gated and all 1,337 postings, match write-ups and application
-- statuses were readable straight through the view by accounts with no 'job'
-- grant. Fixed by adding a SELECT policy to job_postings, then flipping the
-- view.
--
-- invoices_et: no security_invoker AND granted to anon. Every invoice — client
-- names, email addresses, street addresses, amounts, notes — was readable by
-- anyone holding the publishable key, which ships in public HTML. The view also
-- exposed view_token, the column that authorises public invoice links, so the
-- tokens leaked with the data. Fixed by revoking anon and flipping the view;
-- the tokens should be regenerated, because a secret that was world-readable is
-- not a secret any more.
--
-- invoice_public_v was already correct — security_invoker on, granted to
-- nobody, and it excludes view_token. It is the right shape for a public
-- endpoint and appears to be a replacement someone started and never finished
-- switching to.
--
-- The lesson worth keeping: "every table is gated" was true, and the data was
-- being handed out anyway. Gating tables is not the same as gating access.

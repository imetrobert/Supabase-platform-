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


-- 4. Anything the anonymous role can read.
--    anon is the publishable key, which ships in public HTML. Whatever appears
--    here is readable by anyone who visits any of these sites. A deliberately
--    public endpoint may legitimately appear — but it must be a deliberate
--    decision, made once, and not a leftover grant.

-- Note the c.oid rather than a constructed 'public.' || relname string.
-- has_table_privilege re-parses a text name and resolves it through the search
-- path, which failed on this project with a misleading "relation
-- public.pg_stat_statements_info does not exist" — an extension artifact, not
-- anything being audited. The oid form skips resolution and cannot hit it.

select c.relname as anon_can_read, c.relkind
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'v', 'm')
  and has_table_privilege('anon', c.oid, 'SELECT')
order by 1;


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

-- Prove an app's RLS actually holds, by impersonating real users at the database
-- level. Run in the Supabase SQL Editor as one script; the final SELECT carries
-- every result, because the editor only displays the last result set.
--
-- Reads and writes are exercised, then undone. G and H prove nothing was left
-- behind. Swap the two emails, the table and the app name to check another app.
--
-- Run this whenever you apply app_access_pattern.sql to a new table. A read-only
-- check is not enough: a broken INSERT or UPDATE policy stays invisible until the
-- next time someone tries to save something.

create temp table if not exists _probe(seq int, label text, result text);
delete from _probe;
grant all on _probe to authenticated;

-- ---- as the authorized user -------------------------------------------------
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role','authenticated')::text
   from auth.users where email='robert@imetrobert.com'), false);
set role authenticated;

insert into _probe select 1,'A. owner reads (want 264)', count(*)::text from public.claims;
insert into _probe select 2,'B. owner has grant (want true)', public.has_app_access('claims-tracker')::text;

insert into public.claims (person, service, service_date, tax_year, amount_submitted, amount_paid, insurer)
values ('RLS PROBE','probe','2025-01-01',2025,1.00,0.00,'probe');
insert into _probe select 3,'C. owner inserts (want 1)', count(*)::text from public.claims where person='RLS PROBE';

update public.claims set status='excluded' where person='RLS PROBE';
insert into _probe select 4,'D. owner updates (want 1)', count(*)::text from public.claims where person='RLS PROBE' and status='excluded';

-- Expected to affect nothing: there is no DELETE policy, so RLS filters the row
-- out rather than raising an error. E returning 1 is the pass condition.
delete from public.claims where person='RLS PROBE';
insert into _probe select 5,'E. delete blocked (want 1)', count(*)::text from public.claims where person='RLS PROBE';

-- ---- as a different user of the same project --------------------------------
-- The point of the whole exercise. auth.users must be read as the admin role,
-- so drop back before looking the second user up.
reset role;
select set_config('request.jwt.claims',
  (select json_build_object('sub', id, 'role','authenticated')::text
   from auth.users where email='oboulian@gmail.com'), false);
set role authenticated;
insert into _probe select 6,'F. OTHER USER reads (want 0)', count(*)::text from public.claims;

-- ---- clean up ---------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '', false);
delete from public.claims where person='RLS PROBE';

insert into _probe select 7,'G. rows after cleanup (want 264)', count(*)::text from public.claims;
insert into _probe select 8,'H. checksum', md5(string_agg(
    id::text || '|' || person || '|' || service || '|' || service_date::text || '|'
    || tax_year::text || '|' || amount_submitted::text || '|' || amount_paid::text || '|'
    || coalesce(insurer,'~NULL~') || '|' || status || '|' || coalesce(flag_status,'~NULL~')
    || '|' || coalesce(note,'~NULL~') || '|'
    || to_char(created_at at time zone 'UTC','YYYY-MM-DD HH24:MI:SS.US')
  , E'\n' order by id::text)) from public.claims;

select seq, label, result from _probe order by seq;

-- Reading the result: A must be 264 and F must be 0. If A comes back 0 and B
-- false, the impersonation did not take and the run is inconclusive rather than
-- a failure — F only means something once A shows the mechanism works.
--
-- Result on 2026-08-09: A=264 B=true C=1 D=1 E=1 F=0 G=264
-- H=15a439699d3966dee7aaffbae7cec639


-- ---------------------------------------------------------------------------
-- Variant for a PERSONAL table
--
-- Two differences from the version above, both of which will bite if copied
-- carelessly.
--
-- First, a refused INSERT does not return zero rows — an RLS WITH CHECK
-- violation RAISES. Unhandled, it aborts the whole script and you lose every
-- result collected so far. Wrap it:
--
--   do $$
--   begin
--     insert into public.profiles (user_id, data) values (auth.uid(), '{"probe":true}'::jsonb);
--     insert into _probe values (6,'other user inserts (want blocked)','ALLOWED — PROBLEM');
--   exception when others then
--     insert into _probe values (6,'other user inserts (want blocked)','blocked (' || sqlerrm || ')');
--   end $$;
--
-- A refused SELECT, DELETE or UPDATE is the opposite: RLS filters the rows away
-- silently, so those are counted rather than caught.
--
-- Second, clean up by content rather than by trusting the refusal:
--   delete from public.profiles where data ? 'probe';
--
-- Run this against every app whose tests stub the access check. A static-site
-- suite can prove the browser gate and its fail-closed behaviour; it can never
-- prove the policy, because it never speaks to Postgres.
--
-- Result on 2026-08-09, profiles / fb-marketplace, robert vs oboulian:
--   owner: grant=true, reads 1, updates own row (rows=1)
--   other: grant=false, reads 0,
--          insert blocked — "new row violates row-level security policy
--          for table profiles"
--   profiles row count unchanged at 1 afterwards

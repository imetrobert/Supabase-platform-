-- Decommission CartMatch (Price Checker, pricecheck.imetrobert.com).
--
-- Run in the Supabase SQL editor of project ipnajvgwtjrlecbqfwrh, in order:
--   STEP 1  preview      read-only, shows exactly what will go
--   STEP 2  drop         one transaction; removes ONLY cartmatch objects
--   STEP 3  verify       every query should return 0 rows
--
-- THIS PROJECT IS SHARED by claims-tracker, invoicing, etf, job and
-- fb-marketplace. Nothing here touches auth.users or any non-cartmatch table.
-- Everything is matched by the `cartmatch` prefix or app = 'cartmatch'.
--
-- NOT done here (SQL cannot, or must not):
--   * storage bucket `cartmatch-flyers`  -> Dashboard > Storage (SQL delete is blocked)
--   * Edge Functions cartmatch-*         -> Dashboard > Edge Functions
--   * Edge Function secrets CARTMATCH_*  -> Dashboard > Edge Functions > Secrets
--
-- Optional first: export anything you want to keep (Dashboard > Table Editor >
-- Export CSV) from cartmatch_price_observations / cartmatch_validations.

-- ============================================================ STEP 1: PREVIEW
select 'cron job' as kind, jobname as name from cron.job where jobname ilike 'cartmatch%'
union all
select 'table', tablename from pg_tables where schemaname = 'public' and tablename ilike 'cartmatch\_%'
union all
select 'view', viewname from pg_views where schemaname = 'public' and viewname ilike 'cartmatch\_%'
union all
select 'function', p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname ilike 'cartmatch\_%'
union all
select 'storage policy', policyname from pg_policies
  where schemaname = 'storage' and tablename = 'objects' and policyname ilike 'cartmatch%'
union all
select 'app_access rows', count(*)::text from public.app_access where app = 'cartmatch'
order by 1, 2;

-- ============================================================== STEP 2: DROP
-- Stop the schedules first so nothing fires mid-drop.
begin;

do $$
declare r record;
begin
  -- 1. cron jobs (worker, Flipp import, purge)
  for r in select jobname from cron.job where jobname ilike 'cartmatch%' loop
    perform cron.unschedule(r.jobname);
  end loop;

  -- 2. storage policies (bucket + objects are removed from the Dashboard)
  for r in select policyname from pg_policies
           where schemaname = 'storage' and tablename = 'objects'
             and policyname ilike 'cartmatch%' loop
    begin
      execute format('drop policy %I on storage.objects', r.policyname);
    exception when insufficient_privilege then
      raise notice 'Could not drop storage policy "%": delete it in Dashboard > Storage > Policies', r.policyname;
    end;
  end loop;

  -- 3. views, then tables (CASCADE removes their policies, triggers, indexes)
  for r in select viewname from pg_views
           where schemaname = 'public' and viewname ilike 'cartmatch\_%' loop
    execute format('drop view if exists public.%I cascade', r.viewname);
  end loop;
  for r in select tablename from pg_tables
           where schemaname = 'public' and tablename ilike 'cartmatch\_%' loop
    execute format('drop table if exists public.%I cascade', r.tablename);
  end loop;

  -- 4. functions (any argument signature)
  for r in select p.oid::regprocedure as sig from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname ilike 'cartmatch\_%' loop
    execute format('drop function if exists %s cascade', r.sig);
  end loop;
end $$;

-- 5. access grants for the app
delete from public.app_access where app = 'cartmatch';

commit;

-- ============================================================= STEP 3: VERIFY
-- Each of these should return zero rows.
select jobname from cron.job where jobname ilike 'cartmatch%';
select tablename from pg_tables where schemaname = 'public' and tablename ilike 'cartmatch\_%';
select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname ilike 'cartmatch\_%';
select policyname from pg_policies where tablename = 'objects' and policyname ilike 'cartmatch%';
select app from public.app_access where app = 'cartmatch';
-- Sanity: other apps untouched (expect your usual counts).
select count(*) as other_app_grants from public.app_access;

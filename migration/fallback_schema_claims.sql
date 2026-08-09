-- Fallback schema for the `claims` table used by imetrobert/claims-tracker.
--
-- IMPORTANT: this is RECONSTRUCTED from how index.html reads and writes the table,
-- not dumped from the live database. Column names and the status/flag vocabularies
-- are certain (the app uses them literally); exact types, the `id` type, defaults,
-- and the original RLS policies are educated guesses.
--
-- Prefer migrate.sh, which copies the real definitions. Use this file only if you
-- cannot get a database password for the old project and are rebuilding by hand —
-- in that case load the data with import_claims.sh, which goes through the API.

create extension if not exists "pgcrypto";

create table if not exists public.claims (
  id                uuid primary key default gen_random_uuid(),

  -- Written on insert from the extracted screenshot rows (saveReviewed()).
  person            text not null,
  service           text,
  service_date      date,
  tax_year          integer,
  amount_submitted  numeric(12,2),
  amount_paid       numeric(12,2),
  insurer           text,

  -- 'active' is set explicitly on insert; the other two come from the Dup/Excl.
  -- buttons in the claims table, and 'duplicate' is also set when a flag is
  -- resolved as a confirmed duplicate.
  status            text not null default 'active'
                      check (status in ('active','duplicate','excluded')),

  -- Null until detectSuspectedDuplicates() flags the row. The app treats any
  -- non-null value as "already reviewed", so it never re-flags a resolved row.
  flag_status       text
                      check (flag_status in ('suspected','confirmed_duplicate','rejected_not_duplicate')),

  created_at        timestamptz not null default now()
);

-- The claims list is always ordered by service_date desc, and the summary tab
-- filters by tax_year.
create index if not exists claims_service_date_idx on public.claims (service_date desc);
create index if not exists claims_tax_year_idx     on public.claims (tax_year);

-- Duplicate detection groups on exactly these three columns.
create index if not exists claims_dedupe_idx
  on public.claims (person, amount_submitted, service_date);

-- Row level security ------------------------------------------------------
-- The app ships a publishable (anon) key in a public HTML file, so the table must
-- NOT be reachable by the anon role — access is gated on being logged in. There is
-- no user_id column, so every authenticated user sees the same rows; that matches
-- the current single-account setup. If you ever add a second login, add a user_id
-- column and scope these policies with `auth.uid() = user_id`.

alter table public.claims enable row level security;

drop policy if exists "authenticated read claims"   on public.claims;
drop policy if exists "authenticated insert claims" on public.claims;
drop policy if exists "authenticated update claims" on public.claims;
drop policy if exists "authenticated delete claims" on public.claims;

create policy "authenticated read claims"
  on public.claims for select to authenticated using (true);

create policy "authenticated insert claims"
  on public.claims for insert to authenticated with check (true);

create policy "authenticated update claims"
  on public.claims for update to authenticated using (true) with check (true);

create policy "authenticated delete claims"
  on public.claims for delete to authenticated using (true);

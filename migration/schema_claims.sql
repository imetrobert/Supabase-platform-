-- The `claims` table, as verified against the live old project on 2026-08-09.
--
-- This is not a reconstruction: every column, type, default, index name and policy
-- below was read out of the old project's catalog and confirmed byte-identical in
-- the new project afterwards. This is what claims-tracker actually runs on.
--
-- Note `note` — a column the app never reads or writes, but which exists and must
-- not be dropped. It is NULL in all 264 rows today.

create table public.claims (
  id                uuid           not null default gen_random_uuid(),
  person            text           not null,
  service           text           not null,
  service_date      date           not null,
  tax_year          integer        not null,
  amount_submitted  numeric(10,2)  not null,
  amount_paid       numeric(10,2)  not null default 0,
  insurer           text,
  status            text           not null default 'active'::text,
  flag_status       text,
  note              text,
  created_at        timestamptz    not null default now(),
  constraint claims_pkey primary key (id)
);

-- The primary key is the only constraint. There are deliberately no CHECK
-- constraints on status or flag_status — the app's vocabularies are
--   status      : active | duplicate | excluded
--   flag_status : NULL | suspected | confirmed_duplicate | rejected_not_duplicate
-- but the database does not enforce them, and adding enforcement now would be a
-- behaviour change, not a migration.

create index claims_dedupe_idx   on public.claims using btree (person, amount_submitted, service_date);
create index claims_person_idx   on public.claims using btree (person);
create index claims_tax_year_idx on public.claims using btree (tax_year);

-- claims_dedupe_idx backs detectSuspectedDuplicates(), which groups on exactly
-- (person, amount_submitted, service_date).

-- For RLS, see app_access_pattern.sql. The old project used
-- `auth.role() = 'authenticated'`, which is not safe in the shared project this
-- table now lives in.

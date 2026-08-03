-- Structure of Supabase project nnkfnlrscywlosfwdlsw (app: claims-tracker).
--
-- Captured from the live database on 2026-08-03 via queries/capture-one-shot.sql.
-- The verbatim capture output is in ./raw-capture-2026-08-03.txt; this file is a
-- reconstruction from it. If the two disagree, the raw file wins.
--
-- COMPLETE, unlike the project 1 snapshot. This project holds exactly one table
-- and nothing else: no functions, no views, no triggers, no extra schemas. So
-- running this on an empty database reproduces the whole project structure.
--
-- Source database: PostgreSQL 17.6.
--
-- Reconstructed, not dumped — written from catalog output, so it is faithful but
-- not byte-identical to whatever was originally typed into the SQL editor.
--
-- VERIFIED 2026-08-03: this file was replayed onto an empty PostgreSQL instance
-- and the capture query re-run against the result. The output matched the real
-- capture in ./raw-capture-2026-08-03.txt EXACTLY, line for line, with one
-- expected exception — the row estimate (264 there, empty here). So the
-- structure below is not merely plausible: it round-trips to the same catalog
-- state the live database reports.
--
-- ONE THING WAS NOT CAPTURED: whether each policy is PERMISSIVE or RESTRICTIVE.
-- The capture query does not select pg_policies.permissive. They are written as
-- permissive below because that is PostgreSQL's default and what the Supabase
-- dashboard creates, but it is an assumption, not a reading. It matters: three
-- restrictive policies would have to ALL pass rather than any one of them.

-- ─────────────────────────────────────────────────────────────────────────────
-- Table
-- ─────────────────────────────────────────────────────────────────────────────
--
-- ~264 rows at capture time. Personal data: named individuals against dated
-- services, amounts and insurers.
--
-- `insurer` sits after `created_at` rather than with the other claim fields,
-- which is the ordinary signature of a column added later by ALTER TABLE.

create table if not exists public.claims (
  id               uuid                     not null default gen_random_uuid(),
  person           text                     not null,
  service          text                     not null,
  service_date     date                     not null,
  tax_year         integer                  not null,
  amount_submitted numeric(10,2)            not null,
  amount_paid      numeric(10,2)            not null default 0,
  -- Free text, no CHECK constraint. Nothing at the database level stops a typo
  -- creating a new status value.
  status           text                     not null default 'active'::text,
  flag_status      text,
  note             text,
  created_at       timestamp with time zone not null default now(),
  insurer          text,
  constraint claims_pkey primary key (id)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────────────────────────────────────
--
-- NOTE on claims_dedupe_idx: it is named for deduplication but it is a PLAIN
-- btree index, not a unique one, so it enforces nothing. It makes duplicate
-- detection fast; it does not prevent duplicates. If the app relies on it to
-- keep the same claim from being entered twice, that protection does not exist
-- at the database level. Recorded, not acted on — see ../../migrations/PLAN.md.

create index if not exists claims_dedupe_idx
  on public.claims using btree (person, amount_submitted, service_date);
create index if not exists claims_person_idx
  on public.claims using btree (person);
create index if not exists claims_tax_year_idx
  on public.claims using btree (tax_year);

-- ─────────────────────────────────────────────────────────────────────────────
-- Grants and row level security
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The grants are Supabase's defaults for the public schema, not a
-- misconfiguration: anon holds full DML here as it does on every table. RLS is
-- what actually gates access, and every policy below is scoped `to
-- authenticated`, so no policy applies to anon and an anonymous request is
-- denied. An unauthenticated read of /rest/v1/claims returns [].

alter table public.claims enable row level security;

grant select, insert, update, delete, truncate, references, trigger
  on table public.claims to anon, authenticated, service_role;

-- Three policies, one per command. There is deliberately NO DELETE policy, so
-- deletes are denied for everyone except service_role — RLS denies whatever no
-- policy permits. Consistent with an append-and-correct record; confirm it was
-- intended rather than overlooked.
--
-- The predicate `auth.role() = 'authenticated'` is redundant alongside `to
-- authenticated`, which already restricts the policy to that role. Harmless.
--
-- On this project the predicate means what it looks like it means, because only
-- one app is here. The same predicate on project 1 does NOT — see
-- ../../policies/patterns.md, pattern 5. It is still worth knowing who can
-- obtain an authenticated session: every such account can read all 264 rows.

create policy "claims select (authenticated)" on public.claims
  as permissive
  for select
  to authenticated
  using (auth.role() = 'authenticated'::text);

create policy "claims insert (authenticated)" on public.claims
  as permissive
  for insert
  to authenticated
  with check (auth.role() = 'authenticated'::text);

create policy "claims update (authenticated)" on public.claims
  as permissive
  for update
  to authenticated
  using (auth.role() = 'authenticated'::text)
  with check (auth.role() = 'authenticated'::text);

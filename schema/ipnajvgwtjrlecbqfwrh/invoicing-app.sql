-- ═════════════════════════════════════════════════════════════════════════════
-- COPY. The original of this file lives in the invoicing app's own repo, at
-- imetrobert/Ai-with-Robert-Invoicing-System:supabase/schema.sql, and that copy
-- is the one to trust if the two ever differ. It is duplicated here so this
-- repo holds a complete picture of the project without depending on another
-- repo staying reachable. Transcribed verbatim on 2026-08-03; the header below
-- is the original author's.
--
-- Covers the invoicing app ONLY — roughly half of what is in this project. See
-- ./README.md for what is missing.
-- ═════════════════════════════════════════════════════════════════════════════

-- Structure of this app's tables in Supabase project ipnajvgwtjrlecbqfwrh.
--
-- Captured from the live database on 2026-08-03, AFTER everything in
-- ./migrations/ had been applied. It is a snapshot of current state, not a
-- historical baseline — run it on an empty database and you get today's
-- structure directly, with no need to replay the migrations on top.
--
-- Why this file exists: none of this schema was ever in version control. It was
-- built by hand in the Supabase SQL editor over time, and the README used to
-- point at a `supabase-setup.sql` that has never existed in this repo. Losing
-- the Supabase project meant rebuilding from memory.
--
-- Reconstructed from catalog queries (pg_attribute, pg_constraint, pg_indexes,
-- pg_policies, pg_trigger, pg_get_functiondef, information_schema grants), not
-- from pg_dump — an iPhone was the only tool available. Function, trigger and
-- view bodies are verbatim; the table, grant and policy statements were written
-- from catalog output and are faithful but not byte-identical to the originals.
--
-- SCOPE: this app only. The Supabase project is shared with other apps, whose
-- tables (etf_*, job_*, profiles) are deliberately absent. `survey_responses` is
-- read by this app's survey screens but is also absent — it is part of separate
-- authorization work and was left untouched on purpose. This file is therefore
-- NOT a complete backup of the project.
--
-- Source database: PostgreSQL 17.6.

-- ─────────────────────────────────────────────────────────────────────────────
-- Table
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.invoices (
  id                 uuid                     not null default gen_random_uuid(),
  invoice_number     text                     not null,
  client_name        text                     not null,
  client_email       text,
  service_date       date                     not null,
  services           jsonb                    not null default '[]'::jsonb,
  subtotal           numeric(10,2)            not null default 0,
  discount_type      text                              default 'none'::text,
  discount_value     numeric(10,2)                     default 0,
  discount_amount    numeric(10,2)                     default 0,
  gst_enabled        boolean                           default false,
  gst_amount         numeric(10,2)                     default 0,
  total              numeric(10,2)            not null default 0,
  notes              text,
  status             text                              default 'draft'::text,
  created_at         timestamp with time zone          default now(),
  updated_at         timestamp with time zone          default now(),
  emailed_at         timestamp with time zone,
  province           text,
  address_line1      text,
  address_line2      text,
  address_city       text,
  address_postal     text,
  -- Client-facing link code. 122 bits of randomness; the tokenized viewer at
  -- /#/invoice/public/<view_token> resolves it through invoice_by_token below.
  view_token         uuid                              default gen_random_uuid(),
  view_count         integer                           default 0,
  first_viewed_at    timestamp with time zone,
  pdf_download_count integer                           default 0,
  -- Every send timestamp, not just the latest, so the dashboard's EmailJS quota
  -- tracker can count actual sends per cycle rather than distinct invoices.
  email_log          jsonb                    not null default '[]'::jsonb,
  constraint invoices_pkey primary key (id),
  constraint invoices_invoice_number_key unique (invoice_number)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────────────────────────────────────

create index if not exists idx_invoices_client_name on public.invoices using btree (client_name);
create index if not exists idx_invoices_created_at  on public.invoices using btree (created_at desc);
create index if not exists idx_invoices_status      on public.invoices using btree (status);

-- Added 2026-08-03. InvoicePublic.jsx takes data[0] rather than .single(), so
-- two rows sharing a token would silently render one client's invoice to
-- another. NULL tokens on drafts are unaffected — unique permits many NULLs.
create unique index if not exists invoices_view_token_key on public.invoices using btree (view_token);

-- ─────────────────────────────────────────────────────────────────────────────
-- updated_at trigger
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Not SECURITY DEFINER, so the search_path hardening applied to the other
-- functions on 2026-08-03 does not apply here — it runs as the calling user.

create or replace function public.update_updated_at_column()
 returns trigger
 language plpgsql
as $function$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$function$;

drop trigger if exists invoices_updated_at on public.invoices;
create trigger invoices_updated_at
  before update on public.invoices
  for each row execute function public.update_updated_at_column();

-- ─────────────────────────────────────────────────────────────────────────────
-- Grants and row level security
-- ─────────────────────────────────────────────────────────────────────────────
--
-- These table-level grants are Supabase's defaults for the public schema, not a
-- misconfiguration: anon and authenticated hold full DML privileges on every
-- table, and RLS is what actually gates access. Nothing anonymous can read or
-- write public.invoices, because the only policy below requires an
-- authenticated session and no anonymous policy exists.
--
-- NOTE, recorded and deliberately not acted on: the surviving policy grants
-- access to ANY authenticated account on this shared project, not only this
-- app's owner. That is known, is a real issue, and belongs to separate
-- cross-app authorization work — see ../SECURITY.md.

alter table public.invoices enable row level security;

grant select, insert, update, delete, truncate, references, trigger
  on table public.invoices to anon, authenticated, service_role;

drop policy if exists "Authenticated users only" on public.invoices;
create policy "Authenticated users only" on public.invoices
  as permissive
  for all
  to public
  using (auth.role() = 'authenticated'::text)
  with check (auth.role() = 'authenticated'::text);

-- ─────────────────────────────────────────────────────────────────────────────
-- Client-facing view
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Fixes the column list a client may see. Excludes view_token, email_log,
-- emailed_at, view_count, first_viewed_at, pdf_download_count and updated_at.
--
-- security_invoker = on matters: without it a view runs with its owner's rights
-- and would read invoices with RLS bypassed, so PostgREST exposing it at
-- /rest/v1/invoice_public_v would re-open anonymous access to every invoice.
-- With it on, the view is subject to the caller's own RLS. invoice_by_token
-- still works because it is SECURITY DEFINER and runs as postgres, which owns
-- the table and is not forced under RLS.
--
-- The revoke is kept as well — belt and braces, not one replacing the other.

create or replace view public.invoice_public_v
with (security_invoker = on) as
 select id,
    invoice_number,
    client_name,
    client_email,
    address_line1,
    address_line2,
    address_city,
    address_postal,
    province,
    service_date,
    created_at,
    services,
    subtotal,
    discount_type,
    discount_value,
    discount_amount,
    gst_enabled,
    gst_amount,
    total,
    notes,
    status
   from invoices;

revoke all on table public.invoice_public_v from anon, authenticated, public;
grant all on table public.invoice_public_v to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- Functions
-- ─────────────────────────────────────────────────────────────────────────────
--
-- All three are SECURITY DEFINER with search_path pinned to 'public', 'pg_temp'.
-- pg_temp is listed last on purpose: when it is not listed at all, PostgreSQL
-- searches the temporary schema FIRST for relation names.
--
-- All three take the token as an ARGUMENT and compare with view_token::text.
-- That is the whole security model — RLS is evaluated per row and cannot see the
-- token in the URL or a filter on the request, so scoping expressed as a request
-- filter is scoping the caller can remove. See ../SECURITY.md.
--
-- increment_invoice_view once existed as both (token text) and (token uuid).
-- PostgREST resolves RPC arguments by name, not type, so the call was ambiguous
-- and click counting silently failed for two months. The uuid overload was
-- dropped on 2026-08-03; do not recreate it.

create or replace function public.increment_invoice_view(token text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
BEGIN
  UPDATE invoices
  SET
    view_count = COALESCE(view_count, 0) + 1,
    first_viewed_at = COALESCE(first_viewed_at, NOW())
  WHERE view_token::text = token;
END;
$function$;

create or replace function public.increment_invoice_pdf_download(token text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
BEGIN
  UPDATE invoices
  SET
    pdf_download_count = COALESCE(pdf_download_count, 0) + 1
  WHERE view_token::text = token;
END;
$function$;

create or replace function public.invoice_by_token(token text)
 returns setof invoice_public_v
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select v.*
  from public.invoice_public_v v
  where v.id in (
    select i.id from public.invoices i where i.view_token::text = token
  );
$function$;

revoke all on function public.invoice_by_token(text) from public;
grant execute on function public.invoice_by_token(text) to anon, authenticated;

notify pgrst, 'reload schema';

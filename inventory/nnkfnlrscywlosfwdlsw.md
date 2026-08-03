# Project 2 — `nnkfnlrscywlosfwdlsw`

**Standalone.** One app, `claims-tracker`. Shares nothing with
[project 1](ipnajvgwtjrlecbqfwrh.md).

- PostgreSQL 17.6
- API base: `https://nnkfnlrscywlosfwdlsw.supabase.co`
- Structure captured **2026-08-03** — complete. Auth not yet captured.

---

## App

### claims-tracker — [`imetrobert/claims-tracker`](https://github.com/imetrobert/claims-tracker)

Stack, deploy target and key storage are **UNKNOWN** — the repo is not attached
to this session and nothing about the app itself has been read. Everything
below comes from the database.

## Structure

The whole project is **one table**. No functions, no views, no triggers, no
non-default schemas. Full DDL in
[`../schema/nnkfnlrscywlosfwdlsw/claims-tracker.sql`](../schema/nnkfnlrscywlosfwdlsw/claims-tracker.sql),
with the verbatim capture alongside it.

| Object | Kind | Rows | RLS | Policies |
|---|---|---|---|---|
| `public.claims` | table | ~264 | on | 3 |

**Columns.** `id`, `person`, `service`, `service_date`, `tax_year`,
`amount_submitted`, `amount_paid`, `status`, `flag_status`, `note`,
`created_at`, `insurer`.

This is **personal financial data about named people** — who received what
service, when, for how much, and through which insurer. Roughly 264 rows of it.
That is the most sensitive data in either project, and it is worth saying
plainly here rather than leaving it implied by the column names.

**Policies.** One each for SELECT, INSERT and UPDATE, all scoped
`to authenticated` with the predicate `auth.role() = 'authenticated'`.

- **No anonymous access.** No policy applies to `anon`, so an unauthenticated
  request to `/rest/v1/claims` returns `[]`. The broad `anon` grants are
  Supabase's defaults and not a hole on their own — RLS is what gates this.
- **No public read path at all.** Nothing here resembles the tokenized invoice
  viewer on project 1: no `security definer` function, no view.
- **No DELETE policy**, so deletes are denied to everyone except
  `service_role`. Consistent with an append-and-correct record. Worth
  confirming that was intended rather than overlooked.

**Why the predicate is fine here and not on project 1.** `auth.role() =
'authenticated'` means "any account on this project". On project 1 that spans
four apps and is a real problem. Here only one app exists, so it means what it
appears to mean. The cross-app risk does not arise — but see below.

## Open questions

### 1. Who can obtain an authenticated session — capture block B

Not yet run. Every authenticated account can read all ~264 rows, so the
protection on this data is exactly as strong as the answer to "who can sign
up". If signups are open, the effective audience for this table is anyone who
fills in a form.

Block B reports account counts and providers. Whether signups are *open* is the
one part still needing the dashboard: **Authentication → Providers**.

### 2. `claims_dedupe_idx` does not deduplicate

It is named for deduplication but is a **plain** btree index on
`(person, amount_submitted, service_date)`, not a unique one. It makes duplicate
lookups fast; it prevents nothing.

If the app relies on the database to stop the same claim being entered twice,
that protection does not exist. If dedupe is enforced in app code instead, the
index is doing its job and only the name misleads. Which one is true needs the
repo — see [`../migrations/PLAN.md`](../migrations/PLAN.md).

### 3. Permissive vs restrictive not captured

The capture query does not read `pg_policies.permissive`. The three policies are
recorded as permissive because that is PostgreSQL's default and what the
dashboard creates, but it is an assumption rather than a reading. Worth closing
when convenient — restrictive policies compose with AND rather than OR, which
would change behaviour.

## What has not been checked

- Storage buckets, Edge Functions, scheduled jobs, database webhooks.
- Keys in circulation and where they are stored; whether a `service_role` key
  exists for this project and where it lives.
- Anything about the app itself: stack, deploy target, whether it has a server
  side.

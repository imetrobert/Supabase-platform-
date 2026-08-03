# Project `ipnajvgwtjrlecbqfwrh`

**Shared project.** More than one app points at this single database. That is
the most important fact about it and the source of most of its open problems —
see [Cross-app exposure](#cross-app-exposure) below.

- PostgreSQL 17.6
- API base: `https://ipnajvgwtjrlecbqfwrh.supabase.co`
- Last verified: **2026-08-03**, and only partially — see
  [What has not been checked](#what-has-not-been-checked).

---

## Apps

### Invoicing — `imetrobert/Ai-with-Robert-Invoicing-System`

| | |
|---|---|
| Stack | React 18 + Vite 5, `@supabase/supabase-js` ^2.45.4 |
| Deploy | GitHub Actions → GitHub Pages, on push to `main` |
| URL | `https://invoices.aiwithrobert.com` (custom domain, `base: '/'`) |
| Auth | Supabase Auth, email + password, single owner account |
| Indexed | No — `robots: noindex, nofollow` |

**Tables and functions it touches**

| Object | Kind | Used by | Access |
|---|---|---|---|
| `public.invoices` | table | `Dashboard`, `InvoiceForm`, `InvoiceView`, `TaxSummary` | authenticated only |
| `public.invoice_public_v` | view | (not called directly) | revoked from `anon`/`authenticated`; reached only via `invoice_by_token` |
| `public.invoice_by_token(text)` | function | `InvoicePublic` | `anon` + `authenticated` |
| `public.increment_invoice_view(text)` | function | `InvoicePublic` | `anon` |
| `public.increment_invoice_pdf_download(text)` | function | `InvoicePublic` | `anon` |
| `public.survey_responses` | table | `SurveyUpload`, `SurveyDashboard` | **UNKNOWN — see below** |

`survey_responses` is the loose end. This app reads, inserts and deletes it, but
it was left out of the invoicing repo's schema capture on purpose, and its
policies have never been read out of the catalog. Nothing here should be taken
as a statement about how it is protected.

**The one unauthenticated read path** is the client invoice viewer:
`/#/invoice/public/<view_token>` → `rpc('invoice_by_token', { token })`. It
takes the token as a function argument, never as a request filter. That
distinction is load-bearing and is written up as the house pattern in
[`../policies/patterns.md`](../policies/patterns.md#1-public-reads-scoped-by-a-secret).

**Keys and secrets** — names and locations only, no values:

| Name | Where it lives | Notes |
|---|---|---|
| `VITE_SUPABASE_URL` | GitHub Actions secret; `.env.local` for dev | Project URL |
| `VITE_SUPABASE_ANON_KEY` | GitHub Actions secret; `.env.local` for dev | Publishable key. Ships in the client bundle — treat as public |
| `VITE_EMAILJS_SERVICE_ID` | GitHub Actions secret | Not Supabase |
| `VITE_EMAILJS_TEMPLATE_ID` | GitHub Actions secret | Not Supabase |
| `VITE_EMAILJS_PUBLIC_KEY` | GitHub Actions secret | Not Supabase |

No `service_role` key is used by this app. It has no server side — everything
runs in the browser, which is why every access decision has to hold up against a
caller holding the publishable key and nothing else.

### Other apps — not yet enumerated

Table prefixes `etf_*`, `job_*` and `profiles` exist in this project and belong
to other apps. Which app owns which prefix, where those apps are deployed, and
what keys they use is **UNKNOWN** and needs a pass of its own.

---

## Cross-app exposure

Recorded here because it is a property of the *project*, not of any one app.

The only policy on `public.invoices` is:

```sql
using (auth.role() = 'authenticated')
```

That grants access to **any authenticated account on this project**, not to the
invoicing app's owner specifically. On a single-app project it would read as
"logged in"; on a shared one it means every app's users share one trust
boundary, and any account that can sign in anywhere can read and write every
invoice.

Known, deliberately not acted on yet, and the main driver behind the migration
plan — see [`../migrations/PLAN.md`](../migrations/PLAN.md).

The same question applies to `survey_responses`, which holds names, emails,
phone numbers and addresses, and whose policies have not been read.

---

## What has not been checked

Everything in this section is a gap, not a finding.

- Structure and policies of `etf_*`, `job_*`, `profiles`, `survey_responses`.
- The full list of tables in the project. The names above came from the
  invoicing app's own notes and its source, not from a catalog read of this
  project.
- Whether any other schema besides `public` is in use.
- Auth configuration: how many user accounts exist, whether signups are open,
  which providers are enabled. **This matters directly** — the blast radius of
  the `auth.role() = 'authenticated'` policy above depends entirely on who can
  get an authenticated session, and open signups would make it severe.
- Storage buckets, Edge Functions, scheduled jobs, database webhooks.
- Whether a `service_role` key is in use by any other app.

Running [`../queries/inventory.sql`](../queries/inventory.sql) closes most of
these in one pass. The auth questions are dashboard-only.

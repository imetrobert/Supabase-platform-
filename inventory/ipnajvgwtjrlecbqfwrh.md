# Project 1 — `ipnajvgwtjrlecbqfwrh`

**Shared by four apps.** They all point at this single database. That is the
most important fact about it and the source of most of its open problems — see
[Cross-app exposure](#cross-app-exposure) below.

The other project, [`nnkfnlrscywlosfwdlsw`](nnkfnlrscywlosfwdlsw.md), is
standalone behind `claims-tracker` and shares nothing with this one.

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

### Other apps on this project

Confirmed by the owner 2026-08-03: **four repos share this project.**

| Repo | Likely tables | Confidence |
|---|---|---|
| [`Ai-with-Robert-Invoicing-System`](https://github.com/imetrobert/Ai-with-Robert-Invoicing-System) | `invoices`, `survey_responses` | Confirmed — read from source |
| [`jobs`](https://github.com/imetrobert/jobs) | `job_*` | Strongly implied by the prefix; not yet confirmed |
| [`tsx-etf-signal-notifier`](https://github.com/imetrobert/tsx-etf-signal-notifier) | `etf_*` | Strongly implied by the prefix; not yet confirmed |
| [`Facebook-marketplace-generator`](https://github.com/imetrobert/Facebook-marketplace-generator) | **UNKNOWN** | No tables attributed to it at all |

Two things this does not yet tell us:

- **`profiles` has no owner.** It is unattributed, and on a shared project a
  table by that name is usually auth-adjacent — one row per user, often carrying
  a role. If it does carry a role, it is the natural basis for fixing the
  cross-app policy problem below, so identifying it is worth doing early.
- **`Facebook-marketplace-generator` has no tables.** Either it owns `profiles`,
  or it owns tables nobody has listed yet, or it uses this project for auth or
  storage only. Block 1 of the capture will settle it.

Deploy targets, keys and auth usage for these three apps have not been recorded.
Reading their repos would settle all of it; none of them are attached to this
session.

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

Now that the sharing is confirmed as **four apps**, the question is concrete:
if any one of `jobs`, `tsx-etf-signal-notifier` or `Facebook-marketplace-generator`
signs users up — even just to a signup form nobody uses — those accounts can
read and write every invoice, and every row in `survey_responses`. Whether that
is currently true is unanswered until block 7 is run; the app that ends up
mattering most here is whichever one has the loosest signup, not the one holding
the sensitive data.

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
- Auth configuration: how many user accounts exist, which providers are
  enabled, and whether signups are open. **This matters directly** — the blast
  radius of the `auth.role() = 'authenticated'` policy above depends entirely on
  who can get an authenticated session, and open signups would make it severe.
  Account counts and providers are readable in SQL (capture block 7); whether
  signups are open is the one part that is genuinely dashboard-only.
- Storage buckets, Edge Functions, scheduled jobs, database webhooks.
- Whether a `service_role` key is in use by any other app.

Running [`../queries/capture-blocks.sql`](../queries/capture-blocks.sql) closes
most of these in one pass — or
[`../queries/inventory.sql`](../queries/inventory.sql) for the same information
as ordinary result tables.

# Migration plan

Work identified but **not yet executed**. Nothing on this page has happened.
When something here is run, it moves to [`LOG.md`](LOG.md) with its verification
notes, and comes off this list.

Ordered by what should happen first. The ordering is not arbitrary: step 1 is
the only step that can be done without new information, and steps 2 and 3 cannot
be specified correctly until step 1 is done.

---

## 0. Check whether signups are open — both projects ⚠️

**Status:** not started. **Effort:** two dashboard clicks. **No SQL, no
migration.** Promoted above step 1 because it is the cheapest item here and
currently the largest single unknown.

**Authentication → Providers → "Allow new users to sign up"**, in each project.

Why it outranks everything else on this page: both projects gate their data on
`auth.role() = 'authenticated'`, which means *anyone with an account*, not *the
owner*. Project 2 was captured on 2026-08-03 with exactly one account, the
owner's own. That is a **snapshot of a set, not a constraint on it.** If signups
are open, anyone can join that set at will and immediately read every row the
policy protects — all ~264 claims on project 2, every invoice and every
`survey_responses` row on project 1. No policy changes, nothing in this repo
goes stale, and nothing announces it.

If each project is only ever used by its owner, turning signups off costs
nothing and removes that path entirely. It is not a substitute for step 2 —
scoping policies to an owner is still the correct fix — but it is a one-click
mitigation available today, where step 2 needs schema changes and testing.

Record the answer per project in the inventory files either way. "Signups are
off" is a fact worth having written down; so is "signups are on, deliberately,
because X".

## 1. Inventory the rest of `ipnajvgwtjrlecbqfwrh`

**Status:** not started. **Blocks:** everything else on this page.

Run [`../queries/inventory.sql`](../queries/inventory.sql) against the project
and commit the output into `schema/ipnajvgwtjrlecbqfwrh/` and the inventory file.

Half of this project has never been looked at. `survey_responses`, `etf_*`,
`job_*` and `profiles` are known to exist, and how they are protected is
unknown. Section 4 of the query — RLS policies, plus the "RLS disabled" and "RLS
on, no policies" check — is the part that matters most.

Capture block B answers **how many accounts exist and which providers are on**
for this project — not yet run here, though it has been for project 2. Whether
signups are *open* is step 0 above. Together those decide how urgent step 2 is:
if signups are open, anyone can obtain an authenticated session, and step 2 goes
from correct to urgent.

## 2. Scope `public.invoices` to its owner, not to "anyone logged in"

**Status:** not started. **Depends on:** step 1.

The only policy on the table is:

```sql
using (auth.role() = 'authenticated')
```

On a single-app project that reads as "logged in". This project is shared, so it
actually grants read and write on every invoice to **any authenticated account
in the project**, whichever app that account belongs to. Every app's users share
one trust boundary.

The fix depends on what step 1 finds — specifically, whether a `profiles` table
already carries a role or tenant column worth reusing. Two shapes, in order of
preference:

- **Owner column.** Add `owner_id uuid references auth.users default auth.uid()`
  to `invoices`, backfill it to the single owner account, then scope policies
  with `using (owner_id = auth.uid())`. Precise, and it generalizes if a second
  user is ever added.
- **Allowlist.** If a single-owner app makes an owner column feel like overkill,
  pin the policy to that account's UUID. Simpler, but it hardcodes an identity
  into a policy, and the next app on this project will copy the pattern.

Sequencing matters, the same way it did on 2026-08-03: add the column and
backfill it first, verify every existing row is attributed, and only then swap
the policy. Swapping first locks the owner out of their own invoices.

`invoice_by_token` is unaffected — it is `security definer` and runs as
`postgres`, outside RLS.

## 3. Decide the same question for `survey_responses`

**Status:** not started. **Depends on:** step 1.

The invoicing app reads, inserts and deletes this table, and it holds names,
emails, phone numbers, addresses and language preferences — the most sensitive
data in the project. Its policies have never been read, so there is nothing to
say about it yet beyond that it needs the same treatment as step 2 and probably
sooner.

## 3b. Project 2 — decide on `claims_dedupe_idx`

**Status:** not started. **Depends on:** reading the `claims-tracker` repo.

`claims_dedupe_idx` on `public.claims` is a plain btree index over
`(person, amount_submitted, service_date)`, despite the name. It speeds up
duplicate lookups and enforces nothing.

Two possibilities, and the repo settles which:

- **The app enforces dedupe itself** — checks for a match before inserting. Then
  the index is doing exactly its job and only the name misleads. Nothing to fix;
  consider a comment on the index.
- **The app assumes the database enforces it.** Then duplicates can already
  exist, and making the index unique will fail on the existing ~264 rows until
  they are reconciled. That reconciliation is a data decision, not a schema one:
  two identical `(person, amount, date)` rows may be a double entry or may be
  two genuinely identical claims on the same day.

Check for existing duplicates before deciding anything:

```sql
select person, amount_submitted, service_date, count(*)
from public.claims
group by 1,2,3 having count(*) > 1;
```

That query is read-only and settles how big the question is. If it returns
nothing, a unique index can go on cleanly whenever the app question is
answered — see pattern 6 in [`../policies/patterns.md`](../policies/patterns.md).

## 3c. Project 2 — confirm the missing DELETE policy is deliberate

**Status:** not started. **Effort:** one question, no SQL.

`public.claims` has policies for SELECT, INSERT and UPDATE but none for DELETE,
so deletes are denied to everyone except `service_role`. That is a sensible
shape for a financial record — nothing is destroyed, `status` marks what is no
longer active. Recorded only to confirm it was designed that way rather than
forgotten, since the app would fail silently on a delete either way.

## 4. Adopt the house patterns for anything new

**Status:** ongoing, not a migration.

[`../policies/patterns.md`](../policies/patterns.md) is written. New tables and
new public read paths should follow it by default rather than being reasoned
about from scratch each time.

---

## Deferred: token rotation for pre-2026-08-03 invoices

**Status:** deliberately not decided. Business call, not a technical one.

Every invoice created before the 2026-08-03 fix had its `view_token` readable by
anyone holding the publishable key, for as long as the `(view_token IS NOT NULL)`
policy was live. The key ships in the client bundle, so that means any visitor
who opened the app, plus anyone who read the deployed JavaScript.

Rotating is one statement —
`update public.invoices set view_token = gen_random_uuid()` — and that is not
the hard part. It **invalidates every link already sitting in a client's inbox**.
Each affected invoice then has to be re-sent by hand from `InvoiceView.jsx`, one
at a time, each consuming EmailJS quota, each landing as a second email about an
invoice the client already received. Anyone who bookmarked the original link or
forwarded it to a bookkeeper gets "Invoice Not Found" with no explanation unless
the re-send says so.

The counterfactual cost is unknowable. Whether anyone actually harvested tokens
while the policy was live cannot be determined after the fact: it would mean
auditing PostgREST logs for that window, and an anonymous read of a public table
is indistinguishable from ordinary viewer traffic in them.

Left open on purpose. Recorded here so the decision is not silently forgotten,
rather than because it is pending action.

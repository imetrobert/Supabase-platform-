# Execution log

What has **actually been run** against a live database, newest first. An entry
here means the SQL was executed and its effect observed. Anything not yet run
belongs in [`PLAN.md`](PLAN.md).

Every entry records: date, project, what changed, how it was verified, and
anything that turned out to be unrecoverable.

---

## 2026-08-03 — `ipnajvgwtjrlecbqfwrh` — harden definer functions, fix click counter

Run by hand in the SQL editor. Full SQL transcribed in the invoicing repo at
`supabase/migrations/20260803160000_fix_view_counter_and_harden.sql`.

Four changes, none of them security fixes — the anonymous read hole was closed
earlier the same day:

1. **Dropped `increment_invoice_view(uuid)`.** Two overloads existed with the
   same parameter name, `(token text)` and `(token uuid)`. PostgREST resolves
   RPC arguments by name, not type, so `rpc('increment_invoice_view', { token })`
   could not choose between them and every call from the invoice page failed.
   Plain SQL was unaffected — SQL resolves overloads by type — which is why
   calling the function directly always appeared to work and the bug survived
   two months. Kept the `text` overload: the app sends a JSON string, and
   `view_token::text = token` returns zero rows on a malformed token where the
   `uuid` version would raise.
   *Verified:* tapping a real invoice link moved `view_count` 0 → 1, then 1 → 2.
   *Unrecoverable:* click counts before this date. `view_count` was 1 across the
   whole table, last set 2026-06-03.

2. **Pinned `search_path = public, pg_temp` on all four definer functions.**
   `pg_temp` is listed **last** on purpose: when it is not listed at all,
   PostgreSQL searches the temporary schema *first* for relation names, which is
   the exact hijack the setting prevents. A bare `search_path = public` — what
   `invoice_by_token` originally had — does not close that.

3. **`alter view invoice_public_v set (security_invoker = on)`.** The view is
   exposed by PostgREST at `/rest/v1/invoice_public_v` and, like any view, ran
   with its owner's rights — reading `invoices` with RLS bypassed. The only
   thing keeping it shut was an explicit revoke, which a later blanket grant or
   a tool re-applying Supabase's default privileges would have silently undone,
   with no policy change for an audit to notice. The revoke was kept as well:
   belt and braces, not one replacing the other.
   *Verified:* loaded a real invoice link after the change. `invoice_by_token`
   still works because it is `security definer` and runs as `postgres`, which
   owns the table and is not under `FORCE ROW LEVEL SECURITY`.

4. **Added unique index `invoices_view_token_key`.** The viewer takes `data[0]`
   rather than `.single()`, so two rows sharing a token would silently render
   one client's invoice to another. Built non-concurrently after
   `CREATE INDEX CONCURRENTLY` failed inside the SQL editor's implicit
   transaction; the table is small enough that the brief lock did not matter.
   NULL tokens on drafts are unaffected — unique permits many NULLs.

## 2026-08-03 — `ipnajvgwtjrlecbqfwrh` — close anonymous read on `public.invoices`

Run by hand in the SQL editor. Full SQL and reasoning in the invoicing repo at
`supabase/migrations/20260803120000_invoice_by_token_rpc.sql`.

**The problem.** The public invoice viewer let clients open a tokenized link
without logging in. The policy enabling that was:

```
tablename: invoices | cmd: SELECT | applies to: {anon}
using: (view_token IS NOT NULL)
```

RLS is evaluated per row and can only see the row. It cannot see the token in
the URL or the filter on the request, so that predicate only asked *does this row
have a token at all* — true for every invoice ever sent. The real scoping lived
in the page's own query filter, `view_token=eq.<token>`, and a filter the caller
supplies is a filter the caller can remove.

*Confirmed before the fix:* an unauthenticated request with no filter, holding
only the publishable key, returned every invoice row including its `view_token`
— enough to construct a valid link for any client.

**The fix.** The token became a function argument instead of a request filter:
`invoice_by_token(token text)`, `security definer`, `stable`, returning
`setof invoice_public_v` so the declared shape and the projection are the same
object and cannot drift apart.

**Ordering mattered at the time.** The function was added first; the app change
calling it (commit `a04b28e`, PR #3) was deployed next; a real client link was
clicked to confirm it still worked; only then was the old policy dropped.
Dropping the policy first would have broken every link clients were holding at
that moment.

*Still open from this:* every invoice created before this date had its
`view_token` readable by anyone holding the publishable key. Rotation is a
business call — see [`PLAN.md`](PLAN.md#deferred-token-rotation-for-pre-2026-08-03-invoices).

---

## Before 2026-08-03

**No record exists.** The schema was built by hand in the Supabase SQL editor
over roughly a year, and none of it was in version control. What the database
looked like at any earlier point cannot be reconstructed. The entries above are
the first that were written down as they happened.

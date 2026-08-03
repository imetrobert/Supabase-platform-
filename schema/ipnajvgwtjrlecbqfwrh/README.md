# Schema snapshot — `ipnajvgwtjrlecbqfwrh`

Captured 2026-08-03. **Partial.**

| File | Covers | Provenance |
|---|---|---|
| [`invoicing-app.sql`](invoicing-app.sql) | `invoices`, `invoice_public_v`, the three `invoice_*` functions, the `updated_at` trigger | Catalog queries, 2026-08-03. Copied from the invoicing app's repo |

## Not captured

These are known to exist in this project and have never been read out of the
catalog:

- `survey_responses` — read, inserted and deleted by the invoicing app's survey
  screens. Left out of the original capture on purpose, as part of separate
  authorization work. **This is the highest-value gap**: it holds names, emails,
  phone numbers and addresses, and its policies are unknown.
- `etf_*` — another app's tables. Owner app unidentified.
- `job_*` — another app's tables. Owner app unidentified.
- `profiles` — likely auth-adjacent, unconfirmed.
- Anything else in the project. The list above came from the invoicing app's
  notes, not from a catalog read, so it may be incomplete in both directions.

To close these, run [`../../queries/inventory.sql`](../../queries/inventory.sql)
and add a file per app or table group alongside `invoicing-app.sql`.

## What these snapshots are and are not

**A snapshot of current state, not a historical baseline.** Run
`invoicing-app.sql` against an empty database and you get the structure as of the
capture date directly. There is no need to replay
[`../../migrations/LOG.md`](../../migrations/LOG.md) on top of it — those entries
are the record of what changed and why, kept for the reasoning, not for replay.

**Reconstructed, not dumped.** Function, trigger and view bodies are verbatim
from `pg_get_functiondef` and friends. The table, grant and policy statements
were written by hand from catalog output: faithful, but not byte-identical to
whatever was originally typed into the SQL editor. Where a real terminal and the
database URL are available, prefer:

```bash
supabase db dump --db-url "$SUPABASE_DB_URL" --schema public -f schema.sql
```

That is more authoritative than any hand-reconstruction and covers the whole
schema rather than one app's slice. The capture here was done from a phone,
which is why it exists in this form.

**Not a backup.** It contains no data, and it does not cover the whole project.
Do not treat restoring it as disaster recovery.

# Schema snapshot — `nnkfnlrscywlosfwdlsw`

Captured 2026-08-03. **Complete** for structure.

| File | Covers | Provenance |
|---|---|---|
| [`raw-capture-2026-08-03.txt`](raw-capture-2026-08-03.txt) | The whole project | Verbatim output of `queries/capture-one-shot.sql` section A |
| [`claims-tracker.sql`](claims-tracker.sql) | `public.claims` — the only object in the project | Reconstructed from the raw capture |

The raw capture is the authority. `claims-tracker.sql` is a reconstruction from
it, kept because replayable DDL is more useful than a text dump when rebuilding.

**Verified by round trip.** `claims-tracker.sql` was replayed onto an empty
database and the capture query re-run against the result. The output matched the
raw capture line for line, with one expected difference — the row estimate (264
live, 0 in the empty copy). The reconstruction is therefore known to reproduce
the same catalog state, not merely to look plausible.

Unlike project 1, this project contains one table and nothing else, so this
snapshot really is the whole structure. It still contains **no data** and is not
a backup.

## Not captured

- Auth: account counts, providers, whether signups are open.
- Storage buckets, Edge Functions, scheduled jobs, webhooks.
- Whether the three policies are permissive or restrictive — see the note at the
  top of `claims-tracker.sql`.

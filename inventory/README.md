# Inventory

One file per Supabase project, named after the project ref.

| File | Project ref | Apps | Last verified |
|---|---|---|---|
| [`ipnajvgwtjrlecbqfwrh.md`](ipnajvgwtjrlecbqfwrh.md) | `ipnajvgwtjrlecbqfwrh` | **4, shared** — invoicing, jobs, tsx-etf-signal-notifier, Facebook-marketplace-generator | 2026-08-03, partial |
| [`nnkfnlrscywlosfwdlsw.md`](nnkfnlrscywlosfwdlsw.md) | `nnkfnlrscywlosfwdlsw` | 1, standalone — claims-tracker | never |

**Two projects, confirmed by the owner 2026-08-03.** Repos not listed above
(`imetrobert.github.io`, `aiwithrobert`, `aiwithrobert-brand-assets`) use no
Supabase project. That is worth stating explicitly: an app that is absent from
this table should be absent because it was checked and uses no database, not
because nobody got to it.

## Adding a project

1. Run [`../queries/inventory.sql`](../queries/inventory.sql) in that project's
   SQL editor.
2. Copy `ipnajvgwtjrlecbqfwrh.md` as a template and fill it in from the output.
3. Commit the structure into [`../schema/<project-ref>/`](../schema/).
4. Add a row to the table above.

## Rules for these files

- **Never paste a key value.** Record the key's *name* and where it is stored
  (GitHub secret, `.env.local`, Supabase dashboard). Anon/publishable keys ship
  in the client bundle and are not secrets in the usual sense, but there is no
  reason for them to be here, and `service_role` keys must never be.
- **Project refs are fine to record.** They are in the URL of every request the
  browser makes.
- **Mark what you have not checked as `UNKNOWN`.** An honest gap is useful; a
  guess that reads like a fact is worse than nothing. If something is inferred
  from app code rather than read from the catalog, say so inline.
- **Date every claim about live state.** Anything captured by hand is true as of
  a moment, not forever.

# Supabase platform

This repo is the durable record of how my Supabase projects are actually set up:
which app uses which project, which tables and keys each one touches, what the
schema looks like right now, what migrations are planned versus actually
executed, and the policy patterns I've decided new apps should follow by
default. It exists because all of this previously lived in my head and in chat
threads that end — the databases were built by hand in the SQL editor, so there
was no version-controlled copy of anything, and losing a project would have
meant rebuilding from memory. Nothing runs from this repo and no code deploys
out of it; it is documentation, and its only job is to still make sense to me in
six months.

---

## Layout

| Path | What's in it |
|---|---|
| [`inventory/`](inventory/) | Which app uses which project, tables, and keys |
| [`schema/`](schema/) | A structure snapshot per project, captured from catalog queries |
| [`queries/`](queries/) | The catalog queries that produce those snapshots — start with [`capture-one-shot.sql`](queries/capture-one-shot.sql) |
| [`migrations/`](migrations/) | The plan, and the log of what has actually been run |
| [`policies/`](policies/) | Patterns new apps should follow by default |

## How this is meant to be used

**The database is the source of truth, not this repo.** Every snapshot here is a
capture with a date on it, and it goes stale the moment something is changed by
hand in the SQL editor. When the two disagree, the database is right and the
snapshot needs re-capturing — see [`queries/inventory.sql`](queries/inventory.sql).

**Two things are recorded separately on purpose.** What was *planned*
([`migrations/PLAN.md`](migrations/PLAN.md)) and what was *actually executed*
([`migrations/LOG.md`](migrations/LOG.md)) are different files, because with
hand-run SQL the gap between them is the thing that bites. A plan entry means
nothing has happened yet.

**Nothing secret is committed here.** The inventory records key *names* and
where they are stored, never their values. Project refs are recorded because
they are not secret — they appear in every request URL the browser makes.

## Current state

Started 2026-08-03. This is a first pass, deliberately partial:

- **Two Supabase projects exist.** Project 1 (`ipnajvgwtjrlecbqfwrh`) is shared
  by four apps; project 2 is standalone behind `claims-tracker` and its ref has
  not been recorded yet.
- The invoicing app's slice of project 1 is captured in full, transcribed from
  that app's own repo where it had already been reconstructed from catalog
  queries.
- **The other three apps on project 1 are not captured.** `survey_responses`,
  `etf_*`, `job_*` and `profiles` are known to exist, but their structure has
  never been read out of the catalog. Gaps are marked `UNKNOWN` rather than
  guessed at.
- **Project 2 has never been looked at at all.**

Filling those gaps means running
[`queries/capture-one-shot.sql`](queries/capture-one-shot.sql) against each
project and committing the output. See [`inventory/README.md`](inventory/README.md) for
what to do with the results.

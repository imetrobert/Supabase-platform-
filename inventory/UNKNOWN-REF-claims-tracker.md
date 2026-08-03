# Project 2 — claims-tracker (project ref not yet recorded)

**Placeholder.** Nothing here has been captured yet.

**Rename this file** to `<project-ref>.md` once the ref is known — it is in the
dashboard URL, `supabase.com/dashboard/project/<ref>` — and update the link in
[`README.md`](README.md) and in
[`ipnajvgwtjrlecbqfwrh.md`](ipnajvgwtjrlecbqfwrh.md).

## What is known

Confirmed by the owner 2026-08-03, from a screenshot of their repo list:

- [`imetrobert/claims-tracker`](https://github.com/imetrobert/claims-tracker) is
  the only app on this project.
- It is **standalone** — it shares nothing with project
  [`ipnajvgwtjrlecbqfwrh`](ipnajvgwtjrlecbqfwrh.md).

That is the entire extent of what is recorded. Everything below is unknown.

## What is unknown

Everything: project ref, region, Postgres version, tables, policies, functions,
views, grants, auth configuration, keys, where the app is deployed, and whether
it has any public unauthenticated read path.

## Why this one may deserve attention first

Not a finding — a reason not to leave it until last.

Being standalone makes it *structurally* safer than project 1: a policy of
`auth.role() = 'authenticated'` on a single-app project means "a user of this
app", which is usually what the author intended. The cross-app problem cannot
arise here.

Two things cut the other way, though, and they are worth holding in mind before
assuming this project is fine:

- **The name.** Anything tracking claims is likely to hold personal, financial
  or medical detail. If its policies are as loose as project 1's turned out to
  be, the consequence is worse even though the structure is simpler.
- **It has never been looked at.** Project 1's problems were only found because
  someone went looking. This project has had no equivalent pass, so "no known
  issues" here means nothing has been checked — not that nothing is wrong.

Run the same capture blocks as project 1 —
[`../queries/capture-blocks.sql`](../queries/capture-blocks.sql). They are not
project-specific; every block reads whatever project it is run in.

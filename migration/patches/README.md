# Patches waiting to land elsewhere

Changes made for another repository that could not be pushed from the session that
wrote them, parked here so they survive. Delete each one once it has landed.

## `jobs-dismiss-no-cascade.patch`

Target: [imetrobert/jobs](https://github.com/imetrobert/jobs)

Dismissing a role deleted its `job_postings` row, and `job_matches` and
`job_applications` both cascade off it — so throwing a role away also threw away its
match write-up, its application status and any generated cover letter. On this shared
project, one person dismissing a role would destroy everyone else's, since the posting
is a single shared row.

The delete was never what made dismissal work: the suppression row in `job_dismissed`
already hides the card immediately and stops the scan re-importing it. Dismissed
postings now stay put, inert.

The patch also fixes `supabase/schema.sql`, which mattered more than the bug. That file
is documented as safe to re-run, and re-running it would have undone the access work on
the live project — every policy back to `using (true)`, `job_ranked` recreated without
`security_invoker`, and the DELETE policy restored. It now creates the gated policies,
carries `security_invoker` explicitly, has no DELETE policy on `job_postings`, and
refuses to run at all if `has_app_access()` is missing.

Verified against a local Postgres: applies clean, idempotent across two runs, seven
policies all gated, no DELETE policy, `job_ranked` with `security_invoker` true; fails
loudly and creates nothing when the platform layer is absent. `npm run build` passes,
which is the whole of that repo's CI.

It could not be pushed because that repository was not in the authoring session's
authorized source set.

To land it:

```bash
git clone https://github.com/imetrobert/jobs.git
cd jobs
git checkout -b claude/supabase-db-migration-6lqrhw
curl -sSL https://raw.githubusercontent.com/imetrobert/Supabase-platform-/main/migration/patches/jobs-dismiss-no-cascade.patch | git am
npm install && npm run build
git push -u origin claude/supabase-db-migration-6lqrhw
```

**Run this on the project after merging**, to drop the DELETE policy that is already
live. The patch removes it from `schema.sql`, but that only takes effect if `schema.sql`
is re-run:

```sql
drop policy if exists "job_postings delete (job)" on public.job_postings;
```

With no DELETE policy, RLS blocks browser deletes on postings outright, so this class of
bug cannot come back through the app.

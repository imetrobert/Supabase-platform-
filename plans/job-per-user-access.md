# Plan — per-user job search

> **This is a plan, not a task. Nothing here is to be executed now.**
>
> It exists so that whoever picks this up — in a month or a year — starts from a design
> instead of re-deriving it from 1,400 lines of scan code. Written 2026-08-09 from a
> read-only investigation of `imetrobert/jobs`.
>
> **Do not start any of this without deciding the four questions in *Decisions first*.**
> Two of them are product decisions, not engineering ones, and getting them wrong means
> rewriting the same code twice.

## The goal

Several people sign into the jobs app with their own account. Each fills in their own
profile, and each sees jobs curated against *their* profile — their matches, their
applications, their dismissals. Nobody sees anyone else's.

## Why this is a project and not a migration

The app is not "single-user by configuration". It is single-user by schema, and in four
independent ways:

1. **`job_matches` is keyed one row per posting.** `posting_id uuid primary key`. Two
   users' verdicts on the same posting collide on the primary key — per-user matches are
   not merely unattributed, they are *impossible* until the key changes. Add a `user_id`
   column without changing the key and the second user's verdict silently **overwrites**
   the first.
2. **`job_profile` physically forbids a second row.** `id int primary key default 1
   check (id = 1)`, seeded once. Every reader hardcodes the literal `1`.
3. **The scan has no concept of users.** It runs under the service role with no auth
   context, loads *the* profile with `.eq('id', 1).single()`, and passes that one object
   to the scorer. There is no loop, no user parameter, and no user field in the verdict
   shape it writes.
4. **The edge function authenticates the caller and then discards them.** It validates
   the user purely to prove they are logged in, then builds a second service-role client
   and reads profile `id = 1`. For anyone but the original owner it would generate a
   cover letter from **the wrong person's résumé**.

None of these is hard on its own. Together they mean touching every write path in the
app, in a repo with **no test suite** — CI is `npm install && npm run build` and nothing
else. The only real verification is running a live scan and looking at the result.

## Decisions first

**1. Who pays for the LLM?** `MAX_SCORES_PER_RUN = 120` and the Gemini free-tier pacing
are *per run*, globally. Two users do not double the budget — they halve each person's
share. Options: a per-user cap (cost scales with people), a global cap split fairly
(everyone gets less), or per-user scheduled runs. This is a product decision and it
shapes the scan's structure, so decide it before writing the loop.

**2. Does an `app_admin` see everyone's matches?** The platform's personal-table shape
says yes for reads, writes stay owner-only. Fine for a support role; think about whether
that is what you want for someone else's job search, which is unusually personal data.

**3. Whose search terms drive the scrape?** `buildQueries`/`buildLocations` derive what
gets fetched from the single profile. `job_postings` is meant to stay shared, but that is
only true if the scan fetches the **union** of every user's queries. Otherwise "shared"
means "whatever the first profile asked for", and other users get matched against a pool
that was never searched for them.

**4. Do dismissals stay personal?** Almost certainly yes — one person throwing a role
away should not hide it from everyone. That makes `job_dismissed` a personal table too,
keyed `(fingerprint, user_id)`.

## What stays shared

`job_postings`, `job_sources`, `job_runs`. The scraped world and ingest bookkeeping are
the same for everyone. They keep the **shared** shape: `has_app_access('job')` only.

`job_profile`, `job_applications`, `job_dismissed`, `job_matches` become **personal**:
`has_app_access('job') and (app_role('job') = 'app_admin' or user_id = auth.uid())` for
reads, `has_app_access('job') and user_id = auth.uid()` for writes. See
`../migration/app_access_pattern.sql`.

## The work, in order

Each step should land and be verified before the next. Steps 1–2 are irreversible on
live data; take a backup of `job_matches` and `job_applications` first.

**1. Schema.** Add `user_id uuid references auth.users(id)` to the four personal tables.
Change primary keys: `job_matches` and `job_applications` to `(posting_id, user_id)`,
`job_dismissed` to `(fingerprint, user_id)`. Drop `check (id = 1)` on `job_profile` and
re-key it on `user_id`.

**2. Backfill.** Every existing row belongs to the owner — about 1,346 of them across
`job_matches` (1,337), `job_runs`-adjacent tables, `job_applications` (4),
`job_dismissed` (4) and `job_profile` (1). Do this **before** the columns go `not null`,
and before the new policies land, or the owner loses their own data.

**3. Policies.** Switch the four tables to the personal shape. Then run
`../migration/verify_access.sql` adapted for `job`: the owner reads their rows, a second
granted account reads only theirs, an ungranted account reads none.

**4. `onConflict` targets.** Every upsert that names `posting_id` or `fingerprint` alone
must become the composite. Miss one and it silently overwrites another user's row rather
than erroring — the worst failure mode in this whole plan. As of the investigation:
matches at `run-job-scan.js` ~834 and ~861; applications at `JobCard.jsx` ~162,
`generate-application/index.ts` ~248 and ~304; dismissals at `dismiss.js` ~29 and
`run-job-scan.js` ~677.

**5. The scan.** The substantial part:
   - wrap the scoring section in a loop over profiles instead of loading `id = 1`
   - `alreadyScored` is built from a global `select posting_id from job_matches`. It must
     become per-user, or user B's postings look already-scored because A scored them and
     B never gets a verdict at all
   - apply whatever budget decision came out of question 1
   - `scoreById` builds one score per posting for link verification; with N verdicts per
     posting it needs a max-across-users (link checking is genuinely shared)
   - deadline expiry reads `job_matches.application_deadline` and marks the **shared**
     `job_postings.stale` — one user's verdict currently hides a posting from everyone
   - query building per question 3

**6. The edge function.** It already authenticates the caller and throws the identity
away. Use it: load *that* user's profile instead of `id = 1`, and stamp `user_id` on the
`job_applications` rows it writes.

**7. Frontend.** `Profile.jsx` reads and writes `id = 1` — switch to the signed-in user.
The client-side dismissed filter in `Jobs.jsx` and `Applications.jsx` loads *all*
dismissals; once the table is row-scoped RLS handles that, but the code should stop
assuming otherwise.

**8. `job_ranked`.** Probably needs no change, and that is worth understanding rather
than assuming. The view left-joins `job_matches` and `job_applications` onto postings.
Because it now carries `security_invoker = true`, RLS on those tables is evaluated as
the *caller*, so each user's join naturally yields their own verdict or none — and
`Jobs.jsx` already drops rows where `score is null`. Confirm this holds with two real
accounts rather than trusting the reasoning.

## Verifying, with no test suite

The build proves the frontend compiles and nothing more. The real check is:

1. Create a second account, grant it `job`, give it a genuinely different profile
2. Run the scan (`workflow_dispatch`) and watch it complete without error
3. Sign in as each user and confirm each sees matches against *their* profile
4. Confirm neither sees the other's applications or dismissals
5. Dismiss a role as one user; confirm it is still visible to the other
6. Run `../migration/audit.sql` — one row

Step 5 is the one most likely to be wrong and the least likely to be tested.

## A caveat on line numbers

Every reference above was accurate at the time of the investigation. `dismiss.js`,
`run-job-scan.js` and especially `supabase/schema.sql` have changed since — the cascading
dismiss-delete fix rewrote parts of all three. **Treat line numbers as hints and grep for
the symbol.** The structural findings — the primary keys, the `check (id = 1)`, the
absent user concept — are properties of the design and have not changed.

## What is already done

The cascading dismiss-delete is fixed: dismissing a role used to delete the shared
posting row, and `job_matches` and `job_applications` cascade off it, so a dismissal
destroyed the match write-up, application status and any generated cover letter — for
every user, not just the dismisser. That would have made this whole plan considerably
more dangerous, so it was fixed first, separately.

`job_ranked` also no longer bypasses RLS, and there is no longer a DELETE policy on
`job_postings`. Both matter here: the first is what makes step 8 work at all, and the
second means the app cannot delete a posting even if someone re-adds the code.

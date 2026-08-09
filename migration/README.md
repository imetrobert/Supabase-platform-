# Supabase project migration

Moving the database from the old project to the new one, so the old project can be deleted.

| | Project ref | Role |
|---|---|---|
| Old | `nnkfnlrscywlosfwdlsw` | source — delete after this is done |
| New | `ipnajvgwtjrlecbqfwrh` | target |

> ## As built — 2026-08-09
>
> **The data migration is done and verified.** It was carried out through the Supabase
> dashboard SQL Editor from a phone, not with the scripts below — those need a terminal.
> What actually happened:
>
> 1. Inventoried the old project from the catalog: one table, `public.claims`, 264 rows,
>    12 columns, 4 indexes, 3 RLS policies, no triggers/functions/buckets, one login.
> 2. Recreated `claims` in the new project from that inventory (`schema_claims.sql`).
> 3. Discovered the new project is **not** a fresh project — it hosts ~21 tables for
>    several other apps and has **3 auth users**. The old project's policy
>    (`auth.role() = 'authenticated'`) was safe there with one user and would have
>    exposed all 264 claims to the other two accounts here. Built a per-app
>    authorization layer instead — see `app_access_pattern.sql`.
> 4. Moved the rows project-to-project with the `http` extension: the new project called
>    the old project's PostgREST API with its secret key and inserted the JSON directly,
>    guarded so it could only fire on HTTP 200, exactly 264 rows, and an empty target.
>    No CSV, so `null` stayed `null` and the original UUIDs came across.
> 5. Verified with an md5 checksum over every field of all 264 rows, computed identically
>    on both projects: `15a439699d3966dee7aaffbae7cec639` on each side.
> 6. Cut over: `index.html` repointed and merged to `main`, so
>    <https://tax.imetrobert.com> now runs on the new project. Confirmed by
>    `auth.users.last_sign_in_at` on the new project moving to the moment of the first
>    login — the one signal page caching cannot fake.
> 7. Verified the access boundary by impersonating both users at the database level
>    (`verify_access.sql`): the owner reads 264 rows and can insert and update; a second
>    account on the same project, fully authenticated, reads **0**. Deletes stay blocked,
>    matching the old project. Checksum unchanged afterwards.
>
> The old project's secret key was exposed in a chat transcript during step 4 and has
> been deleted. The keep-alive workflow's `SUPABASE_URL` / `SUPABASE_ANON_KEY` repository
> secrets have been updated.
>
> **Only remaining step: delete the old project** (`nnkfnlrscywlosfwdlsw`), after roughly
> a week of running on the new one. Deletion is instant and irreversible and free-tier
> projects have no downloadable backup, so the old project is the only fallback until
> then.
>
> ## Access control — 2026-08-09
>
> Migrating into a shared project turned out to be the smaller half of the job. The
> target hosts six apps and three accounts, and every table except `claims`, `profiles`
> and `cartmatch_*` was readable — and on eleven of them writable — by all three.
>
> All 22 tables are now behind per-app grants; see `app_access_pattern.sql` for the model
> and `verify_access.sql` for the proof. The audit query returns no rows: nothing is
> reachable by a logged-in account that has not been granted that app.
>
> Still open, in order:
>
> 1. Per-user rows for `job`. It is gated but not yet row-scoped, which is correct while
>    it has one user and wrong the moment it has two. Blocked on knowing what generates
>    `job_matches` — that writer has to set `user_id` or new matches arrive owned by
>    nobody.
> 2. The admin page at `access.imetrobert.com` — grants and revokes without SQL. Needs a
>    `list_app_users()` function first, since `auth.users` is not reachable through the
>    API.
> 3. Merge `claude/supabase-db-migration-6lqrhw` on Facebook-marketplace-generator, which
>    moves that app off its hardcoded email allowlist. Safe now that `profiles` carries
>    the grant.
>
> Unrelated and still open: `claims-tracker/index.html` carries a live Google Gemini API
> key in plaintext in a public repository.
>
> The scripts below remain valid for a terminal-based migration and are kept as-is.

**Short answer: yes, this is easy.** As far as the application code shows, the old
project holds one table (`public.claims`) and one login. There are no storage buckets,
no edge functions, no database functions and no foreign keys to untangle. The work is
a dump, a restore, and a two-line config change in the app.

## What I could and could not check

This was prepared in a sandbox whose network policy blocks `*.supabase.co`, so I could
not connect to either project. Everything below is derived from `imetrobert/claims-tracker`
(`index.html`), which is the only thing that talks to the database.

Certain, because the app uses them literally:

- One table, `public.claims`, with columns `id`, `person`, `service`, `service_date`,
  `tax_year`, `amount_submitted`, `amount_paid`, `insurer`, `status`, `flag_status`.
- `status` is one of `active` / `duplicate` / `excluded`; `flag_status` is unset or one of
  `suspected` / `confirmed_duplicate` / `rejected_not_duplicate`.
- Supabase Auth with email + password (`signInWithPassword`). No OAuth providers.
- No `user_id` column, so nothing in the data is tied to a specific auth user — which is
  what makes recreating the login on the new project harmless.

Not verifiable without access, and the reason step 1 is "look, then decide":

- Whether anything else exists in the database that the app does not use.
- The exact column types, the type of `id`, and the RLS policies currently in force.

`migrate.sh` sidesteps all of that by copying the real definitions rather than my
reconstruction of them. Use it if you can get the database password.

## Path A — full copy (recommended)

Needs the database password for both projects. Get each connection string from
**Dashboard → your project → Connect → Session pooler** (port 5432, *not* the
transaction pooler on 6543 — `pg_dump` needs prepared statements).

```bash
cd migration
export OLD_DB_URL='postgresql://postgres.nnkfnlrscywlosfwdlsw:PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres'
export NEW_DB_URL='postgresql://postgres.ipnajvgwtjrlecbqfwrh:PASSWORD@aws-0-REGION.pooler.supabase.com:5432/postgres'

./migrate.sh dump      # writes dump/01_pre_data.sql, 02_data.sql, 03_post_data.sql
                       # nothing is written to the new project yet
```

Open `dump/01_pre_data.sql`. It is the ground truth about what is actually in the old
project. If it contains only the `claims` table, this migration is as small as expected;
if there is more, it still all comes across, you just now know about it.

```bash
./migrate.sh restore   # loads all three files into the new project, in one transaction
./migrate.sh verify    # exact row counts side by side, plus an RLS check
```

The restore runs inside a single transaction with `ON_ERROR_STOP=1`: if anything fails,
the new project is left exactly as it was, and you can re-run after fixing the cause.

The dump is split into three sections — bare tables, then rows, then indexes, keys, RLS
policies and triggers — and restored in that order. That is what lets the load work
without `pg_dump --disable-triggers`, which requires superuser; the `postgres` role on a
Supabase project is not a superuser, and a dump taken the more obvious way fails on
restore with `permission denied to set session authorization`.

The dump deliberately skips Supabase's own schemas (`auth`, `storage`, `realtime`,
`extensions`, …) because the new project already has its own copies and restoring over
them causes collisions. That means logins do not come across automatically — see below.

### If `pg_dump` complains about a version mismatch

Supabase runs Postgres 15 or 17 and `pg_dump` refuses to dump from a server newer than
itself. `migrate.sh dump` checks this up front and tells you what to install. The
alternative is the Supabase CLI, which runs the correct version in Docker:

```bash
npx supabase@latest db dump --db-url "$OLD_DB_URL" -f dump/schema.sql
npx supabase@latest db dump --db-url "$OLD_DB_URL" -f dump/data.sql --data-only --use-copy
psql --single-transaction --variable ON_ERROR_STOP=1 \
     --file dump/schema.sql --file dump/data.sql --dbname "$NEW_DB_URL"
```

(The CLI handles the superuser problem its own way, by emitting
`SET session_replication_role = replica` instead of disabling triggers, so its two-file
output is safe to restore in that order.)

## Path B — no database password

Only needs the app login and the two publishable keys. Rebuilds the table from my
reconstruction and copies the rows through the REST API.

```bash
# 1. Create the table in the new project: paste schema_claims.sql into
#    Dashboard -> SQL Editor -> Run. Read it first — the types are my best guess.

# 2. Copy the rows.
cd migration
export OLD_ANON_KEY='sb_publishable_SbFVLbSnoDXM56MhF5jA0g_vLc6bNEh'
export NEW_ANON_KEY='...'                 # new project -> Connect -> API keys
export LOGIN_EMAIL='...' OLD_PASSWORD='...' NEW_PASSWORD='...'

./copy_claims_via_api.sh export
./copy_claims_via_api.sh import
```

Do step 3 below first, so the new-project login exists to authenticate with.

## Logins

Neither path carries auth users across — that is intentional, since the `auth` schema
belongs to the platform and the app has no `user_id` column linking data to a user.

Recreate the account by hand: **Dashboard → new project → Authentication → Users → Add user**,
same email address, and tick *Auto Confirm User* so it works without an email round-trip.
`migrate.sh dump` writes `dump/auth_users.txt` listing the accounts on the old project, so
you can check you have not missed one.

## Repointing the app

`claims-tracker/index.html` has the project baked into two constants near line 236:

```js
const SUPABASE_URL = "https://ipnajvgwtjrlecbqfwrh.supabase.co";
const SUPABASE_ANON_KEY = "<new project publishable key>";
```

Change both together — a new URL with the old key fails to authenticate. The site is
served from GitHub Pages off the default branch, so it goes live the moment that lands.

## Order of operations

1. Verify the new project exists and is empty.
2. Path A or Path B above.
3. Recreate the login on the new project.
4. `./migrate.sh verify` — row counts match, and RLS is enabled on `claims`.
5. Repoint `index.html`, and update the `SUPABASE_URL` / `SUPABASE_ANON_KEY` repository
   secrets that `.github/workflows/keep-alive.yml` uses, or the weekly keep-alive ping
   will keep poking the deleted project and fail.
6. Log in to the live site, confirm the claims list and the summary totals look right.
7. Leave the old project up, untouched, for a week.
8. Delete the old project.

Step 7 matters more than it looks: deleting a Supabase project is immediate and
irreversible, and free-tier projects have no downloadable backups. Keep `dump/` on your
own machine until you are sure — it is the only copy of that data outside Supabase.

## How these scripts were tested

Not against your projects — the sandbox could not reach them. Against a local Postgres 16
with two databases standing in for the old and new project, both carrying the roles
(`anon`, `authenticated`, `service_role`) and platform schemas (`auth`, `storage`,
`extensions`) that Supabase creates, and with the target database owned by a
**non-superuser** role so that superuser-only statements fail the way they would on
Supabase rather than silently passing.

- `schema_claims.sql` (then the reconstructed draft it replaced) applies cleanly and produces the table it describes.
- `migrate.sh dump` skips the platform schemas and picks up everything in `public` —
  including a table the app never references, which is the case that matters if there is
  more in your database than `index.html` reveals.
- `migrate.sh restore` completes as a non-superuser; all 6 test rows arrive byte-identical,
  UUID primary keys preserved, along with all 3 indexes, both check constraints, and all
  4 RLS policies.
- `migrate.sh verify` reports PASS on a good migration and FAIL with a diff when a row is
  missing from the target.
- `copy_claims_via_api.sh` was run against a mock PostgREST: 2500 rows paged out in three
  requests and imported in three chunks, the re-import guard refused a second load into a
  non-empty table, and a wrong password produced a clean error rather than an empty file.

What this does not prove is the shape of your actual database, which is the one thing
only the real dump can tell you. That is why step 1 is to read `01_pre_data.sql`.

## A note on the files in `dump/`

`.gitignore` in this directory excludes them. They contain real insurance claim records
with names, treatments and dates, and both of these repositories are public — the dumps
must not be committed. Keep them locally, and delete them once the new project is
confirmed working.

## Unrelated, but worth doing while you are in here

`claims-tracker/index.html` line 238 has a live Google Gemini API key committed in
plaintext, in a public repository. `robots.txt` keeps it out of search results but does
nothing about the GitHub repo itself or the served page source, and key scrapers watch
public commits. That key should be rotated in Google AI Studio regardless of what you
decide about the architecture. Note that any key shipped in a static page is readable by
anyone who opens the site — the durable fix is to move the Gemini call behind a Supabase
edge function on the new project, so the key lives in server-side secrets and the browser
never sees it. The Supabase publishable key is fine to expose, by design; it is only safe
while RLS is on, which is why `migrate.sh verify` checks for that.

# Supabase platform

Access control for the Supabase project `ipnajvgwtjrlecbqfwrh`, which is shared by six
apps, and the page that manages it.

Supabase Auth is per-project, not per-app. Every app pointing at this project shares one
set of users, so an account created for any of them can authenticate against all of
them — and the usual policy `auth.role() = 'authenticated'` therefore means "anyone with
an account on any of my apps", not "the owner". That reads as a restriction and is not
one. This repository is how that gap is closed.

## The model

Two dimensions, kept separate:

| | Answered by |
|---|---|
| **Can you enter this app?** | `app_access(user_id, app)` → `has_app_access('etf')` |
| **What can you see inside it?** | `app_role('etf')` and `user_id = auth.uid()` |

Every table in `public` uses one of two policy shapes — `shared` for reference data that
is the same for everyone in an app, `personal` for one person's rows. Deliberately two
and not three: one audit query then checks the whole project.

`migration/app_access_pattern.sql` is the deployed model, with the shapes, which app uses
which, and the audit queries.

## The apps

| App | Tables | Shape |
|---|---|---|
| `claims-tracker` | `claims` | shared |
| `invoicing` | `invoices`, `survey_responses` | shared |
| `etf` | 8 × `etf_*` | shared |
| `job` | 7 × `job_*` | shared — [see below](#open) |
| `cartmatch` | 3 × `cartmatch_*` | personal |
| `fb-marketplace` | `profiles` | personal |

`platform` is a reserved app name, not a real one. A row for it with role `app_admin` is
what lets someone hand out grants.

## Managing access

**https://access.imetrobert.com** — sign in, tap a cell, done. Changes take effect on
that person's next page load; there is no deploy. Source in `docs/`.

The page holds only the publishable key and can do exactly what row level security
allows the person signed into it to do. Its `is_platform_admin()` check is for showing a
clear message, not for enforcement — the `app_access` policies are what actually refuse.
It cannot create or delete accounts, because that needs a secret key and no secret key
belongs in a browser.

Equivalent by hand, if the page is ever unavailable:

```sql
insert into public.app_access (user_id, app, role)
select id, 'job', 'member' from auth.users where email = 'someone@example.com'
on conflict (user_id, app) do update set role = excluded.role;
```

## Files

| | |
|---|---|
| `docs/` | the Access Rights page, served by GitHub Pages |
| `tests/admin.test.mjs` | drives that page against a stubbed Supabase — `npm test` |
| `migration/app_access_pattern.sql` | the deployed access model |
| `migration/list_app_users.sql` | lets a platform admin list accounts; `auth.users` is not reachable through the API |
| `migration/schema_claims.sql` | the verified `claims` table |
| `migration/verify_access.sql` | proves a policy holds, by impersonating real accounts |
| `migration/README.md` | the database migration that started all this, as built |
| `migration/migrate.sh` | terminal-based project-to-project migration, for next time |

## Verifying

A test suite for a static site can only prove the browser gate. It stubs the network, so
it never asks Postgres anything — a policy could be missing entirely and the suite would
stay green.

`migration/verify_access.sql` is the other half. It impersonates real accounts at the
database level and checks what they can actually read and write. Run it against any app
after changing its policies. Note that a refused `INSERT` **raises** rather than
returning zero rows, so an unwrapped probe aborts the script and discards every result
before it; `SELECT`, `UPDATE` and `DELETE` fail the opposite way, filtering silently.

Nothing should ever appear in this, on any table:

```sql
select tablename, policyname, cmd, coalesce(qual, with_check) as expr
from pg_policies
where schemaname = 'public'
  and (coalesce(qual, with_check, 'true') = 'true'
       or coalesce(qual,'') || coalesce(with_check,'') like '%auth.role()%')
order by tablename, policyname;
```

## Open

<a name="open"></a>

**Per-user rows for `job`.** It is gated but not row-scoped — correct while it has one
user, wrong the moment it has two. `job_profile`, `job_applications`, `job_dismissed` and
`job_matches` need a `user_id` column and a backfill of the existing 1,346 rows;
`job_postings`, `job_sources` and `job_runs` stay shared.

Blocked on one thing: something generates `job_matches` on a schedule. If that writer
does not set `user_id`, every new match arrives owned by nobody, the personal policy
hides it from everyone, and the app looks like it stopped finding jobs. The writer has to
change alongside the schema, not after it.

## A caveat worth keeping honest

Whoever holds `platform`/`app_admin` can grant themselves `app_admin` on any app and read
everything in it. That is inherent to controlling access, not a flaw in the model.
`granted_at` and `granted_by` make such a change visible rather than silent; they do not
prevent it. Preventing it would take a second approver, which is overkill for three
accounts.

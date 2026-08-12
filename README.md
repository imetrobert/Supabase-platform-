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

### Inviting someone

**Invite** on that page takes an address and a set of apps, and does the whole thing in
one call: creates the account, emails an invitation, and writes the grants. They choose a
password at **https://access.imetrobert.com/invite.html**, and from then on they can sign
in to exactly those apps and nothing else — which is not something the invitation
arranges, but simply what `app_access` already means.

They are told where those apps are, twice: the invitation email lists each one with its
address, and so does the screen where they set their password. Both come from the same
grant, so neither can advertise something they cannot open. An app with no address on
file is still named — knowing you have it and not where it is beats not knowing.

Creating an account needs the secret key, so it cannot happen in a browser. It happens in
`public.invite_app_user()` instead, which holds the key in the vault, refuses anyone who
is not a platform admin, and is the most dangerous function on the project — read the
header of `migration/invite_user.sql` before changing it. **It needs one-time setup**
(the vault secret, the redirect URL, the password rules); that file lists it.

Two deliberate limits. An invitation cannot grant `platform` admin — invite them, then
promote them from the grid, which asks first. And deleting an account is still the
Supabase dashboard, because nothing here needs to delete one and a page that can is a
page that can be tricked into it.

Equivalent by hand, if the page is ever unavailable:

```sql
insert into public.app_access (user_id, app, role)
select id, 'job', 'member' from auth.users where email = 'someone@example.com'
on conflict (user_id, app) do update set role = excluded.role;
```

## Files

| | |
|---|---|
| `docs/index.html` | the Access Rights page, served by GitHub Pages |
| `docs/invite.html` | where an invitation email lands — sets the password, shows what they can now reach |
| `email/invite.html` | the invitation email, which lives in the dashboard at runtime; this is the reviewable copy |
| `tests/admin.test.mjs` | drives both pages against a stubbed Supabase — `npm test` |
| `migration/app_access_pattern.sql` | the deployed access model |
| `migration/invite_user.sql` | creates an account, invites it and grants it, in one call — **needs one-time setup** |
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

`migration/audit.sql` is the standing check — five queries, all of which should come
back empty. Run it after touching any policy, view, grant or function.

Check 5 is the newest and exists for the same reason as 3 and 4: a `security definer`
function runs as its owner and sees past every policy here, so checks 1–4 can be clean
while a function hands out their contents. It reports the two ways one goes wrong — an
unpinned `search_path`, which lets the caller choose which table the function reads, and
being executable by `anon`, which is the publishable key in public HTML. Alongside it is
a listing query to read by eye, because "is this function meant to exist" is not
something SQL can answer.

**Checking policies is not enough, and believing it was cost us two real holes.** Views
have no policies, so a policy audit cannot see them; and a view created without
`security_invoker` reads its tables with its *owner's* rights, bypassing the policies
beneath it rather than inheriting them.

- `job_ranked` was granted to `authenticated` with no `security_invoker`. Every `job_*`
  table was correctly gated, and all 1,337 postings and match write-ups were readable
  through the view by accounts with no `job` grant.
- `invoices_et` was the same, **and granted to `anon`** — so every invoice, with client
  names, addresses and amounts, was readable by anyone holding the publishable key that
  ships in public HTML. It also exposed `view_token`, so the tokens authorising public
  invoice links leaked alongside the invoices.

Both are fixed. The lesson is in `audit.sql`: gating tables is not the same as gating
access.

## Open

<a name="open"></a>

**Per-user rows for `job`.** It is gated but not row-scoped — correct while it has one
user, wrong the moment it has two.

**Planned, not scheduled — see [`plans/job-per-user-access.md`](plans/job-per-user-access.md).**
That document is the design: the four decisions to make before writing any code, the work
in order, and how to verify it in a repo with no test suite. Do not start from this
summary.

This is a project, not a migration, and the recommendation is to leave it until a second
job-seeker actually needs it:

- `job_matches` is keyed one row per posting, so two users' verdicts **collide** on the
  primary key — per-user matches are impossible, not merely unattributed
- `job_profile` declares `check (id = 1)`; a second profile is physically forbidden
- the scan runs under the service role with no auth context and loads `job_profile`
  where `id = 1`. It has no concept of users — no loop, no parameter, no column
- the edge function authenticates the caller and then discards the identity, reading
  profile `id = 1` regardless
- `alreadyScored`, the LLM budget cap, `scoreById`, deadline expiry and query building
  all assume a single profile
- and the repo has **no test suite** — the only verification is running a real scan
  against the real database

Fixed and landed in the meantime: dismissing a role used to delete the shared
`job_postings` row, and `job_matches` and `job_applications` cascade off it — so a
dismissal destroyed the match write-up, application status and any generated cover
letter, for everyone. Dismissal now writes only the suppression row, and the DELETE
policy on `job_postings` is gone, so the app cannot delete a posting even if the code
tries again.

## A caveat worth keeping honest

Whoever holds `platform`/`app_admin` can grant themselves `app_admin` on any app and read
everything in it. That is inherent to controlling access, not a flaw in the model.
`granted_at` and `granted_by` make such a change visible rather than silent; they do not
prevent it. Preventing it would take a second approver, which is overkill for three
accounts.

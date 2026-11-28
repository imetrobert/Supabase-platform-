# Common edits — recipes (Access Rights, access.imetrobert.com)

Each recipe lists the exact place to change. Keep to it; do not read whole files.

## 1. Add a new app to the access system
An app is just a text id in `app_access.app`. Pick the id (lowercase, e.g. `planners`).
1. **The page:** `docs/index.html`, add a line to the `APPS` array:
   `{ id: 'planners', name: 'Retirement Planners', url: 'https://planners.aiwithrobert.com' },`
2. **The invite landing page:** `docs/invite.html`, add the same id/name/url to its `APPS` map.
3. **The invitation function:** `migration/invite_user.sql`, add one `jsonb_build_object` line to
   `catalog`. Then run the WHOLE file's `create or replace function` block in the Supabase SQL
   editor (editing the file alone changes nothing live).
   Do the same for `migration/resend_invite.sql` (its own `catalog` copy).
4. **The test:** `tests/admin.test.mjs`, raise `APPS_WITH_URLS` by one.
5. **The README table** ("The apps") — add a row.
6. In the new app's own repo: tables use `has_app_access('planners')` (see recipe 5).
The id must be identical everywhere, including in the app's own policies.

## 2. Change an app's address or display name
Same three copies as recipe 1 (page, invite page, `invite_user.sql` catalog). Missing one makes
invitation emails link to a dead address while the page looks fine. Re-run the function in SQL.

## 3. Grant, change or remove someone's access by hand
Normally use the page. By SQL (Supabase SQL editor):
```sql
-- grant
insert into public.app_access (user_id, app, role)
select id, 'job', 'member' from auth.users where email = 'someone@example.com'
on conflict (user_id, app) do update set role = excluded.role;
-- revoke one app
delete from public.app_access
where app = 'job' and user_id = (select id from auth.users where email = 'someone@example.com');
```
To lock someone out completely but keep their data, remove all their `app_access` rows (do not
delete the account). `migration/list_app_users.sql` lists who holds what.

## 4. Invite someone
On the page: **Invite**, enter email, choose apps. If it fails, the one-time setup in the header
of `migration/invite_user.sql` (vault secret, URL fields, password rules) is missing.
Custom SMTP should be set before inviting real clients (built-in sender is rate limited).

## 5. Gate a new table in any app
In that app's migration, in the SAME file:
```sql
alter table public.<t> enable row level security;
create policy "<t> app access" on public.<t> for all to authenticated
  using (public.has_app_access('<app>')) with check (public.has_app_access('<app>'));
grant select, insert, update, delete on public.<t> to authenticated;
```
For one person's own rows use the `personal` shape in `migration/app_access_pattern.sql`
(adds `and user_id = auth.uid()`). Then run `migration/audit.sql`: no rows expected.

## 6. Delete an account (no undo)
Page → person → Delete account. First run the opening query of `migration/delete_user.sql` to see
what data would go with it.

## 7. After any policy, view or function change
Run `migration/audit.sql` (five checks, all empty). For a new policy prove it with
`migration/verify_access.sql`.

## 8. Update or run the tests
`npm install` then `npm test` (Playwright, terminal needed). If no terminal, skip tests and
check the page by hand: sign in, open a person, change a cell, open Invite.

## Private app (only one named account may ever hold it)
Today: `retire-personal` (the personal retirement planner). Two layers: the page (`PRIVATE_APPS` in `docs/index.html`) never
offers it on anyone else's row or on the invitation form, and the database (`migration/private_apps.sql`: table
`private_app_owner` + trigger `guard_private_app` on `app_access`) refuses any grant to a different user, even from the API or the invite function.
To make another app private: add its id to `PRIVATE_APPS`, then in the Supabase AI assistant insert `(app, owner user_id)` into
`public.private_app_owner`. To change the owner, update that row (use the assistant). Run `migration/audit.sql` afterwards.

## Invitation link language (Quebec planner)
The invite form shows "Link to send for the Quebec planner: English link / French link" once Quebec Retirement Planner is given a role. The choice travels as `lang` on that grant (`{app:'retire-qc', role, lang:'fr'}`); `invite_app_user` swaps the email link to retraiteqc.aiwithrobert.com when `lang` is `fr`. The function in the Supabase project must be updated for this (paste-ready prompt in the pull request that added it); until then every email carries the English link, harmlessly. `invite.html` always shows both links for this app.
In the grid, anyone holding the Quebec planner has "Copy a link to send" with English and French buttons (copies retireqc / retraiteqc.aiwithrobert.com).

## Resend an invitation (people who never accepted)
The grid shows "invited YYYY-MM-DD, not accepted yet" for such people, and their card has a **Resend invitation** button (not on your own row). It calls `public.resend_app_invite(target_user_id)` from `migration/resend_invite.sql`: admin-only guard first, refuses anyone who already accepted or was never invited, shares the 10-per-hour brake with `invite_app_user`, refreshes the "apps" list in the email from the person's CURRENT grants, then asks Auth to send the invite again (new link). Keeps the French Quebec link if the first email used it. The send is queued in the background (pg_net) because signed-in calls are cut off at 8 seconds; the page then asks public.resend_invite_status(request_id) for Supabase's answer (sent, or refused with the reason such as the email rate limit). Both functions live in the one file. The function holds a FOURTH copy of the app catalog: recipes 1 and 2 must also edit it (and re-run the function in SQL). If the person lost an already-accepted invite, use "Forgot password" in the app instead; do not delete them.

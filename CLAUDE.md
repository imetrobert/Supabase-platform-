# Supabase-platform- (Access Rights, access.imetrobert.com) — read this first, it is the map

Controls who can enter which app on the shared Supabase project `ipnajvgwtjrlecbqfwrh`, and
is the page (`docs/index.html`) that grants it. `README.md` explains the model in full; read
only the section you need. Recipes for the usual edits: `COMMON-EDITS.md`.

## Rules (non-negotiable)
- This repo guards every private app. A mistake here can expose other apps' data, so change
  as little as possible, and never loosen a policy "to make something work".
- Never commit secrets. The page holds only the publishable key (`sb_publishable_...`),
  which is public by design. The secret key lives only in the Supabase vault.
- Revoking access takes effect on the next query; deleting an account is NOT undoable. Prefer
  "set every app to None" to lock someone out.
- After touching any policy, view, grant or function, run `migration/audit.sql` in the Supabase
  SQL editor: all five checks must return no rows.
- New table in any app: explicit Data API grants in the same migration, and a policy that uses
  `has_app_access('<app>')` (see `migration/app_access_pattern.sql` for the two policy shapes).
- Free tier only.

## Where things are
- `docs/index.html` — the page. `APPS` array near the top lists every app (id, name, url).
- `docs/invite.html` — where an invitation lands; has its own `APPS` map.
- `email/invite.html` — reviewable copy of the invitation email (the live one is in the Supabase
  dashboard).
- `migration/invite_user.sql` — `public.invite_app_user()`; contains a third copy of the app
  catalog (`catalog constant jsonb`). Editing the file does NOT change the live function: the
  whole function must be re-run in the Supabase SQL editor.
- `migration/resend_invite.sql` — `public.resend_app_invite(uuid)` and `public.resend_invite_status(bigint)` (reports Supabase's answer to the page), behind the "Resend invitation" button on pending people. Admin guard first; refuses accepted accounts; shares the 10/hour cap; queues the send with `pg_net` (inline sends are cut off at 8s). Holds a FOURTH app catalog copy. Re-run the whole function in Supabase after editing.
- `migration/app_access_pattern.sql` — the deployed access model. `audit.sql` — standing check (check 5 skips nine functions that are public on purpose; a new anon-callable definer function should be a surprise).
  `verify_access.sql` — proves a policy by impersonating accounts.
- `tests/admin.test.mjs` — `npm test` (needs Playwright; use only if a terminal is available).
  It hard-codes `APPS_WITH_URLS` (number of apps with an address). Update it when apps change.
- Hosting: GitHub Pages from `docs/`, domain in `CNAME` and `docs/CNAME`.

## Cheap-change guide
- Add, rename or move an app: FOUR catalog copies must match (index.html, invite.html, invite_user.sql, resend_invite.sql). See COMMON-EDITS.md.
- Grant or revoke by hand: SQL in COMMON-EDITS.md, or the page itself.
- Never edit `docs/index.html` wholesale; change the one block.

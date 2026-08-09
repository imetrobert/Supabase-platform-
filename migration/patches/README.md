# Patches waiting to land elsewhere

Changes made for another repository that could not be pushed from the session that
wrote them, parked here so they survive. Delete each one once it has landed.

## `fb-marketplace-app-access.patch`

Target: [imetrobert/Facebook-marketplace-generator](https://github.com/imetrobert/Facebook-marketplace-generator)

Moves that app off its hardcoded `ACCESS.allowedEmails` array and onto the shared
`app_access` grant — the same model as `app_access_pattern.sql` in the parent directory.
The grant is checked twice: in the browser so a refused visitor gets a clear message, and
inside the row level security policies on `profiles`, which is the boundary that actually
holds. All 10 Playwright suites pass with it applied.

It could not be pushed because that repository was not in the authoring session's
authorized source set, and the approval prompt to add it never surfaced.

To land it:

```bash
git clone https://github.com/imetrobert/Facebook-marketplace-generator.git
cd Facebook-marketplace-generator
git checkout -b claude/supabase-db-migration-6lqrhw
curl -sSL https://raw.githubusercontent.com/imetrobert/Supabase-platform-/main/migration/patches/fb-marketplace-app-access.patch | git am
npm install && npx playwright install chromium && npm test
git push -u origin claude/supabase-db-migration-6lqrhw
```

**Do not merge it before `app_access_pattern.sql` has run on the project.** Both the
policies and the browser check call `has_app_access()`; without that function every
policy references something that does not exist, fails closed, and locks the app's users
out — including the owner.

# If something breaks (read this first, then fix only what it names)

1. **A red check or an email from GitHub:** Actions tab, open the failed run, read the last 20 lines of the red step. "Pages build and deployment" red once: re-run the job (usually a transient GitHub error).
2. **A pull request (for example from Dependabot) has a red "PR build check" or "Checks":** do not merge it; open the red step and fix or close the PR.
3. **Someone cannot get into an app:** check the person's rows on the access page (access.imetrobert.com); see `COMMON-EDITS.md` for the SQL to grant or revoke by hand. Revoking takes effect on the next query.
4. **After touching any policy, view, grant or function:** run `migration/audit.sql` in the Supabase SQL editor; all five checks must return no rows. Never loosen a policy to make something work.
5. **Invitation email not arriving:** `migration/resend_invite.sql` and the Brevo SMTP notes in the hub's `docs/EMAIL-SETUP.md`. The app catalog exists in FOUR places (see CLAUDE.md); they must match.

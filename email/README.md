# The invitation email

`invite.html` is the body for **Authentication → Emails → Invite user** in the Supabase
dashboard. Paste it in whole; there is nothing to build. Subject line:

> You have been given access

## Why it is here and not only there

The dashboard is the only place this template exists at runtime — it is a project
setting, not a file the project reads. Keeping a copy here means the wording is
reviewable, has a history, and can be restored after somebody edits it in a hurry. If you
change it in the dashboard, change it here too; nothing enforces that.

## What it can see

Supabase renders these as Go templates. Alongside the built-ins — `{{ .ConfirmationURL }}`,
`{{ .Email }}`, `{{ .SiteURL }}` — this one reads what `public.invite_app_user()` attached
to the account when it sent the invitation:

| | |
|---|---|
| `{{ .Data.apps }}` | the granted apps, each with `name`, `url` (may be absent) and `role` |
| `{{ .Data.app_list }}` | the same thing already flattened to one line per app |
| `{{ .Data.invited_by }}` | the email address of whoever sent it |

`.Data` is the account's `user_metadata`, which the account holder can edit. That is fine
for an email that was already sent, and it is the reason nothing anywhere reads it to
decide anything. Access is `app_access` and only `app_access`.

## If the list does not render

`{{ range .Data.apps }}` is the part most likely to fail on a given project, and it fails
by rendering nothing rather than by complaining — so **send yourself one and read it**
before inviting a real person. That is what `app_list` is for. Swap the `{{ if .Data.apps }}`
block for:

```html
{{ if .Data.app_list }}
<p style="margin:0 0 8px;color:#6b7280;font-size:13px">You will be able to sign in to these, and only these:</p>
<p style="margin:0 0 22px;white-space:pre-line">{{ .Data.app_list }}</p>
{{ end }}
```

It loses the styling and the administrator note, and it cannot fail.

## Testing it

Invite an address you own, read the mail, then delete the account —
Authentication → Users → the row → Delete. The `app_access` rows go with it, on delete
cascade. Do not test against an address you actually want invited: accepting the link
sets the password, and the invitation cannot be sent twice to the same address.

The links in the email are plain URLs to each app. They are not authenticated and they
are not secret — the invitation's one-use token is in the button at the top and nowhere
else.

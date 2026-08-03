# Policy patterns

House rules for new tables and new apps on these projects. Each one exists
because of something that actually went wrong or was actually found — the
incident is cited so the rule can be re-argued later rather than followed on
faith.

Default to these. Deviating is fine, but write down why.

---

## 1. Public reads scoped by a secret

**Rule.** An unauthenticated read scoped by a secret — a token, a share link, a
slug — goes through a `security definer` function that takes the secret **as an
argument** and returns `setof` a view that whitelists columns. Never through a
policy on the table plus a filter in the request.

**Why.** This is the one worth internalizing:

> Row Level Security is evaluated per row and can only see the row. It cannot see
> the token in the URL or the filter attached to the request. A policy can
> therefore never verify that the caller supplied the right token — only that the
> row has one. Any scoping expressed as a request filter is scoping the caller
> controls, and a caller can remove it.

**What it looks like when you get it wrong.** A policy of
`using (view_token is not null)` with the page querying
`?view_token=eq.<token>`. It reads like it works, and it does work for honest
callers. But the policy is true for every row that was ever sent, and the filter
is the client's to drop: one request with no filter and the publishable key
returned every invoice in the table, `view_token` included — enough to build a
working link for anyone. Found and fixed 2026-08-03; see
[`../migrations/LOG.md`](../migrations/LOG.md).

**The shape.**

```sql
create or replace view public.thing_public_v
with (security_invoker = on) as
  select id, safe_col_a, safe_col_b   -- the select list IS the whitelist
  from public.things;

revoke all on table public.thing_public_v from anon, authenticated, public;

create or replace function public.thing_by_token(token text)
returns setof public.thing_public_v
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select v.* from public.thing_public_v v
  where v.id in (select t.id from public.things t where t.secret::text = token);
$$;

revoke all on function public.thing_by_token(text) from public;
grant execute on function public.thing_by_token(text) to anon;
```

Four details in there that are all load-bearing:

- **`returns setof <view>`**, not `returns table (...)`. A hand-written column
  list paired with a hand-written select list can silently transpose two
  same-typed columns — `client_name` and `client_email` — and render wrong
  without raising anything. Returning `setof` the view makes the declared shape
  and the projection the same object, so they cannot drift.
- **Take the secret as `text` and cast on the column side** (`secret::text =
  token`). A malformed token then returns zero rows instead of raising, so the
  app's existing "not found" screen handles it. A `uuid` parameter raises on
  garbage input.
- **`revoke` the view from `anon` even though it has `security_invoker`.** Belt
  and braces — one is not a replacement for the other.
- **Whitelist by select list.** Anything not named is excluded. Internal columns
  — the token itself, send logs, view counters — never reach a client.

## 2. Every view gets `security_invoker = on`

**Rule.** Set it on every view in a PostgREST-exposed schema, including views you
believe nothing reads.

**Why.** A view runs with its *owner's* rights by default, so it reads its base
tables with RLS bypassed. PostgREST publishes views at `/rest/v1/<view>`. A view
whose safety rests only on a revoke is one blanket `grant select on all tables in
schema public to anon` — or one tool re-applying Supabase's default privileges —
away from being a full read of the base table, **with no policy change for an
audit to notice**. `security_invoker = on` makes the view defend itself.

Found on `invoice_public_v` 2026-08-03. It was not exploitable at the time; it
was one careless grant away from being so.

Section 6 of [`../queries/inventory.sql`](../queries/inventory.sql) lists every
view that lacks it.

## 3. `security definer` implies `set search_path = public, pg_temp`

**Rule.** Every definer function gets it. `pg_temp` **last**, always.

**Why the ordering.** When `pg_temp` is not listed at all, PostgreSQL searches
the temporary schema *first* for relation names — which is precisely the hijack
the setting exists to prevent. A bare `search_path = public` does not close it.
Listing `pg_temp` last forces it to the end of the search order.

Mostly hygiene rather than an active hole: `anon` reaches the database only
through PostgREST and cannot execute the arbitrary SQL that shadowing an object
would require. Do it anyway — it is free, and the reasoning that makes it safe
today is exactly the kind that stops being true quietly.

Invoker functions (ordinary triggers, say) are not affected; they run as the
calling user.

## 4. Never create two overloads with the same parameter name

**Rule.** One signature per function name for anything reachable via `rpc()`. If
you need to change a signature, drop the old one in the same session.

**Why.** PostgREST resolves RPC arguments **by name, not by type**. Two
overloads sharing a parameter name make every `rpc()` call ambiguous, and it
fails silently. Plain SQL keeps working, because SQL resolves overloads by type
— so the function tests fine when you call it directly, and the bug looks like
anything but what it is.

`increment_invoice_view` had `(token text)` and `(token uuid)`. Click counting
was dead for **two months**. The counters read 1 across the entire table and
nobody noticed, because nothing errored anywhere a human would look. Worse, the
`uuid` overload was most likely created *during a debugging session for this very
failure* — the attempted fix was the cause.

The last query in section 5 of
[`../queries/inventory.sql`](../queries/inventory.sql) is the cheap check.

## 5. A policy must identify the caller, not describe the row

**Rule.** Read every policy predicate and ask: *does this tie the row to the
person asking?* If it only describes the row, it is not access control.

Both of these are row descriptions and neither is real scoping:

```sql
using (view_token is not null)              -- true for every row ever sent
using (auth.role() = 'authenticated')       -- true for every account, any app
```

The second one is the trap on a **shared project**, where several apps point at
one database. It reads as "logged in", which sounds right, but it grants access
to any authenticated account in the project regardless of which app that account
belongs to — every app's users end up sharing a single trust boundary. It is
currently the only policy on `public.invoices`; see
[`../migrations/PLAN.md`](../migrations/PLAN.md).

What identifies a caller: `auth.uid() = owner_id`, or a join through a
membership table. `auth.role()` does not.

**Corollary for shared projects.** Before writing any policy, ask who can obtain
an authenticated session at all. If signups are open, `authenticated` means
anyone on the internet who filled in a form.

## 6. Unique-index anything the app looks up as a single row

**Rule.** If code fetches by a value and takes one row, the database must
guarantee there is only one.

**Why.** `data[0]` on a non-unique lookup silently returns *a* row, not *the*
row. For a token lookup that means rendering one client's invoice to another —
no error, no clue anything is wrong. `.single()` at least raises, but the
constraint belongs in the database, where it holds regardless of which caller
forgets.

`invoices_view_token_key` was added 2026-08-03 for exactly this. Note that
unique permits many NULLs, so unsent drafts without a token are unaffected.

If `CREATE INDEX CONCURRENTLY` fails in the Supabase SQL editor, that is its
implicit transaction — concurrent builds cannot run inside one. On a small table,
just build it non-concurrently and accept the brief lock.

## 7. Broad grants to `anon` are normal; check the policies instead

**Not a rule — a thing that looks alarming and is not.**

`anon` and `authenticated` holding full DML on every table in `public` is
Supabase's **default**, not a misconfiguration. RLS is what actually gates
access. Do not "fix" it by revoking grants wholesale; you will break PostgREST
in confusing ways.

The corollary is the part that matters: since the grants are wide open by
default, **the policies are the entire access control story.** Read sections 4
and 7 of the inventory query together, never section 7 alone.

## 8. Write down what you decided not to do

**Rule.** A risk that is accepted rather than fixed gets recorded, with the cost
of fixing it and why that cost won.

An undocumented accepted risk is indistinguishable from an oversight six months
later, and someone — probably you — will either re-derive the whole argument
from scratch or "fix" it without knowing what it costs. The token-rotation entry
in [`../migrations/PLAN.md`](../migrations/PLAN.md) is the worked example:
one SQL statement, and a genuinely hard business consequence that is the actual
reason it hasn't been run.

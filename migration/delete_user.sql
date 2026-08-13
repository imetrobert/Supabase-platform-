-- Delete an account, from the Access Rights page.
--
-- The counterpart to invite_user.sql, and the same reasoning: removing an
-- account needs the secret key, so the privileged half lives here and the page
-- calls it. Read that file's header first — the warnings about SECURITY
-- DEFINER, the guard order and the vault apply here unchanged.
--
-- One difference matters. An invitation that goes to the wrong address is
-- embarrassing and recoverable: delete the pending account and send another.
-- A deletion is neither. There is no undo, no soft-delete, no copy kept
-- anywhere — which is why this function refuses three things outright rather
-- than trusting the page to have asked nicely.


-- BEFORE YOU DEPLOY THIS, know what a deletion takes with it ----------------
--
-- app_access declares `references auth.users(id) on delete cascade`, so grants
-- go when the account goes. That is intended. What is NOT known without
-- looking is what every OTHER table on this project does — these six apps
-- store personal rows, and a cascade you have forgotten about will take them
-- silently.
--
-- Run this first. It is the whole risk assessment:
--
--   select c.conrelid::regclass as referencing_table,
--          a.attname as column_name,
--          case c.confdeltype
--            when 'c' then 'CASCADE — these rows are DELETED with the account'
--            when 'n' then 'SET NULL — these rows survive, owned by nobody'
--            when 'd' then 'SET DEFAULT — these rows survive, reassigned'
--            when 'r' then 'RESTRICT — the deletion FAILS while rows exist'
--            when 'a' then 'NO ACTION — the deletion FAILS while rows exist'
--          end as what_happens
--   from pg_constraint c
--   join unnest(c.conkey) with ordinality as k(attnum, ord) on true
--   join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
--   where c.confrelid = 'auth.users'::regclass and c.contype = 'f'
--   order by 1;
--
-- Every CASCADE row is data that vanishes. Every RESTRICT or NO ACTION row is
-- a deletion that will fail — and it fails at the auth API, coming back as an
-- unhelpful 500 rather than as the foreign key error it really is.
--
-- If that list contains anything you would not want to lose, do not deploy
-- this function. Revoking every grant leaves the person unable to reach
-- anything while keeping their data, and is reversible.
--
-- Run on 2026-08-13, that query answered:
--
--   auth.*                  eight tables, all CASCADE — sessions, identities,
--                           mfa factors, one-time tokens. Housekeeping; this
--                           is what deleting an account means.
--   profiles                CASCADE — their fb-marketplace profile
--   cartmatch_user_prefs    CASCADE — their price-checker preferences
--   app_access.user_id      CASCADE — their grants, as intended
--   app_access.granted_by   NO ACTION — see the note in the function
--
-- Two things follow. Personal data is limited to two rows in two apps, and
-- everything else on the project — claims, invoices, the etf_* and job_*
-- tables — is shared reference data that a deletion does not touch. And
-- granted_by would have blocked deletions outright; the function clears it
-- rather than letting that surface as a 500.
--
-- What that query CANNOT see is a user_id column with no foreign key behind
-- it, which leaves rows orphaned instead of deleted — pointing at an account
-- that no longer exists, invisible to every policy that joins on it. Worth
-- checking alongside:
--
--   select c.relname as table_name, a.attname as column_name
--   from pg_class c
--   join pg_namespace n on n.oid = c.relnamespace
--   join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
--   where n.nspname = 'public' and c.relkind = 'r'
--     and a.attname in ('user_id', 'owner_id', 'created_by', 'granted_by')
--     and not exists (
--       select 1 from pg_constraint fk
--       where fk.conrelid = c.oid and fk.contype = 'f'
--         and a.attnum = any (fk.conkey)
--         and fk.confrelid = 'auth.users'::regclass)
--   order by 1, 2;
--
-- Anything it returns is a table whose rows survive their owner. That is not
-- automatically wrong — but it should be a decision, not a discovery.
--
-- On 2026-08-13 it returned three, all in one app:
--
--   cartmatch_audit_records       user_id, no foreign key
--   cartmatch_price_observations  user_id, no foreign key
--   cartmatch_validations         user_id, no foreign key
--
-- cartmatch_user_prefs has the foreign key and cascades; these three do not.
-- That inconsistency inside a single app is the actual defect — not the
-- orphans, which are only its symptom. Under the personal shape an orphaned
-- row is permanently unreachable: no auth.uid() will ever match a deleted
-- account, so no policy can see it and nothing will ever clean it up.
--
-- Bringing them in line, once the orphan count for each is zero:
--
--   alter table public.cartmatch_price_observations
--     add constraint cartmatch_price_observations_user_id_fkey
--     foreign key (user_id) references auth.users(id) on delete cascade;
--
--   -- and the same for cartmatch_validations, and for
--   -- cartmatch_audit_records IF an audit trail should die with its subject.
--   -- That last one is a real question rather than a formality: cascading
--   -- means deleting someone erases the record of what they did. Usually
--   -- right, and the privacy-respecting default — but decide it rather than
--   -- inherit it.
--
-- Counting existing orphans first is not optional. A table that already
-- violates the constraint will refuse it, and the refusal is the useful
-- answer: it means rows are already pointing at accounts that are gone.


create or replace function public.delete_app_user(target_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  project_url  constant text := 'https://ipnajvgwtjrlecbqfwrh.supabase.co';
  secret_key   text;
  response     extensions.http_response;
  target_email text;
  err_msg      text := '';
begin
  -- The guard. First, and raising, for the same reason as in invite_app_user:
  -- a filter on a function with side effects does nothing while reporting
  -- success, and this function's side effect is that a person is gone.
  if not public.is_platform_admin() then
    raise exception 'not authorised to delete accounts'
      using errcode = 'insufficient_privilege';
  end if;

  if target_user_id is null then
    raise exception 'no account given';
  end if;

  -- Refusal 1: yourself. Deleting the account you are signed in as would end
  -- the session mid-request and, if you were the only platform admin, leave
  -- nobody able to grant anything ever again. Recovery would mean the SQL
  -- editor. The page hides this too; the refusal is what enforces it.
  if target_user_id = auth.uid() then
    raise exception 'you cannot delete the account you are signed in as';
  end if;

  select email into target_email from auth.users where id = target_user_id;

  -- Refusal 2: someone who does not exist. Not pedantry — it means the page is
  -- working from a stale list, and the id it just sent belonged to somebody.
  if target_email is null then
    raise exception 'no account with that id — reload the page before trying again';
  end if;

  -- Refusal 3: another administrator. Deliberately two steps: take their admin
  -- rights away in the grid, which asks and is reversible, and only then delete
  -- them. It means no single tap can remove someone who could have stopped it,
  -- and it makes an admin takeover leave two marks instead of one.
  if exists (
    select 1 from public.app_access
    where user_id = target_user_id and app = 'platform' and role = 'app_admin'
  ) then
    raise exception '% administers access rights — remove that first, then delete the account',
      target_email;
  end if;

  select decrypted_secret into secret_key
  from vault.decrypted_secrets where name = 'auth_secret_key';

  if secret_key is null then
    raise exception 'no vault secret named auth_secret_key — see the setup note in invite_user.sql';
  end if;

  -- Duplicated from invite_app_user rather than shared, and that is the safer
  -- of the two bad options. A helper that returns the secret key would be one
  -- careless `grant execute on all functions in schema public` away from
  -- handing it to every signed-in account; ten copied lines are only one
  -- careless edit away from drifting. Change one, change the other.
  if secret_key like '%PASTE%' or length(secret_key) < 30 then
    raise exception 'the vault secret auth_secret_key is not a real key (% characters)',
      length(secret_key);
  end if;

  -- app_access.granted_by references auth.users with NO ACTION, so every grant
  -- this person handed out to somebody else blocks their deletion — and the
  -- block happens inside the auth API, which reports it as a bare 500 rather
  -- than as the foreign key error it is. Clearing the attribution first is what
  -- makes the delete possible at all.
  --
  -- Safe to do before knowing whether the deletion succeeds: if the call below
  -- fails we raise, and this update rolls back with it. It only sticks if the
  -- account actually went.
  --
  -- Note what is lost — those grants keep their granted_at and lose their
  -- granted_by, so they read as "granted, by someone no longer here". That is
  -- unavoidable rather than chosen: the whole point of the operation is that
  -- the person is gone. Rows where they granted to themselves are not touched,
  -- because the cascade removes them anyway.
  update public.app_access
  set granted_by = null
  where granted_by = target_user_id and user_id <> target_user_id;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '15');

  select * into response from extensions.http((
    'DELETE',
    project_url || '/auth/v1/admin/users/' || target_user_id::text,
    array[
      extensions.http_header('apikey', secret_key),
      extensions.http_header('Authorization', 'Bearer ' || secret_key)
    ],
    null,
    null
  )::extensions.http_request);

  -- 200 is the success here; 404 means it was already gone, which is not worth
  -- raising over — the caller wanted it absent and it is absent.
  if response.status not in (200, 404) then
    begin
      err_msg := coalesce(response.content::jsonb->>'msg',
                          response.content::jsonb->>'message', '');
    exception when others then
      err_msg := '';
    end;

    raise exception '%', case
      when response.status = 401 then
        'Supabase would not accept the secret key. Whatever is in the vault is wrong, expired '
        || 'or revoked — see the setup note at the top of invite_user.sql. Nothing was deleted.'
      when response.status = 409 or response.status = 500 then
        target_email || ' could not be deleted, usually because something else on the project '
        || 'still refers to this account. Nothing was deleted — the query at the top of '
        || 'delete_user.sql lists what points at auth.users and what each one does.'
      else
        'Deleting ' || target_email || ' was refused (' || response.status || ')'
        || case when err_msg <> '' then ': ' || err_msg else '.' end
        || ' Nothing was deleted.'
    end;
  end if;

  -- Nothing to clean up afterwards: app_access cascades off auth.users, so the
  -- grants went with the account. If that FK is ever changed, this function
  -- starts leaving rows behind that point at nobody — see the note at the top.
  return jsonb_build_object(
    'user_id', target_user_id,
    'email',   target_email,
    'status',  response.status
  );
end;
$$;

revoke execute on function public.delete_app_user(uuid) from public, anon;
grant  execute on function public.delete_app_user(uuid) to authenticated;


-- Checking it works ----------------------------------------------------------
--
-- Every check below should RAISE, and the raise is the pass. None of them
-- reach the network. Run them one at a time; the first failure ends the script.

--   -- Nobody signed in.
--   select set_config('request.jwt.claims', '', false);
--   select public.delete_app_user('00000000-0000-0000-0000-000000000000'::uuid);
--   -- expected: ERROR  not authorised to delete accounts

--   -- An ordinary account.
--   select set_config('request.jwt.claims',
--     (select json_build_object('sub', id, 'role', 'authenticated')::text
--      from auth.users where email = 'oboulian@gmail.com'), false);
--   select public.delete_app_user(
--     (select id from auth.users where email = 'sheldonrozansky@gmail.com'));
--   -- expected: ERROR  not authorised to delete accounts

--   -- A platform admin, refused on the three cases that matter.
--   select set_config('request.jwt.claims',
--     (select json_build_object('sub', id, 'role', 'authenticated')::text
--      from auth.users where email = 'robert@imetrobert.com'), false);
--
--   select public.delete_app_user(
--     (select id from auth.users where email = 'robert@imetrobert.com'));
--   -- expected: ERROR  you cannot delete the account you are signed in as
--
--   select public.delete_app_user('00000000-0000-0000-0000-000000000000'::uuid);
--   -- expected: ERROR  no account with that id
--
--   -- Grant platform/app_admin to a second account first, then:
--   -- expected: ERROR  ... administers access rights — remove that first
--
--   select set_config('request.jwt.claims', '', false);

-- The happy path has no safe rehearsal. Test it on an account created for the
-- purpose — invite one, accept nothing, delete it — and confirm afterwards
-- that both the account and its grants are gone:
--
--   select count(*) from auth.users where email = 'the-test-address@example.com';
--   select count(*) from public.app_access a
--   where not exists (select 1 from auth.users u where u.id = a.user_id);
--
-- Both zero. The second is the one that matters: a non-zero answer means the
-- cascade did not fire and grants are pointing at accounts that no longer
-- exist.

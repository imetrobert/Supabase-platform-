-- Create an account, email it an invitation, and hand out its grants — in one
-- call, from the Access Rights page.
--
-- Why this exists at all: creating an account needs the project's SECRET key,
-- and no secret key belongs in a browser. Until now the page said so and left
-- account creation to the Supabase dashboard, which meant two places, two
-- steps, and a window where a new account existed with no grants at all.
--
-- This closes that by moving the privileged half into the database, where the
-- secret key can live in the vault and the caller is already identified. The
-- page still holds nothing but the publishable key; it calls this function and
-- the function decides whether to obey.
--
--
-- THIS IS THE MOST DANGEROUS FUNCTION ON THE PROJECT. Read before changing it.
--
-- It is SECURITY DEFINER, it is callable by `authenticated`, it reads the
-- secret key, and it makes an outbound HTTP request. Every one of those is
-- deliberate and every one of them is a reason the guard below must stay
-- exactly where it is: first, and RAISING.
--
-- Note the difference from list_app_users(), which guards with a WHERE clause
-- and returns an empty set to anyone else. That is right for a read — the
-- caller cannot even distinguish "no users" from "not allowed". It is wrong
-- here. A filter on a function with side effects silently does nothing while
-- reporting success, and this function's side effects are an account and an
-- email. It must refuse loudly instead.


-- Setup, once ----------------------------------------------------------------
--
-- 1. The http extension, which the project already has from the migration:
--
--      create extension if not exists http with schema extensions;
--
-- 2. The secret key, in the vault. Get it from Project Settings → API keys.
--    Never paste it anywhere else — not into this file, not into the page.
--
--    NAME THE ARGUMENTS, and run it in a SQL Editor tab as `postgres`:
--
--      select vault.create_secret(
--        new_secret => 'sb_secret_REPLACE_ME',
--        new_name   => 'auth_secret_key');
--
--    Both halves of that are scar tissue. The positional order of
--    (secret, name, description) has varied between Vault versions, and
--    getting it wrong fails SILENTLY in the worst way: the description lands
--    in `name`, the lookup further down finds nothing, and the eventual error
--    is about this function rather than about the secret. Naming them cannot
--    go wrong. The description is omitted for the same reason — it is
--    optional, and it is the argument that does the damage.
--
--    And run it in the editor, not the dashboard's AI assistant panel: that
--    executes as a restricted role which cannot write to the vault, and
--    reports the refusal as though the whole approach were wrong. Direct
--    INSERT or UPDATE on vault.secrets is refused for everyone — the
--    vault.* functions are SECURITY DEFINER and write where you cannot.
--
--    THEN CHECK THE NAME LANDED, AND THAT A REAL KEY LANDED WITH IT:
--
--      select name, left(decrypted_secret, 12) as starts_with,
--             length(decrypted_secret) as len
--      from vault.decrypted_secrets where name = 'auth_secret_key';
--
--    One row, named exactly auth_secret_key, starting 'sb_secret_', and over
--    forty characters long. A length near twenty-six means the placeholder
--    above went in verbatim — which stores perfectly happily and fails much
--    later, as "Invalid API key" from Auth. The function now refuses that
--    case up front, but the check here is what saves the round trip.
--
--    To rotate it later:
--
--      select vault.update_secret(
--        (select id from vault.secrets where name = 'auth_secret_key'),
--        new_secret => 'sb_secret_THE_NEW_ONE');
--
-- 3. Allow the page to be an invite destination, or every link in every
--    invitation email will bounce to the site root having consumed its token:
--    Authentication → URL Configuration → Redirect URLs →
--    https://access.imetrobert.com/invite.html
--
-- 4. Password rules, which are a project setting and not something this
--    function or the page can enforce on their own:
--    Authentication → Providers → Email → minimum length 12, required
--    characters lower+upper+digit+symbol, and turn ON the leaked-password
--    check. invite.html mirrors those rules so people see a failure before
--    they submit rather than after, but the server is what enforces them.
--
-- 5. Email. The built-in sender is rate limited to a handful of messages an
--    hour, which is survivable when inviting people one at a time and not
--    otherwise. Set up custom SMTP if this ever becomes routine.
--
-- 6. The invitation itself: Authentication → Emails → Invite user, replaced
--    with email/invite.html. Optional — the stock template still works and
--    still lets them in. What it adds is the list of apps they have been
--    given, with a link to each, which this function attaches to the account
--    as metadata for the template to read. Send yourself one and read it: the
--    list is the part that fails silently if the template does not support it,
--    and email/README.md has the version that cannot.


create or replace function public.invite_app_user(target_email text, grants jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  project_url  constant text := 'https://ipnajvgwtjrlecbqfwrh.supabase.co';
  redirect_url constant text := 'https://access.imetrobert.com/invite.html';
  hourly_cap   constant int  := 10;

  -- Where each app actually lives, so the invitation can say "here is the
  -- thing you have been given" rather than just naming it. An app missing from
  -- here still appears in the email, by its raw id and without a link — a
  -- forgotten entry must not be able to hide access that was granted.
  --
  -- THIS LIST EXISTS THREE TIMES, and all three now hold the same addresses:
  -- here, in docs/index.html for the grid, and in docs/invite.html for the
  -- confirmation screen. Moving an app to a new hostname means three edits,
  -- and the failure when you make two of them is silent and ugly — the page
  -- links correctly while the invitation email sends people somewhere dead.
  --
  -- Three copies of a name was tolerable. Three copies of an address is a
  -- standing bet that nobody ever renames anything. Whichever comes first — a
  -- seventh app or the first hostname change — is when this becomes a
  -- public.app_catalog table that all three read.
  catalog constant jsonb := jsonb_build_object(
    'claims-tracker', jsonb_build_object('name', 'Claims Tracker',  'url', 'https://tax.imetrobert.com'),
    'invoicing',      jsonb_build_object('name', 'Invoicing',       'url', 'https://invoices.imetrobert.com'),
    'etf',            jsonb_build_object('name', 'ETF Tracker',     'url', 'https://etf.imetrobert.com'),
    'job',            jsonb_build_object('name', 'Job Search',      'url', 'https://jobs.imetrobert.com'),
    'cartmatch',      jsonb_build_object('name', 'Price Checker',   'url', 'https://pricecheck.imetrobert.com'),
    'fb-marketplace', jsonb_build_object('name', 'Marketplace Ads', 'url', 'https://fbmarket.imetrobert.com')
  );

  email_clean  text;
  app_json     jsonb;
  app_lines    text;
  secret_key   text;
  response     extensions.http_response;
  entry        jsonb;
  new_user_id  uuid;
  applied      int := 0;
begin
  -- The guard. First, and raising — see the note above.
  if not public.is_platform_admin() then
    raise exception 'not authorised to invite users'
      using errcode = 'insufficient_privilege';
  end if;

  email_clean := lower(trim(target_email));
  if email_clean is null or email_clean !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'not an email address: %', target_email;
  end if;

  -- Everything below this line is validated BEFORE the invitation goes out.
  -- An invitation cannot be recalled, so a bad grant list must fail while it is
  -- still only a failed request and not a stranger holding a live link.

  if grants is not null and jsonb_typeof(grants) <> 'array' then
    raise exception 'grants must be a json array of {app, role}';
  end if;

  for entry in select * from jsonb_array_elements(coalesce(grants, '[]'::jsonb)) loop
    if entry->>'app' is null or entry->>'role' is null then
      raise exception 'each grant needs an app and a role, got %', entry;
    end if;
    if entry->>'role' not in ('member', 'app_admin') then
      raise exception 'unknown role %', entry->>'role';
    end if;
    -- Deliberate: an invitation cannot confer the power to hand out access.
    -- The grid does that, and it asks first — a rejected round trip is a
    -- cheaper mistake than a typo'd address owning the access system.
    if entry->>'app' = 'platform' then
      raise exception 'platform admin cannot be granted by invitation — '
        'invite them first, then promote them from the grid';
    end if;
  end loop;

  -- Checked here rather than left to the API so an existing account does not
  -- get a second invitation. Accepting one resets the password on the account
  -- they already have, which would be a confusing way to lose access.
  if exists (select 1 from auth.users where lower(email) = email_clean) then
    raise exception '% already has an account — set their access from the grid instead',
      email_clean;
  end if;

  -- A brake, not a security control. If an admin session is ever taken over,
  -- this bounds how much mail it can send in someone else's name before anyone
  -- notices. Supabase's own sending limit is lower still.
  if (select count(*) from auth.users
      where invited_at > now() - interval '1 hour') >= hourly_cap then
    raise exception 'too many invitations in the last hour (limit %) — wait, or send it from the dashboard',
      hourly_cap;
  end if;

  select decrypted_secret into secret_key
  from vault.decrypted_secrets where name = 'auth_secret_key';

  if secret_key is null then
    raise exception 'no vault secret named auth_secret_key — see the setup note in invite_user.sql';
  end if;

  -- The placeholder check, which exists because the placeholder went in for
  -- real: 'sb_secret_PASTE_YOURS_HERE' is a well-formed string, it stores
  -- cleanly, it sits under the right name, and every check upstream passes.
  -- Only Auth knows it is nonsense, and all it says is "Invalid API key" —
  -- which reads as a key that expired, not a key that was never pasted.
  --
  -- Length alone separates the two: real keys are comfortably past forty
  -- characters, and nothing legitimate is anywhere near thirty.
  if secret_key like '%PASTE%' or length(secret_key) < 30 then
    raise exception 'the vault secret auth_secret_key is not a real key (% characters) — '
      'the placeholder was probably stored instead of your secret key. Replace it with '
      'vault.update_secret() and check the length is over forty.', length(secret_key);
  end if;

  -- Resolve the apps to names and addresses for the email body. Both shapes
  -- are sent because Supabase's email templates are Go templates and the
  -- looping form is the part most likely not to render on a given project:
  -- `apps` is the structured list a {{ range }} walks, `app_list` is the same
  -- thing already flattened to text for a template that cannot. See
  -- email/invite.html.
  select
    coalesce(jsonb_agg(jsonb_build_object('name', app_name, 'url', app_url, 'role', app_role)
                       order by app_name), '[]'::jsonb),
    string_agg(app_name || coalesce(' — ' || app_url, ''), e'\n' order by app_name)
  into app_json, app_lines
  from (
    select coalesce(catalog -> (g->>'app') ->> 'name', g->>'app') as app_name,
           catalog -> (g->>'app') ->> 'url'                       as app_url,
           g->>'role'                                             as app_role
    from jsonb_array_elements(coalesce(grants, '[]'::jsonb)) g
  ) resolved;

  -- Bounded, because an unreachable auth endpoint would otherwise hold a
  -- database connection open for as long as curl is willing to wait.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '15');

  select * into response from extensions.http((
    'POST',
    project_url || '/auth/v1/invite?redirect_to=' || extensions.urlencode(redirect_url),
    array[
      extensions.http_header('apikey', secret_key),
      extensions.http_header('Authorization', 'Bearer ' || secret_key)
    ],
    'application/json',
    -- `data` becomes the account's user_metadata, which is where an email
    -- template can reach it. Note what that means and do not forget it: THE
    -- USER CAN EDIT THEIR OWN user_metadata. Everything in here is decoration
    -- for one email. It is not a record of anything, it is not consulted by
    -- anything, and it must never be read to decide what someone may do —
    -- app_access is the only answer to that question. It is written once, at
    -- the moment the list is true, and never looked at again.
    jsonb_build_object(
      'email', email_clean,
      'data', jsonb_build_object(
        'apps',       app_json,
        'app_list',   coalesce(app_lines, ''),
        'invited_by', coalesce((select email from auth.users where id = auth.uid()), '')
      )
    )::text
  )::extensions.http_request);

  if response.status <> 200 then
    -- Truncated: the body is an error message, but it arrived over a channel
    -- carrying the secret key and there is no reason to relay it wholesale to
    -- a browser.
    raise exception 'invite refused by auth (%): %',
      response.status, left(coalesce(response.content, ''), 200);
  end if;

  new_user_id := (response.content::jsonb->>'id')::uuid;
  if new_user_id is null then
    raise exception 'invite returned no user id: %', left(coalesce(response.content, ''), 200);
  end if;

  -- The one seam that cannot be made atomic: the account now exists whatever
  -- happens next, because an HTTP request is not covered by this transaction.
  -- If the insert below fails, the grants roll back and the account does not,
  -- leaving someone who can sign in and see nothing at all. That is the safe
  -- direction to fail in, and it is visible — they appear in the grid with no
  -- access, and their grants can be set there by hand.
  insert into public.app_access (user_id, app, role, granted_by)
  select new_user_id, entry->>'app', entry->>'role', auth.uid()
  from jsonb_array_elements(coalesce(grants, '[]'::jsonb)) entry
  on conflict (user_id, app) do update set role = excluded.role;

  get diagnostics applied = row_count;

  return jsonb_build_object(
    'user_id', new_user_id,
    'email',   email_clean,
    'granted', applied
  );
end;
$$;

revoke execute on function public.invite_app_user(text, jsonb) from public, anon;
grant  execute on function public.invite_app_user(text, jsonb) to authenticated;


-- Checking it works ----------------------------------------------------------
--
-- The parts with no side effects can be checked directly. Do NOT "test" the
-- happy path against a real address you care about — it creates a real account
-- and sends real mail. Use an address you own and can delete afterwards, and
-- delete it: Authentication → Users → the row → Delete. The app_access rows go
-- with it, on delete cascade.
--
-- Each check below should RAISE, and the raise is the pass. Run them one at a
-- time, since the first failure ends the script.

--   -- Nobody signed in. The SQL editor runs as postgres with auth.uid() null,
--   -- so this is also what an unauthenticated caller gets: refused.
--   select set_config('request.jwt.claims', '', false);
--   select public.invite_app_user('someone@example.com', '[]'::jsonb);
--   -- expected: ERROR  not authorised to invite users

--   -- An ordinary account, fully authenticated, holding grants on other apps.
--   select set_config('request.jwt.claims',
--     (select json_build_object('sub', id, 'role', 'authenticated')::text
--      from auth.users where email = 'oboulian@gmail.com'), false);
--   select public.invite_app_user('someone@example.com', '[]'::jsonb);
--   -- expected: ERROR  not authorised to invite users

--   -- A platform admin, but the input is wrong. These prove the validation
--   -- runs before anything is sent, so no mail leaves on a bad call.
--   select set_config('request.jwt.claims',
--     (select json_build_object('sub', id, 'role', 'authenticated')::text
--      from auth.users where email = 'robert@imetrobert.com'), false);
--
--   select public.invite_app_user('not-an-address', '[]'::jsonb);
--   -- expected: ERROR  not an email address: not-an-address
--
--   select public.invite_app_user('new@example.com', '[{"app":"platform","role":"app_admin"}]'::jsonb);
--   -- expected: ERROR  platform admin cannot be granted by invitation
--
--   select public.invite_app_user('new@example.com', '[{"app":"job","role":"owner"}]'::jsonb);
--   -- expected: ERROR  unknown role owner
--
--   select public.invite_app_user('robert@imetrobert.com', '[]'::jsonb);
--   -- expected: ERROR  robert@imetrobert.com already has an account
--
--   select set_config('request.jwt.claims', '', false);

-- Who was invited, and what they were given on the way in:
--
--   select u.email, u.invited_at, u.confirmed_at is not null as accepted,
--          string_agg(a.app || ':' || a.role, ', ' order by a.app) as access
--   from auth.users u
--   left join public.app_access a on a.user_id = u.id
--   where u.invited_at is not null
--   group by u.id, u.email, u.invited_at, u.confirmed_at
--   order by u.invited_at desc;
--
-- An account with an invited_at and no confirmed_at has been sent a link and
-- has not used it. Supabase expires those; re-inviting is a fresh call to this
-- function, after deleting the pending account.

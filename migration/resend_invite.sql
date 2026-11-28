-- Resend the invitation email to someone who was invited but never accepted it.
-- Called from the Access Rights page ("Resend invitation" on a pending person).
--
-- Read migration/invite_user.sql first: this is its sibling and it has the same danger. It is SECURITY DEFINER, it reads the
-- secret key from the vault and it sends mail, so the guard is FIRST and RAISING. It needs the same one-time setup
-- (vault secret auth_secret_key, redirect URL, Site URL); if inviting works, this works.
--
-- What it does: for an account that has an invited_at and NO confirmed_at, it refreshes the "apps you were given" list from
-- the person's CURRENT grants (so the email matches the grid, not what was true on the first invitation) and asks Auth to
-- send the invitation again. Auth issues a new link; an older unused link may stop working, which is the point.
-- It refuses anyone who already accepted (they use "forgot password" instead) and anyone never invited.
--
-- It shares the invite function's brake: no more than 10 invitations or resends in an hour.
-- The app catalog below is a FOURTH copy (page grid, invite page, invite_app_user, here): any app rename or new address
-- must be edited here too (docs: COMMON-EDITS.md recipes 1 and 2). An app missing from it still appears by its raw id.
-- Explicit Data API grants are at the bottom, as the repo rule requires for every new function or table.

create or replace function public.resend_app_invite(target_user_id uuid)
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
  catalog constant jsonb := jsonb_build_object(
    'claims-tracker', jsonb_build_object('name', 'Claims Tracker',  'url', 'https://tax.imetrobert.com'),
    'invoicing',      jsonb_build_object('name', 'Invoicing',       'url', 'https://invoices.aiwithrobert.com'),
    'etf',            jsonb_build_object('name', 'ETF Tracker',     'url', 'https://invest.imetrobert.com'),
    'job',            jsonb_build_object('name', 'Job Search',      'url', 'https://jobs.imetrobert.com'),
    'fb-marketplace', jsonb_build_object('name', 'Marketplace Ads', 'url', 'https://fbmarket.imetrobert.com'),
    'toolkit',        jsonb_build_object('name', 'AI with Robert Toolkit', 'url', 'https://toolkit.aiwithrobert.com'),
    'blog-review',    jsonb_build_object('name', 'Blog Review', 'url', 'https://www.imetrobert.com/blog/staging/preview.html'),
    'retire-qc',      jsonb_build_object('name', 'Quebec Retirement Planner',  'url', 'https://retireqc.aiwithrobert.com'),
    'retire-on',      jsonb_build_object('name', 'Ontario Retirement Planner', 'url', 'https://retireon.aiwithrobert.com'),
    'retire-personal', jsonb_build_object('name', 'Personal Retirement Planner', 'url', 'https://retire.imetrobert.com')
  );
  u            auth.users%rowtype;
  secret_key   text;
  response     extensions.http_response;
  app_json     jsonb;
  app_lines    text;
  fr_qc        boolean;
  err_code     text := '';
  err_msg      text := '';
begin
  -- The guard. First, and raising.
  if not public.is_platform_admin() then
    raise exception 'not authorised to resend invitations'
      using errcode = 'insufficient_privilege';
  end if;

  select * into u from auth.users where id = target_user_id;
  if not found then
    raise exception 'no such account';
  end if;
  if u.invited_at is null then
    raise exception '% was never invited through this page, so there is no invitation to resend', u.email;
  end if;
  if u.confirmed_at is not null or u.email_confirmed_at is not null then
    raise exception '% already accepted the invitation. If they cannot sign in, they can use "Forgot password" on the app''s sign-in page.', u.email;
  end if;

  if (select count(*) from auth.users where invited_at > now() - interval '1 hour') >= hourly_cap then
    raise exception 'too many invitations in the last hour (limit %) — wait a while and try again', hourly_cap;
  end if;

  select decrypted_secret into secret_key from vault.decrypted_secrets where name = 'auth_secret_key';
  if secret_key is null then
    raise exception 'no vault secret named auth_secret_key — see the setup note in invite_user.sql';
  end if;
  if secret_key like '%PASTE%' or length(secret_key) < 30 then
    raise exception 'the vault secret auth_secret_key is not a real key (% characters) — see invite_user.sql', length(secret_key);
  end if;

  -- Did the first invitation carry the French Quebec planner link? Keep it that way.
  fr_qc := coalesce(u.raw_user_meta_data::text like '%retraiteqc.aiwithrobert.com%', false);

  select
    coalesce(jsonb_agg(jsonb_build_object('name', app_name, 'url', app_url, 'role', app_role) order by app_name), '[]'::jsonb),
    string_agg(app_name || coalesce(' — ' || app_url, ''), e'\n' order by app_name)
  into app_json, app_lines
  from (
    select coalesce(catalog -> a.app ->> 'name', a.app) as app_name,
           case when a.app = 'retire-qc' and fr_qc then 'https://retraiteqc.aiwithrobert.com'
                else catalog -> a.app ->> 'url' end     as app_url,
           a.role                                       as app_role
    from public.app_access a
    where a.user_id = target_user_id and a.app <> 'platform'
  ) resolved;

  -- Auth does not apply new metadata when it re-sends to an existing pending account, so refresh the list the email template reads.
  update auth.users
     set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
                              || jsonb_build_object('apps', app_json, 'app_list', coalesce(app_lines, ''))
   where id = target_user_id;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '15');

  select * into response from extensions.http((
    'POST',
    project_url || '/auth/v1/invite?redirect_to=' || extensions.urlencode(redirect_url),
    array[extensions.http_header('apikey', secret_key), extensions.http_header('Authorization', 'Bearer ' || secret_key)],
    'application/json',
    jsonb_build_object('email', u.email)::text
  )::extensions.http_request);

  if response.status <> 200 then
    begin
      err_code := coalesce(response.content::jsonb->>'error_code', '');
      err_msg  := coalesce(response.content::jsonb->>'msg', response.content::jsonb->>'message', '');
    exception when others then
      err_code := ''; err_msg := '';
    end;
    raise exception '%', case
      when response.status = 429 or err_code = 'over_email_send_rate_limit' then
        'Too many emails in a short time. This is Supabase''s own sending limit and it clears on its own: try again in an hour. Nothing was changed.'
      when response.status = 422 or err_code in ('email_exists', 'user_already_exists') then
        u.email || ' already has a confirmed account, so there is nothing to resend.'
      when response.status = 401 then
        'Supabase would not accept the secret key in the vault (expired, rotated or deleted). See the fix steps in invite_user.sql.'
      when response.status >= 500 then
        'Supabase had a problem at its end (' || response.status || '). Try again in a few minutes.'
      else
        'The invitation was refused (' || response.status || ')' || case when err_msg <> '' then ': ' || err_msg else '.' end
    end;
  end if;

  return jsonb_build_object('user_id', target_user_id, 'email', u.email, 'apps', jsonb_array_length(app_json));
end;
$$;

-- Data API grants (explicit, as the repo rule requires): signed-in users may call it, and the guard above decides who is obeyed.
revoke execute on function public.resend_app_invite(uuid) from public, anon;
grant  execute on function public.resend_app_invite(uuid) to authenticated;
grant  execute on function public.resend_app_invite(uuid) to service_role;

-- Checking it (each of these should RAISE; the raise is the pass; run one at a time):
--   select set_config('request.jwt.claims', '', false);
--   select public.resend_app_invite('00000000-0000-0000-0000-000000000000');
--   -- expected: ERROR  not authorised to resend invitations
--   -- as a platform admin:
--   select set_config('request.jwt.claims', (select json_build_object('sub', id, 'role', 'authenticated')::text from auth.users where email = 'robert@imetrobert.com'), false);
--   select public.resend_app_invite((select id from auth.users where email = 'robert@imetrobert.com'));
--   -- expected: ERROR  robert@imetrobert.com was never invited ... OR already accepted
--   select set_config('request.jwt.claims', '', false);

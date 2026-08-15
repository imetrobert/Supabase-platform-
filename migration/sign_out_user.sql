-- End somebody's sessions, so a revocation cannot be outlived.
--
-- Read this first, because it changes what the function is for: REVOKING A
-- GRANT ALREADY TAKES EFFECT IMMEDIATELY. Every policy on this project calls
-- has_app_access(), which reads app_access at query time. Delete the row and
-- the next query that person's app makes returns nothing. There is no cache to
-- wait out and no session to expire.
--
-- What this function adds is narrower, and worth stating exactly.
--
-- A Supabase access token is a signed JWT. PostgREST validates it by signature
-- and expiry and does not ask the database whether the account still exists or
-- still holds anything. So after a revocation the token stays valid for up to
-- the project's JWT expiry — one hour by default. It opens nothing, because
-- everything is gated on app_access and app_access no longer says yes.
--
-- "Opens nothing" is true exactly as long as every table and view on the
-- project is correctly gated. That has been false here twice: job_ranked was
-- readable by anyone signed in, and invoices_et by anyone at all. Both were
-- found and fixed, and neither announced itself. A stale token is what turns
-- the next one of those from a latent hole into a live one for the specific
-- person you have just decided should not have access.
--
-- So this is defence in depth, not the mechanism. It removes their sessions
-- and refresh tokens, which means the token they hold can no longer be
-- renewed. It cannot revoke that token itself — nothing can, short of rotating
-- the project's JWT secret, which signs out everybody. Their remaining window
-- is therefore whatever is left of one access token's lifetime, and shortening
-- that is a project setting rather than a function:
--
--   Authentication → Sessions → Access token (JWT) expiry
--
-- Lowering it from an hour to a few minutes shortens every such window on the
-- project, at the cost of more refresh traffic. That single setting does more
-- for "revoke immediately" than this file does.
--
-- No secret key, no HTTP. Deleting the rows is what ending a session IS — the
-- admin API would only do the same thing further away.


create or replace function public.sign_out_app_user(target_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  sessions_ended int := 0;
  tokens_revoked int := 0;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorised to sign other people out'
      using errcode = 'insufficient_privilege';
  end if;

  if target_user_id is null then
    raise exception 'no account given';
  end if;

  delete from auth.sessions where user_id = target_user_id;
  get diagnostics sessions_ended = row_count;

  -- user_id here is text rather than uuid, which is a GoTrue schema quirk and
  -- not a mistake: comparing without the cast fails at runtime, not at create
  -- time, and would fail only when somebody was actually being signed out.
  delete from auth.refresh_tokens where user_id = target_user_id::text;
  get diagnostics tokens_revoked = row_count;

  -- Zero of both is a normal answer, not a failure — it means they were not
  -- signed in anywhere. The caller should not treat it as one.
  return jsonb_build_object(
    'user_id',        target_user_id,
    'sessions_ended', sessions_ended,
    'tokens_revoked', tokens_revoked
  );
end;
$$;

revoke execute on function public.sign_out_app_user(uuid) from public, anon;
grant  execute on function public.sign_out_app_user(uuid) to authenticated;


-- Checking it works ----------------------------------------------------------
--
-- The guard, which should raise:
--
--   select set_config('request.jwt.claims', '', false);
--   select public.sign_out_app_user('00000000-0000-0000-0000-000000000000'::uuid);
--   -- expected: ERROR  not authorised to sign other people out
--
--   select set_config('request.jwt.claims',
--     (select json_build_object('sub', id, 'role', 'authenticated')::text
--      from auth.users where email = 'oboulian@gmail.com'), false);
--   select public.sign_out_app_user(
--     (select id from auth.users where email = 'sheldonrozansky@gmail.com'));
--   -- expected: ERROR  not authorised to sign other people out
--
--   select set_config('request.jwt.claims', '', false);
--
-- And that it can reach the auth schema at all, which is the one thing that
-- could stop this working and is worth knowing before you rely on it. As a
-- platform admin, against an account that is signed in somewhere:
--
--   select set_config('request.jwt.claims',
--     (select json_build_object('sub', id, 'role', 'authenticated')::text
--      from auth.users where email = 'robert@imetrobert.com'), false);
--   select public.sign_out_app_user(
--     (select id from auth.users where email = 'someone@example.com'));
--   select set_config('request.jwt.claims', '', false);
--
-- A permission error on auth.sessions means this function's owner cannot reach
-- the auth schema on your project, and the whole approach needs rethinking —
-- tell somebody rather than working around it. A row of counts means it works.

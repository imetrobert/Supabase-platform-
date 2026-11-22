-- Apps that only ONE named account may ever hold (today: retire-personal, the personal retirement planner).
-- Belt and braces with docs/index.html (PRIVATE_APPS): the page never offers these for anyone else, and the
-- database refuses the grant even if someone edits the page, calls the API directly, or invites with it.
--
-- Run via the Supabase AI assistant (prompt in COMMON-EDITS.md, "Private app"). Then run migration/audit.sql.

create table if not exists public.private_app_owner (
  app     text primary key,
  user_id uuid not null references auth.users(id) on delete cascade
);
alter table public.private_app_owner enable row level security;           -- no policies: nobody reads or writes it via the API
revoke all on public.private_app_owner from anon, authenticated, public;  -- explicit: no Data API access at all

create or replace function public.guard_private_app() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare owner_id uuid;
begin
  select user_id into owner_id from public.private_app_owner where app = new.app;
  if found and new.user_id is distinct from owner_id then
    raise exception 'app % can only be held by its owner', new.app using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists guard_private_app on public.app_access;
create trigger guard_private_app before insert or update of user_id, app on public.app_access
  for each row execute function public.guard_private_app();

-- Owner of retire-personal = the one platform administrator (stops with an error if there is not exactly one).
do $$
declare n int; uid uuid;
begin
  select count(*), min(user_id::text)::uuid into n, uid
  from public.app_access where app = 'platform' and role = 'app_admin';
  if n <> 1 then raise exception 'expected exactly one platform admin, found %', n; end if;
  insert into public.private_app_owner(app, user_id) values ('retire-personal', uid)
  on conflict (app) do update set user_id = excluded.user_id;
end $$;

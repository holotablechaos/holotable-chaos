-- Phase 1: accounts, roles, owner protection, audit log, bans, notification switches.
--
-- Security model
--   * Row-level security is enabled on every table; anything not explicitly allowed is denied.
--   * The browser uses the public (publishable) key, so every table here is protected by RLS,
--     and all privileged changes go through SECURITY DEFINER functions that check the caller.
--   * The `private` schema is not exposed through the API. It holds the owner claim, the
--     profanity list, rate-limit counters and the keep-alive heartbeat.
--   * No personal data or seed accounts live in this file. The owner email is inserted by hand
--     in the Supabase SQL editor (see supabase/README.md) and never committed.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Exactly one row at most: the email address that may claim ownership with a verified identity.
create table private.owner_claim (
  id boolean primary key default true check (id),
  email text not null check (email = lower(btrim(email)) and email like '%@%'),
  created_at timestamptz not null default now()
);

create table public.user_roles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  role text not null check (role in ('owner', 'admin')),
  granted_at timestamptz not null default now(),
  granted_by uuid
);
-- The database itself guarantees there is never more than one owner.
create unique index user_roles_single_owner on public.user_roles (role) where role = 'owner';

create table public.admin_invites (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('discord', 'email')),
  value text not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint admin_invites_value_format check (
    (kind = 'discord' and value ~ '^[0-9]{15,21}$')
    or (kind = 'email' and value = lower(btrim(value)) and value ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
  ),
  unique (kind, value)
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  actor_id uuid,            -- no foreign key: entries outlive deleted accounts
  action text not null,
  target_id uuid,
  details jsonb not null default '{}'::jsonb
);
create index audit_log_created_at on public.audit_log (created_at desc);

create table public.bans (
  user_id uuid primary key references auth.users (id) on delete cascade,
  reason text check (char_length(reason) <= 500),
  banned_by uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz
);

-- Every field is optional. A row is only created when the listener first saves their profile.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text check (display_name is null or char_length(btrim(display_name)) between 1 and 40),
  bio text check (bio is null or char_length(bio) <= 500),
  ally_code text check (ally_code is null or ally_code ~ '^[0-9]{9}$'),            -- self-reported, not verified
  swgoh_gg_url text check (swgoh_gg_url is null or swgoh_gg_url ~ '^https://swgoh\.gg/p/[0-9]{9}/?$'),
  is_public boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- A missing row means every notification is off. Notifications are delivered through Discord
-- in a later phase; nothing is sent by email.
create table public.notification_prefs (
  user_id uuid primary key references auth.users (id) on delete cascade,
  episode_alerts boolean not null default false,
  qotw_alerts boolean not null default false,
  roster_aired_dm boolean not null default false,
  weekly_digest boolean not null default false,
  updated_at timestamptz not null default now()
);

create table private.blocked_words (
  word text primary key check (word = lower(btrim(word)) and char_length(word) between 2 and 40)
);

create table private.rate_limit_hits (
  user_id uuid not null,
  action text not null,
  hit_at timestamptz not null default now()
);
create index rate_limit_hits_lookup on private.rate_limit_hits (user_id, action, hit_at);

create table private.heartbeat (
  id boolean primary key default true check (id),
  last_seen timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Helpers used by policies (public so RLS can call them as the signed-in role)
-- ---------------------------------------------------------------------------

create function public.is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_roles where user_id = auth.uid() and role = 'owner'
  );
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_roles where user_id = auth.uid() and role in ('owner', 'admin')
  );
$$;

create function public.is_banned() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.bans
    where user_id = auth.uid() and (expires_at is null or expires_at > now())
  );
$$;

create function private.audit(p_action text, p_target uuid, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_log (actor_id, action, target_id, details)
  values (auth.uid(), p_action, p_target, coalesce(p_details, '{}'::jsonb));
$$;

create function private.contains_blocked_word(p_text text) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_text is not null and exists (
    select 1 from private.blocked_words w
    where lower(p_text) ~ ('\m' || regexp_replace(w.word, '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g') || '\M')
  );
$$;

create function private.enforce_rate_limit(p_action text, p_max integer, p_window interval)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null then
    return;  -- maintenance from the SQL editor is never rate limited
  end if;
  delete from private.rate_limit_hits
   where user_id = v_uid and action = p_action and hit_at < now() - p_window;
  select count(*) into v_count from private.rate_limit_hits
   where user_id = v_uid and action = p_action;
  if v_count >= p_max then
    raise exception 'Too many changes in a short time. Please wait a little and try again.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  insert into private.rate_limit_hits (user_id, action) values (v_uid, p_action);
end;
$$;

-- ---------------------------------------------------------------------------
-- Owner claim and admin invites (run on every sign-in that creates or refreshes an identity)
-- ---------------------------------------------------------------------------

-- An identity counts as verified only when it comes from Google or Discord, the provider
-- reported email_verified = true, and Supabase marked the account's email as confirmed.
create function private.verified_identity_user(p_email text) returns uuid
language sql stable security definer set search_path = '' as $$
  select i.user_id
    from auth.identities i
    join auth.users u on u.id = i.user_id
   where i.provider in ('google', 'discord')
     and lower(i.identity_data ->> 'email') = lower(p_email)
     and lower(coalesce(i.identity_data ->> 'email_verified', 'false')) = 'true'
     and u.email_confirmed_at is not null
     and u.deleted_at is null
   order by i.created_at
   limit 1;
$$;

create function private.try_claim_owner() returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_email text;
  v_user uuid;
begin
  if exists (select 1 from public.user_roles where role = 'owner') then
    return null;
  end if;
  select email into v_email from private.owner_claim where id;
  if v_email is null then
    return null;
  end if;
  v_user := private.verified_identity_user(v_email);
  if v_user is null then
    return null;
  end if;
  begin
    perform set_config('app.owner_change_allowed', 'on', true);
    insert into public.user_roles (user_id, role, granted_by)
    values (v_user, 'owner', null)
    on conflict (user_id) do update set role = 'owner', granted_at = now(), granted_by = null;
    perform set_config('app.owner_change_allowed', 'off', true);
  exception when unique_violation then
    perform set_config('app.owner_change_allowed', 'off', true);
    return null;  -- another session claimed it first
  end;
  insert into public.audit_log (actor_id, action, target_id, details)
  values (null, 'owner_claimed', v_user, '{}'::jsonb);
  return v_user;
end;
$$;

create function private.accept_invites(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_invite record;
begin
  for v_invite in
    select inv.* from public.admin_invites inv
     where (inv.kind = 'discord' and exists (
              select 1 from auth.identities i
               where i.user_id = p_user and i.provider = 'discord' and i.provider_id = inv.value))
        or (inv.kind = 'email' and private.verified_identity_user(inv.value) = p_user)
  loop
    if not exists (select 1 from public.user_roles where user_id = p_user) then
      insert into public.user_roles (user_id, role, granted_by)
      values (p_user, 'admin', v_invite.created_by);
      insert into public.audit_log (actor_id, action, target_id, details)
      values (null, 'admin_invite_accepted', p_user,
              jsonb_build_object('invite_id', v_invite.id, 'kind', v_invite.kind));
    end if;
    delete from public.admin_invites where id = v_invite.id;
  end loop;
end;
$$;

create function private.on_identity_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- A problem here must never block someone from signing in.
  begin
    perform private.try_claim_owner();
    perform private.accept_invites(new.user_id);
  exception when others then
    raise warning 'Role check after sign-in failed: %', sqlerrm;
  end;
  return null;
end;
$$;

create function private.on_user_confirmed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform private.try_claim_owner();
    perform private.accept_invites(new.id);
  exception when others then
    raise warning 'Role check after confirmation failed: %', sqlerrm;
  end;
  return null;
end;
$$;

create trigger on_identity_change
  after insert or update of identity_data on auth.identities
  for each row execute function private.on_identity_change();

create trigger on_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row when (new.email_confirmed_at is not null and old.email_confirmed_at is null)
  execute function private.on_user_confirmed();

-- The owner row can't be changed or removed, not even by cascading account deletion,
-- except through private.transfer_ownership() run by hand in the SQL editor.
create function private.protect_owner_role() returns trigger
language plpgsql set search_path = '' as $$
begin
  if coalesce(current_setting('app.owner_change_allowed', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' and old.role = 'owner' then
    raise exception 'The owner role cannot be removed. Transfer ownership in the SQL editor first.';
  end if;
  if tg_op = 'UPDATE' and (old.role = 'owner' or new.role = 'owner') and old.role is distinct from new.role then
    raise exception 'The owner role cannot be changed from the site.';
  end if;
  if tg_op = 'UPDATE' and old.role = 'owner' and old.user_id is distinct from new.user_id then
    raise exception 'The owner role cannot be moved from the site.';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger protect_owner_role
  before update or delete on public.user_roles
  for each row execute function private.protect_owner_role();

-- Run by hand in the SQL editor only: select private.transfer_ownership('<new owner uuid>');
create function private.transfer_ownership(p_new_owner uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_old uuid;
begin
  if not exists (select 1 from auth.users where id = p_new_owner) then
    raise exception 'No account with that id.';
  end if;
  select user_id into v_old from public.user_roles where role = 'owner';
  perform set_config('app.owner_change_allowed', 'on', true);
  delete from public.user_roles where user_id in (p_new_owner, v_old);
  insert into public.user_roles (user_id, role) values (p_new_owner, 'owner');
  if v_old is not null then
    insert into public.user_roles (user_id, role) values (v_old, 'admin');
  end if;
  perform set_config('app.owner_change_allowed', 'off', true);
  insert into public.audit_log (actor_id, action, target_id, details)
  values (null, 'owner_transferred', p_new_owner, jsonb_build_object('previous_owner', v_old));
end;
$$;

-- The audit log is append-only.
create function private.audit_log_is_append_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'The audit log cannot be edited or deleted.';
end;
$$;

create trigger audit_log_no_update_delete
  before update or delete on public.audit_log
  for each row execute function private.audit_log_is_append_only();
create trigger audit_log_no_truncate
  before truncate on public.audit_log
  for each statement execute function private.audit_log_is_append_only();

-- ---------------------------------------------------------------------------
-- Profile and preference write rules
-- ---------------------------------------------------------------------------

create function private.before_profile_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.display_name := nullif(btrim(new.display_name), '');
  new.bio := nullif(btrim(new.bio), '');
  new.ally_code := nullif(regexp_replace(coalesce(new.ally_code, ''), '[^0-9]', '', 'g'), '');
  new.swgoh_gg_url := nullif(btrim(new.swgoh_gg_url), '');
  if private.contains_blocked_word(new.display_name) or private.contains_blocked_word(new.bio) then
    raise exception 'Please choose different wording; part of that text is not allowed here.'
      using errcode = 'P0001', hint = 'blocked_word';
  end if;
  if tg_op = 'UPDATE' then
    new.id := old.id;
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  perform private.enforce_rate_limit('profile_write', 30, interval '1 hour');
  return new;
end;
$$;

create trigger before_profile_write
  before insert or update on public.profiles
  for each row execute function private.before_profile_write();

create function private.before_prefs_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
  end if;
  new.updated_at := now();
  perform private.enforce_rate_limit('prefs_write', 60, interval '1 hour');
  return new;
end;
$$;

create trigger before_prefs_write
  before insert or update on public.notification_prefs
  for each row execute function private.before_prefs_write();

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.user_roles enable row level security;
alter table public.admin_invites enable row level security;
alter table public.audit_log enable row level security;
alter table public.bans enable row level security;
alter table public.profiles enable row level security;
alter table public.notification_prefs enable row level security;
alter table private.owner_claim enable row level security;
alter table private.blocked_words enable row level security;
alter table private.rate_limit_hits enable row level security;
alter table private.heartbeat enable row level security;

-- Start from nothing, then grant only what each policy needs.
revoke all on public.user_roles, public.admin_invites, public.audit_log, public.bans,
              public.profiles, public.notification_prefs from anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;

grant select on public.user_roles, public.audit_log, public.bans, public.admin_invites to authenticated;
grant select, insert, update, delete on public.profiles, public.notification_prefs to authenticated;

create policy "See your own role; admins see all"
  on public.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

create policy "Owner sees pending admin invites"
  on public.admin_invites for select to authenticated
  using ((select public.is_owner()));

create policy "Admins read the audit log"
  on public.audit_log for select to authenticated
  using ((select public.is_admin()));

create policy "See your own ban; admins see all"
  on public.bans for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

create policy "Read your own profile; admins read all"
  on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.is_admin()));
create policy "Create your own profile unless banned"
  on public.profiles for insert to authenticated
  with check (id = (select auth.uid()) and not (select public.is_banned()));
create policy "Edit your own profile unless banned"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()) and not (select public.is_banned()));
create policy "Clear your own profile"
  on public.profiles for delete to authenticated
  using (id = (select auth.uid()));

create policy "Read your own notification switches"
  on public.notification_prefs for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Create your own notification switches unless banned"
  on public.notification_prefs for insert to authenticated
  with check (user_id = (select auth.uid()) and not (select public.is_banned()));
create policy "Change your own notification switches unless banned"
  on public.notification_prefs for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and not (select public.is_banned()));
create policy "Reset your own notification switches"
  on public.notification_prefs for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Functions the site calls (RPC)
-- ---------------------------------------------------------------------------

create function private.require_signed_in() returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.' using errcode = '42501';
  end if;
  return auth.uid();
end;
$$;

create function private.require_admin() returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins can do that.' using errcode = '42501';
  end if;
  return auth.uid();
end;
$$;

create function private.require_owner() returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_owner() then
    raise exception 'Only the owner can do that.' using errcode = '42501';
  end if;
  return auth.uid();
end;
$$;

-- Everything stored about the signed-in listener, as one JSON document.
create function public.export_my_data() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_signed_in();
begin
  return jsonb_build_object(
    'exported_at', now(),
    'account', (
      select jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at,
                                'last_sign_in_at', u.last_sign_in_at)
        from auth.users u where u.id = v_uid),
    'sign_in_methods', coalesce((
      select jsonb_agg(jsonb_build_object('provider', i.provider, 'email', i.identity_data ->> 'email',
                                          'linked_at', i.created_at) order by i.created_at)
        from auth.identities i where i.user_id = v_uid), '[]'::jsonb),
    'profile', (select to_jsonb(p) from public.profiles p where p.id = v_uid),
    'notification_switches', (select to_jsonb(n) from public.notification_prefs n where n.user_id = v_uid),
    'role', (select r.role from public.user_roles r where r.user_id = v_uid),
    'ban', (select to_jsonb(b) - 'banned_by' from public.bans b where b.user_id = v_uid),
    'audit_entries_about_you', coalesce((
      select jsonb_agg(jsonb_build_object('at', a.created_at, 'action', a.action) order by a.created_at)
        from public.audit_log a where a.target_id = v_uid or a.actor_id = v_uid), '[]'::jsonb)
  );
end;
$$;

create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_signed_in();
begin
  if exists (select 1 from public.user_roles where user_id = v_uid and role = 'owner') then
    raise exception 'The owner account cannot be deleted from the site. Transfer ownership first.'
      using errcode = 'P0001', hint = 'owner_cannot_delete';
  end if;
  insert into public.audit_log (actor_id, action, target_id) values (null, 'account_deleted', v_uid);
  delete from private.rate_limit_hits where user_id = v_uid;
  delete from auth.users where id = v_uid;  -- cascades to profile, switches, role, ban
end;
$$;

create function public.admin_list_accounts()
returns table (
  id uuid, display_name text, email text, providers text[], created_at timestamptz,
  last_sign_in_at timestamptz, role text, banned boolean
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_owner boolean;
begin
  perform private.require_admin();
  v_owner := public.is_owner();
  return query
    select u.id, p.display_name,
           case when v_owner then u.email::text end,
           coalesce((select array_agg(distinct i.provider order by i.provider)
                       from auth.identities i where i.user_id = u.id), '{}'),
           u.created_at, u.last_sign_in_at, r.role,
           exists (select 1 from public.bans b where b.user_id = u.id
                    and (b.expires_at is null or b.expires_at > now()))
      from auth.users u
      left join public.profiles p on p.id = u.id
      left join public.user_roles r on r.user_id = u.id
     where u.deleted_at is null
     order by u.created_at desc
     limit 1000;
end;
$$;

create function public.admin_grant_admin(p_target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  if not exists (select 1 from auth.users where id = p_target) then
    raise exception 'No account with that id.';
  end if;
  if exists (select 1 from public.user_roles where user_id = p_target) then
    return;  -- already admin or owner
  end if;
  insert into public.user_roles (user_id, role, granted_by) values (p_target, 'admin', auth.uid());
  perform private.audit('admin_granted', p_target);
end;
$$;

create function public.admin_revoke_admin(p_target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  if exists (select 1 from public.user_roles where user_id = p_target and role = 'owner') then
    raise exception 'The owner role cannot be removed.';
  end if;
  delete from public.user_roles where user_id = p_target and role = 'admin';
  if found then
    perform private.audit('admin_revoked', p_target);
  end if;
end;
$$;

create function public.admin_create_invite(p_kind text, p_value text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_value text := case when p_kind = 'email' then lower(btrim(p_value)) else btrim(p_value) end;
  v_user uuid;
begin
  perform private.require_owner();
  insert into public.admin_invites (kind, value, created_by)
  values (p_kind, v_value, auth.uid())
  on conflict (kind, value) do update set created_at = now()
  returning id into v_id;
  perform private.audit('admin_invite_created', null, jsonb_build_object('invite_id', v_id, 'kind', p_kind));
  -- If someone already signed in with that identity, the invite applies straight away.
  for v_user in
    select distinct i.user_id from auth.identities i
     where (p_kind = 'discord' and i.provider = 'discord' and i.provider_id = v_value)
        or (p_kind = 'email' and lower(i.identity_data ->> 'email') = v_value)
  loop
    perform private.accept_invites(v_user);
  end loop;
  return v_id;
end;
$$;

create function public.admin_delete_invite(p_invite uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  delete from public.admin_invites where id = p_invite;
  if found then
    perform private.audit('admin_invite_deleted', null, jsonb_build_object('invite_id', p_invite));
  end if;
end;
$$;

create function public.admin_ban(p_target uuid, p_reason text default null, p_expires_at timestamptz default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_target_role text;
begin
  perform private.require_admin();
  if p_target = auth.uid() then
    raise exception 'You cannot ban yourself.';
  end if;
  if not exists (select 1 from auth.users where id = p_target) then
    raise exception 'No account with that id.';
  end if;
  select role into v_target_role from public.user_roles where user_id = p_target;
  if v_target_role = 'owner' then
    raise exception 'The owner cannot be banned.';
  end if;
  if v_target_role = 'admin' and not public.is_owner() then
    raise exception 'Only the owner can ban an admin.';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'The ban end date must be in the future.';
  end if;
  insert into public.bans (user_id, reason, banned_by, expires_at)
  values (p_target, nullif(btrim(p_reason), ''), auth.uid(), p_expires_at)
  on conflict (user_id) do update
    set reason = excluded.reason, banned_by = excluded.banned_by,
        expires_at = excluded.expires_at, created_at = now();
  perform private.audit('user_banned', p_target,
    jsonb_build_object('reason', nullif(btrim(p_reason), ''), 'expires_at', p_expires_at));
end;
$$;

create function public.admin_unban(p_target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  delete from public.bans where user_id = p_target;
  if found then
    perform private.audit('user_unbanned', p_target);
  end if;
end;
$$;

create function public.admin_list_blocked_words() returns setof text
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return query select word from private.blocked_words order by word;
end;
$$;

create function public.admin_add_blocked_word(p_word text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  insert into private.blocked_words (word) values (lower(btrim(p_word))) on conflict do nothing;
  if found then
    perform private.audit('blocked_word_added', null);
  end if;
end;
$$;

create function public.admin_remove_blocked_word(p_word text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  delete from private.blocked_words where word = lower(btrim(p_word));
  if found then
    perform private.audit('blocked_word_removed', null);
  end if;
end;
$$;

-- Called every few days by a GitHub Action with the public key so the free project isn't paused.
create function public.keep_alive() returns timestamptz
language sql security definer set search_path = '' as $$
  insert into private.heartbeat (id, last_seen) values (true, now())
  on conflict (id) do update set last_seen = now()
  returning last_seen;
$$;

-- ---------------------------------------------------------------------------
-- Function permissions: nothing is callable unless granted below.
-- ---------------------------------------------------------------------------

revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function
  public.is_owner(), public.is_admin(), public.is_banned(),
  public.export_my_data(), public.delete_my_account(), public.admin_list_accounts(),
  public.admin_grant_admin(uuid), public.admin_revoke_admin(uuid),
  public.admin_create_invite(text, text), public.admin_delete_invite(uuid),
  public.admin_ban(uuid, text, timestamptz), public.admin_unban(uuid),
  public.admin_list_blocked_words(), public.admin_add_blocked_word(text), public.admin_remove_blocked_word(text),
  public.keep_alive()
from public, anon, authenticated;

grant execute on function
  public.is_owner(), public.is_admin(), public.is_banned(),
  public.export_my_data(), public.delete_my_account(), public.admin_list_accounts(),
  public.admin_grant_admin(uuid), public.admin_revoke_admin(uuid),
  public.admin_create_invite(text, text), public.admin_delete_invite(uuid),
  public.admin_ban(uuid, text, timestamptz), public.admin_unban(uuid),
  public.admin_list_blocked_words(), public.admin_add_blocked_word(text), public.admin_remove_blocked_word(text)
to authenticated;
grant execute on function public.keep_alive() to anon, authenticated;

-- New functions in public are not callable by default.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

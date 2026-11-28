-- Phase 2, task 2: richer profiles and a shared "member card" (display name + avatar).
--
-- Avatars are never uploaded or stored: they are the picture URL that Discord or Google already
-- gave Supabase at sign-in, or nothing (the site then draws initials). Display names fall back to
-- the provider's name and finally to "Listener"; nothing is written at sign-in.

alter table public.profiles
  add column in_game_name text check (in_game_name is null or char_length(btrim(in_game_name)) between 1 and 40),
  add column avatar_source text check (avatar_source in ('discord', 'google', 'initials'));

-- Only well-known avatar hosts are ever returned, so a crafted identity can't point at another site.
create function private.safe_avatar_url(p_url text) returns text
language sql immutable set search_path = '' as $$
  select case
    when p_url ~ '^https://cdn\.discordapp\.com/(avatars|embed/avatars)/[A-Za-z0-9_./-]+$' then p_url
    when p_url ~ '^https://lh[0-9]\.googleusercontent\.com/[A-Za-z0-9_./=-]+$' then p_url
  end;
$$;

create function private.provider_avatar(p_user uuid, p_provider text) returns text
language sql stable security definer set search_path = '' as $$
  select private.safe_avatar_url(coalesce(i.identity_data ->> 'avatar_url', i.identity_data ->> 'picture'))
    from auth.identities i
   where i.user_id = p_user and i.provider = p_provider
   order by i.created_at limit 1;
$$;

create function private.avatar_url_for(p_user uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case p.avatar_source
           when 'initials' then null
           when 'discord' then private.provider_avatar(p_user, 'discord')
           when 'google' then private.provider_avatar(p_user, 'google')
           else coalesce(private.provider_avatar(p_user, 'discord'), private.provider_avatar(p_user, 'google'))
         end
    from (select (select avatar_source from public.profiles where id = p_user) as avatar_source) p;
$$;

-- The provider's own name for someone (Discord display name, then username; Google full name).
create function private.provider_name(p_user uuid) returns text
language sql stable security definer set search_path = '' as $$
  select nullif(btrim(coalesce(i.identity_data -> 'custom_claims' ->> 'global_name',
                               i.identity_data ->> 'full_name', i.identity_data ->> 'name')), '')
    from auth.identities i
   where i.user_id = p_user and i.provider in ('discord', 'google')
   order by case i.provider when 'discord' then 0 else 1 end, i.created_at
   limit 1;
$$;

-- Hook for the name rules (blocked words, reserved names). Replaced by the moderation migration.
create function private.name_allowed(p_user uuid, p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_name is not null and char_length(p_name) <= 40 and not private.contains_blocked_word(p_name);
$$;

create function private.display_name_for(p_user uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles where id = p_user;
  if v_name is not null then
    return v_name;
  end if;
  v_name := left(private.provider_name(p_user), 40);
  if private.name_allowed(p_user, v_name) then
    return v_name;
  end if;
  return 'Listener';
end;
$$;

create function private.member_card(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p_user,
    'name', private.display_name_for(p_user),
    'avatar_url', private.avatar_url_for(p_user),
    'role', (select role from public.user_roles where user_id = p_user)
  );
$$;

-- The signed-in listener's own card, used by the header and account page.
create function public.my_member_card() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return private.member_card(private.require_signed_in())
         || jsonb_build_object('member_since', (select created_at from auth.users where id = auth.uid()),
                               'provider_name', private.provider_name(auth.uid()));
end;
$$;

-- Profile text fields are cleaned and checked here (the name rules apply to names; bios and
-- in-game names get the blocked-word check). Ally codes and links are validated by format only.
create or replace function private.before_profile_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.display_name := nullif(btrim(new.display_name), '');
  new.bio := nullif(btrim(new.bio), '');
  new.in_game_name := nullif(btrim(new.in_game_name), '');
  new.ally_code := nullif(regexp_replace(coalesce(new.ally_code, ''), '[^0-9]', '', 'g'), '');
  new.swgoh_gg_url := nullif(btrim(new.swgoh_gg_url), '');
  if (new.display_name is not null and not private.name_allowed(new.id, new.display_name))
     or private.contains_blocked_word(new.bio)
     or private.contains_blocked_word(new.in_game_name) then
    raise exception 'That text isn''t allowed. Please reword it.'
      using errcode = 'P0001', hint = 'blocked_text';
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

-- Admin account list gains the resolved name and avatar.
drop function public.admin_list_accounts();
create function public.admin_list_accounts()
returns table (
  id uuid, display_name text, avatar_url text, email text, providers text[], created_at timestamptz,
  last_sign_in_at timestamptz, role text, banned boolean, has_profile boolean
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_owner boolean;
begin
  perform private.require_admin();
  v_owner := public.is_owner();
  return query
    select u.id, private.display_name_for(u.id), private.avatar_url_for(u.id),
           case when v_owner then u.email::text end,
           coalesce((select array_agg(distinct i.provider order by i.provider)
                       from auth.identities i where i.user_id = u.id), '{}'),
           u.created_at, u.last_sign_in_at, r.role,
           exists (select 1 from public.bans b where b.user_id = u.id
                    and (b.expires_at is null or b.expires_at > now())),
           exists (select 1 from public.profiles p where p.id = u.id)
      from auth.users u
      left join public.user_roles r on r.user_id = u.id
     where u.deleted_at is null
     order by u.created_at desc
     limit 1000;
end;
$$;

-- Display names for audit-log actors and targets (admins only), so the log reads as people.
create function public.admin_member_cards(p_ids uuid[]) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return query select private.member_card(x) from unnest(p_ids) x where x is not null;
end;
$$;

revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.my_member_card(), public.admin_list_accounts(), public.admin_member_cards(uuid[])
  from public, anon, authenticated;
grant execute on function public.my_member_card(), public.admin_list_accounts(), public.admin_member_cards(uuid[])
  to authenticated;

-- Phase 2, task 3 (+ unique display names): text normalisation, blocked terms with match types and
-- categories, an allowlist, reserved names with per-account exceptions, and unique display names.
--
-- No word lists live in this repository. The tables start empty; the production lists are loaded
-- from files kept outside the repo, and admins can edit them on the moderation tab.

create extension if not exists unaccent with schema extensions;

-- ---------------------------------------------------------------------------
-- Normalisation (shared by the filter, reserved names and unique names)
-- ---------------------------------------------------------------------------

create function private.unaccent_immutable(p text) returns text
language sql immutable parallel safe strict set search_path = '' as $$
  select extensions.unaccent('extensions.unaccent'::regdictionary, p);
$$;

-- "Words" form: NFKC, lower case, accents and zero-width characters removed, common character
-- swaps mapped (@ 4 -> a, $ 5 -> s, 3 -> e, 1 ! | -> i, 0 -> o, 7 -> t), everything else that
-- isn't a letter or digit becomes a space, and runs of 3+ single characters are joined
-- ("g.r.o.b" / "g r o b" -> "grob"). Repeated letters are kept here; see private.squeeze().
create function private.norm_words(p text) returns text
language plpgsql immutable parallel safe set search_path = '' as $$
declare
  t text;
  tokens text[];
  result text[] := '{}';
  run text := '';
  run_length integer := 0;
  token text;
begin
  if p is null then
    return null;
  end if;
  t := lower(normalize(p, NFKC));
  t := regexp_replace(t, '[­​-‏⁠-⁤﻿]', '', 'g');
  t := private.unaccent_immutable(t);
  t := translate(t, '@4$5310!|7', 'aasseioiit');
  t := regexp_replace(t, '[^a-z0-9]+', ' ', 'g');
  tokens := regexp_split_to_array(btrim(t), ' ');
  foreach token in array tokens loop
    continue when token = '';
    if char_length(token) = 1 then
      run := run || token;
      run_length := run_length + 1;
    else
      if run_length >= 3 then result := result || run;
      elsif run_length > 0 then result := result || regexp_split_to_array(run, '');
      end if;
      run := ''; run_length := 0;
      result := result || token;
    end if;
  end loop;
  if run_length >= 3 then result := result || run;
  elsif run_length > 0 then result := result || regexp_split_to_array(run, '');
  end if;
  return array_to_string(result, ' ');
end;
$$;

create function private.squeeze(p text) returns text
language sql immutable parallel safe strict set search_path = '' as $$
  select regexp_replace(p, '([a-z0-9])\1+', '\1', 'g');
$$;

-- Key used for unique and reserved names: words form, no spaces, repeated letters collapsed.
create function private.name_key(p text) returns text
language sql immutable parallel safe set search_path = '' as $$
  select nullif(private.squeeze(replace(private.norm_words(p), ' ', '')), '');
$$;

-- ---------------------------------------------------------------------------
-- Lists (private; managed through the admin functions or the out-of-repo loader)
-- ---------------------------------------------------------------------------

create table private.blocked_terms (
  id bigint generated always as identity primary key,
  term text not null check (char_length(btrim(term)) between 2 and 80),
  match_type text not null default 'word' check (match_type in ('word', 'substring', 'phrase')),
  category text not null default 'other'
    check (category in ('profanity', 'slur', 'sexual', 'sexual_violence', 'harassment', 'self_harm', 'hate_symbol', 'other')),
  source text not null default 'admin' check (source in ('admin', 'list')),
  term_words text generated always as (private.norm_words(term)) stored,
  term_compact text generated always as (replace(private.norm_words(term), ' ', '')) stored,
  created_at timestamptz not null default now(),
  unique (term_words, match_type)
);

create table private.allowed_terms (
  id bigint generated always as identity primary key,
  term text not null check (char_length(btrim(term)) between 2 and 80),
  source text not null default 'admin' check (source in ('admin', 'list')),
  term_words text generated always as (private.norm_words(term)) stored unique,
  created_at timestamptz not null default now()
);

create table private.reserved_names (
  id bigint generated always as identity primary key,
  name text not null check (char_length(btrim(name)) between 2 and 60),
  match_type text not null default 'word' check (match_type in ('word', 'contains')),
  source text not null default 'admin' check (source in ('admin', 'list')),
  name_words text generated always as (private.norm_words(name)) stored,
  name_key text generated always as (private.name_key(name)) stored unique,
  created_at timestamptz not null default now()
);

create table private.name_exceptions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  note text check (char_length(note) <= 200),
  granted_by uuid,
  created_at timestamptz not null default now()
);

alter table private.blocked_terms enable row level security;
alter table private.allowed_terms enable row level security;
alter table private.reserved_names enable row level security;
alter table private.name_exceptions enable row level security;
revoke all on private.blocked_terms, private.allowed_terms, private.reserved_names, private.name_exceptions
  from public, anon, authenticated;

-- Carry over anything added through the Phase 1 dashboard, then retire the old table.
insert into private.blocked_terms (term, match_type, category, source)
select word, 'word', 'other', 'admin' from private.blocked_words
on conflict do nothing;
drop function public.admin_list_blocked_words();
drop function public.admin_add_blocked_word(text);
drop function public.admin_remove_blocked_word(text);

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

-- Every blocked term that matches p. Allowlisted words are removed first. Word and phrase terms
-- match whole words; substring terms match anywhere in the joined text. Repeated letters are
-- collapsed on both sides only when the collapsed term is 4+ characters, so short terms never
-- turn into ordinary words.
create function private.blocked_matches(p text)
returns table (id bigint, term text, match_type text, category text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_words text;
  v_squeezed text;
  v_compact text;
  v_compact_squeezed text;
  v_allowed text;
begin
  if p is null or btrim(p) = '' then
    return;
  end if;
  v_words := ' ' || private.norm_words(p) || ' ';
  for v_allowed in select a.term_words from private.allowed_terms a where a.term_words <> '' loop
    while position(' ' || v_allowed || ' ' in v_words) > 0 loop
      v_words := replace(v_words, ' ' || v_allowed || ' ', ' ');
    end loop;
  end loop;
  v_squeezed := private.squeeze(v_words);
  v_compact := replace(v_words, ' ', '');
  v_compact_squeezed := private.squeeze(v_compact);
  return query
    select b.id, b.term, b.match_type, b.category
      from private.blocked_terms b
     where b.term_words <> ''
       and case
             when b.match_type in ('word', 'phrase') then
               position(' ' || b.term_words || ' ' in v_words) > 0
               or (char_length(private.squeeze(b.term_compact)) >= 4
                   and position(' ' || private.squeeze(b.term_words) || ' ' in v_squeezed) > 0)
             else
               position(b.term_compact in v_compact) > 0
               or (char_length(private.squeeze(b.term_compact)) >= 4
                   and position(private.squeeze(b.term_compact) in v_compact_squeezed) > 0)
           end;
end;
$$;

-- Same name as Phase 1 so every existing check picks up the new matching.
create or replace function private.contains_blocked_word(p_text text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.blocked_matches(p_text));
$$;

create function private.reserved_match(p text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_words text := ' ' || coalesce(private.norm_words(p), '') || ' ';
  v_key text := private.name_key(p);
begin
  if v_key is null then
    return false;
  end if;
  -- Built-in: nobody else may look like the "Listener · 1234" fallback names.
  if v_key ~ '^listener' or position(' listener ' in v_words) > 0 then
    return true;
  end if;
  return exists (
    select 1 from private.reserved_names r
     where r.name_key = v_key
        or position(' ' || r.name_words || ' ' in v_words) > 0
        or position(' ' || private.squeeze(r.name_words) || ' ' in private.squeeze(v_words)) > 0
        or (r.match_type = 'contains' and position(r.name_key in v_key) > 0)
  );
end;
$$;

create function private.may_use_reserved(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles where user_id = p_user)
      or exists (select 1 from private.name_exceptions where user_id = p_user);
$$;

-- Display and in-game names: length, no blocked words, reserved names only for those allowed,
-- and no "·" (used by fallback names).
create or replace function private.name_allowed(p_user uuid, p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_name is not null
     and char_length(p_name) <= 40
     and private.name_key(p_name) is not null
     and position('·' in p_name) = 0
     and not private.contains_blocked_word(p_name)
     and (not private.reserved_match(p_name) or private.may_use_reserved(p_user));
$$;

-- ---------------------------------------------------------------------------
-- Unique display names
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column display_name_key text,
  add column display_name_changed_at timestamptz;
update public.profiles set display_name_key = private.name_key(display_name), display_name_changed_at = updated_at
 where display_name is not null;
create unique index profiles_display_name_key_unique on public.profiles (display_name_key)
  where display_name_key is not null;

create or replace function private.before_profile_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_reclaim boolean := coalesce(current_setting('app.name_reclaim', true), '') = 'on';
  v_name_changed boolean;
  v_next timestamptz;
begin
  new.display_name := nullif(btrim(new.display_name), '');
  new.bio := nullif(btrim(new.bio), '');
  new.in_game_name := nullif(btrim(new.in_game_name), '');
  new.ally_code := nullif(regexp_replace(coalesce(new.ally_code, ''), '[^0-9]', '', 'g'), '');
  new.swgoh_gg_url := nullif(btrim(new.swgoh_gg_url), '');
  if tg_op = 'UPDATE' then
    new.id := old.id;
    new.created_at := old.created_at;
  end if;
  -- Listeners can't set the change date themselves; maintenance in the SQL editor can.
  if auth.uid() is not null then
    new.display_name_changed_at := case when tg_op = 'UPDATE' then old.display_name_changed_at end;
  end if;
  v_name_changed := new.display_name is distinct from (case when tg_op = 'UPDATE' then old.display_name end);

  -- Text checks: one generic message, never saying which list matched.
  if (new.display_name is not null and v_name_changed and not private.name_allowed(new.id, new.display_name))
     or (new.in_game_name is not null and not private.name_allowed(new.id, new.in_game_name))
     or private.contains_blocked_word(new.bio) then
    raise exception 'That text isn''t allowed. Please reword it.'
      using errcode = 'P0001', hint = 'blocked_text';
  end if;

  if v_name_changed and not v_reclaim then
    -- One change every 30 days (setting a first name is always allowed).
    if tg_op = 'UPDATE' and old.display_name is not null and auth.uid() = new.id
       and old.display_name_changed_at > now() - interval '30 days' then
      v_next := old.display_name_changed_at + interval '30 days';
      raise exception 'You can change your display name once every 30 days. You can change it again on %.',
        to_char(v_next at time zone 'UTC', 'FMMonth FMDD, YYYY')
        using errcode = 'P0001', hint = 'name_change_limit';
    end if;
    new.display_name_changed_at := now();
  elsif v_reclaim then
    new.display_name_changed_at := null;
  end if;

  new.display_name_key := private.name_key(new.display_name);
  if new.display_name_key is not null and v_name_changed and exists (
       select 1 from public.profiles p where p.display_name_key = new.display_name_key and p.id <> new.id) then
    raise exception 'That name is already taken. Please choose another.'
      using errcode = 'P0001', hint = 'name_taken';
  end if;

  new.updated_at := now();
  perform private.enforce_rate_limit('profile_write', 30, interval '1 hour');
  return new;
end;
$$;

-- Fallback names get a short number from the account id so two people never look identical.
create function private.fallback_suffix(p_user uuid) returns text
language sql immutable parallel safe set search_path = '' as $$
  select lpad((('x' || substr(md5(p_user::text), 1, 8))::bit(32)::bigint % 10000)::text, 4, '0');
$$;

create or replace function private.display_name_for(p_user uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles where id = p_user;
  if v_name is not null then
    return v_name;
  end if;
  v_name := left(private.provider_name(p_user), 32);
  if not private.name_allowed(p_user, v_name) then
    v_name := 'Listener';
  end if;
  return v_name || ' · ' || private.fallback_suffix(p_user);
end;
$$;

-- When a listener may next change their display name (null = any time).
create function public.my_name_change_available_at() returns timestamptz
language sql stable security definer set search_path = '' as $$
  select case when p.display_name is not null and p.display_name_changed_at > now() - interval '30 days'
              then p.display_name_changed_at + interval '30 days' end
    from public.profiles p where p.id = auth.uid();
$$;

-- Inline check for the account page: 'ok', 'taken' or 'not_allowed'. Never says who holds a
-- name or which rule matched. Rate limited so it can't be used to probe the lists.
create function public.check_display_name(p_name text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_signed_in();
  v_name text := nullif(btrim(p_name), '');
begin
  perform private.enforce_rate_limit('name_check', 60, interval '1 hour');
  if v_name is null then
    return 'ok';
  end if;
  if not private.name_allowed(v_uid, v_name) then
    return 'not_allowed';
  end if;
  if exists (select 1 from public.profiles where display_name_key = private.name_key(v_name) and id <> v_uid) then
    return 'taken';
  end if;
  return 'ok';
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin tools
-- ---------------------------------------------------------------------------

create function public.admin_list_terms(p_list text)
returns table (id bigint, term text, match_type text, category text, source text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  if p_list = 'blocked' then
    return query select b.id, b.term, b.match_type, b.category, b.source, b.created_at from private.blocked_terms b order by b.category, b.term;
  elsif p_list = 'allowed' then
    return query select a.id, a.term, null::text, null::text, a.source, a.created_at from private.allowed_terms a order by a.term;
  elsif p_list = 'reserved' then
    return query select r.id, r.name, r.match_type, null::text, r.source, r.created_at from private.reserved_names r order by r.name;
  else
    raise exception 'Unknown list.';
  end if;
end;
$$;

create function public.admin_moderation_counts() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return jsonb_build_object(
    'blocked_by_category', coalesce((select jsonb_object_agg(category, n) from (select category, count(*) n from private.blocked_terms group by category) c), '{}'::jsonb),
    'blocked_by_match_type', coalesce((select jsonb_object_agg(match_type, n) from (select match_type, count(*) n from private.blocked_terms group by match_type) c), '{}'::jsonb),
    'allowed', (select count(*) from private.allowed_terms),
    'reserved', (select count(*) from private.reserved_names),
    'name_exceptions', (select count(*) from private.name_exceptions));
end;
$$;

-- Bulk add. Terms already present are left as they are. Returns how many were added.
create function public.admin_add_terms(p_list text, p_terms text[], p_match_type text default null, p_category text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_added integer;
begin
  perform private.require_admin();
  if p_list = 'blocked' then
    insert into private.blocked_terms (term, match_type, category)
    select btrim(t), coalesce(p_match_type, 'word'), coalesce(p_category, 'other')
      from unnest(p_terms) t where btrim(t) <> ''
    on conflict do nothing;
  elsif p_list = 'allowed' then
    insert into private.allowed_terms (term) select btrim(t) from unnest(p_terms) t where btrim(t) <> '' on conflict do nothing;
  elsif p_list = 'reserved' then
    insert into private.reserved_names (name, match_type)
    select btrim(t), coalesce(p_match_type, 'word') from unnest(p_terms) t where btrim(t) <> '' on conflict do nothing;
  else
    raise exception 'Unknown list.';
  end if;
  get diagnostics v_added = row_count;
  perform private.audit('moderation_terms_added', null,
    jsonb_build_object('list', p_list, 'count', v_added, 'match_type', p_match_type, 'category', p_category));
  return v_added;
end;
$$;

create function public.admin_remove_terms(p_list text, p_ids bigint[]) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_removed integer;
begin
  perform private.require_admin();
  if p_list = 'blocked' then delete from private.blocked_terms where id = any (p_ids);
  elsif p_list = 'allowed' then delete from private.allowed_terms where id = any (p_ids);
  elsif p_list = 'reserved' then delete from private.reserved_names where id = any (p_ids);
  else raise exception 'Unknown list.';
  end if;
  get diagnostics v_removed = row_count;
  perform private.audit('moderation_terms_removed', null, jsonb_build_object('list', p_list, 'count', v_removed));
  return v_removed;
end;
$$;

create function public.admin_update_terms(p_list text, p_ids bigint[], p_match_type text default null, p_category text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_changed integer;
begin
  perform private.require_admin();
  if p_list = 'blocked' then
    update private.blocked_terms set match_type = coalesce(p_match_type, match_type), category = coalesce(p_category, category)
     where id = any (p_ids);
  elsif p_list = 'reserved' then
    update private.reserved_names set match_type = coalesce(p_match_type, match_type) where id = any (p_ids);
  else
    raise exception 'That list has no match types or categories.';
  end if;
  get diagnostics v_changed = row_count;
  perform private.audit('moderation_terms_changed', null,
    jsonb_build_object('list', p_list, 'count', v_changed, 'match_type', p_match_type, 'category', p_category));
  return v_changed;
end;
$$;

-- Test any text: would it be blocked, and why. Admins only (it shows the matching entries).
create function public.admin_test_text(p_text text, p_as_name boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_matches jsonb;
  v_reserved boolean;
begin
  perform private.require_admin();
  select coalesce(jsonb_agg(jsonb_build_object('term', m.term, 'match_type', m.match_type, 'category', m.category)), '[]'::jsonb)
    into v_matches from private.blocked_matches(p_text) m;
  v_reserved := p_as_name and private.reserved_match(p_text);
  return jsonb_build_object(
    'blocked', jsonb_array_length(v_matches) > 0 or v_reserved,
    'blocked_terms', v_matches,
    'reserved_name', v_reserved,
    'normalized', private.norm_words(p_text),
    'name_key', private.name_key(p_text),
    'name_taken', p_as_name and exists (select 1 from public.profiles where display_name_key = private.name_key(p_text)));
end;
$$;

-- Owner: who holds a display name (by its normalised key), and reclaiming it.
create function public.admin_lookup_name(p_name text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid;
begin
  perform private.require_owner();
  select id into v_user from public.profiles where display_name_key = private.name_key(p_name);
  if v_user is null then
    return null;
  end if;
  return private.member_card(v_user) || jsonb_build_object(
    'display_name_changed_at', (select display_name_changed_at from public.profiles where id = v_user));
end;
$$;

create function public.admin_reclaim_name(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_old text;
begin
  perform private.require_owner();
  select display_name into v_old from public.profiles where id = p_user;
  if v_old is null then
    raise exception 'That account has no display name to reclaim.';
  end if;
  perform set_config('app.name_reclaim', 'on', true);
  update public.profiles set display_name = null where id = p_user;
  perform set_config('app.name_reclaim', 'off', true);
  perform private.audit('display_name_reclaimed', p_user, jsonb_build_object('name', v_old));
end;
$$;

-- Owner: accounts allowed to use reserved names (e.g. a co-host who isn't an admin).
create function public.admin_list_name_exceptions() returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_owner();
  return query select private.member_card(e.user_id) || jsonb_build_object('note', e.note, 'created_at', e.created_at)
                 from private.name_exceptions e order by e.created_at;
end;
$$;

create function public.admin_add_name_exception(p_user uuid, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  if not exists (select 1 from auth.users where id = p_user) then
    raise exception 'No account with that id.';
  end if;
  insert into private.name_exceptions (user_id, note, granted_by) values (p_user, nullif(btrim(p_note), ''), auth.uid())
  on conflict (user_id) do update set note = excluded.note, granted_by = excluded.granted_by, created_at = now();
  perform private.audit('name_exception_added', p_user);
end;
$$;

create function public.admin_remove_name_exception(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  delete from private.name_exceptions where user_id = p_user;
  if found then
    perform private.audit('name_exception_removed', p_user);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Out-of-repo list loader support: replace every 'list' row of one list in one transaction.
-- Called only from the SQL editor / linked CLI (not exposed to the site).
-- ---------------------------------------------------------------------------
create function private.load_list(p_list text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_before integer;
  v_after integer;
begin
  if p_list = 'blocked' then
    delete from private.blocked_terms where source = 'list';
    insert into private.blocked_terms (term, match_type, category, source)
    select r ->> 'term', coalesce(r ->> 'match_type', 'word'), coalesce(r ->> 'category', 'other'), 'list'
      from jsonb_array_elements(p_rows) r
    on conflict (term_words, match_type) do update set category = excluded.category, source = 'list';
    select count(*) into v_after from private.blocked_terms where source = 'list';
  elsif p_list = 'allowed' then
    delete from private.allowed_terms where source = 'list';
    insert into private.allowed_terms (term, source) select r ->> 'term', 'list' from jsonb_array_elements(p_rows) r
    on conflict (term_words) do update set source = 'list';
    select count(*) into v_after from private.allowed_terms where source = 'list';
  elsif p_list = 'reserved' then
    delete from private.reserved_names where source = 'list';
    insert into private.reserved_names (name, match_type, source)
    select r ->> 'term', coalesce(r ->> 'match_type', 'word'), 'list' from jsonb_array_elements(p_rows) r
    on conflict (name_key) do update set match_type = excluded.match_type, source = 'list';
    select count(*) into v_after from private.reserved_names where source = 'list';
  else
    raise exception 'Unknown list.';
  end if;
  insert into public.audit_log (actor_id, action, details)
  values (null, 'moderation_list_loaded', jsonb_build_object('list', p_list, 'count', v_after));
  return jsonb_build_object('list', p_list, 'loaded', v_after);
end;
$$;

-- Read-only false-positive check for a batch of texts (used by the loader after each load).
create function private.blocked_texts(p_texts text[]) returns table (text_value text)
language sql stable security definer set search_path = '' as $$
  select t from unnest(p_texts) t where private.contains_blocked_word(t);
$$;

drop table private.blocked_words;

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function
  public.check_display_name(text), public.my_name_change_available_at(), public.admin_list_terms(text), public.admin_moderation_counts(),
  public.admin_add_terms(text, text[], text, text), public.admin_remove_terms(text, bigint[]),
  public.admin_update_terms(text, bigint[], text, text), public.admin_test_text(text, boolean),
  public.admin_lookup_name(text), public.admin_reclaim_name(uuid), public.admin_list_name_exceptions(),
  public.admin_add_name_exception(uuid, text), public.admin_remove_name_exception(uuid)
from public, anon, authenticated;
grant execute on function
  public.check_display_name(text), public.my_name_change_available_at(), public.admin_list_terms(text), public.admin_moderation_counts(),
  public.admin_add_terms(text, text[], text, text), public.admin_remove_terms(text, bigint[]),
  public.admin_update_terms(text, bigint[], text, text), public.admin_test_text(text, boolean),
  public.admin_lookup_name(text), public.admin_reclaim_name(uuid), public.admin_list_name_exceptions(),
  public.admin_add_name_exception(uuid, text), public.admin_remove_name_exception(uuid)
to authenticated;

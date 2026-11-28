-- Security review fixes (no data changes):
--  1. A banned admin loses admin powers (is_admin() is false while banned), and only the owner can
--     lift an admin's ban.
--  2. Listeners can no longer delete their profile row directly. Clearing fields still works (the
--     site saves with an upsert), but deleting and recreating the row reset the 30-day name limit.
--  3. Names may only use Latin letters (accents are fine), so look-alike letters from other
--     alphabets can't be mixed into a name to imitate someone. Names made only of other alphabets
--     were already refused.
--  4. Overlong text is refused before the word filter runs, so huge requests can't tie up the
--     database. Legitimate fields are all 1000 characters or fewer.
--  5. created_at is set by the database on insert, not by the browser.
--  6. "Download my data" says whether the account has a reserved-name exception.

-- 1. Banned admins ---------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role in ('owner', 'admin'))
     and not public.is_banned();
$$;

create or replace function public.admin_unban(p_target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.require_admin();
  if exists (select 1 from public.user_roles where user_id = p_target and role = 'admin') and not public.is_owner() then
    raise exception 'Only the owner can lift an admin''s ban.' using errcode = 'P0001';
  end if;
  delete from public.bans where user_id = p_target;
  if found then
    perform private.audit('user_unbanned', p_target);
  end if;
end;
$$;

-- 2. No direct profile deletes ------------------------------------------------------------------
drop policy if exists "Clear your own profile" on public.profiles;
revoke delete on public.profiles from authenticated;

-- 3 + 4. Name rules and length guards --------------------------------------------------------------
create or replace function private.has_non_latin_letters(p text)
returns boolean
language sql immutable parallel safe set search_path = ''
as $$
  -- After folding width/compatibility forms and accents, any letter other than a-z is from
  -- another alphabet (Cyrillic, Greek, IPA ...). Emoji and punctuation are not letters.
  select regexp_replace(
           private.unaccent_immutable(regexp_replace(lower(normalize(coalesce(p, ''), NFKC)), '[­​-‏⁠-⁤﻿]', '', 'g')),
           '[a-z]', '', 'g') ~ '[[:alpha:]]';
$$;

create or replace function private.name_allowed(p_user uuid, p_name text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
begin
  -- Cheap checks first, in a fixed order, so long input never reaches the filters.
  if p_name is null or char_length(p_name) > 40 or position('·' in p_name) > 0 then
    return false;
  end if;
  if private.name_key(p_name) is null or private.has_non_latin_letters(p_name) then
    return false;
  end if;
  if private.contains_blocked_word(p_name) then
    return false;
  end if;
  return not private.reserved_match(p_name) or private.may_use_reserved(p_user);
end;
$$;

create or replace function private.blocked_matches(p text)
returns table(id bigint, term text, match_type text, category text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_words text;
  v_squeezed text;
  v_compact text;
  v_compact_squeezed text;
  v_allowed text;
  v_patterns text[];
begin
  if p is null or btrim(p) = '' then
    return;
  end if;
  -- No field accepts more than 1000 characters; refuse overlong text before any filtering work.
  if char_length(p) > 1000 then
    raise exception 'That text is too long.' using errcode = '22001', hint = 'too_long';
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
  select coalesce(array_agg(pat), '{}') into v_patterns
    from private.masked_patterns(p) pat
   where not exists (select 1 from private.allowed_terms a where replace(a.term_words, ' ', '') ~ pat);
  return query
    select b.id, b.term, b.match_type, b.category
      from private.blocked_terms b
     where b.term_words <> ''
       and (case
              when b.match_type in ('word', 'phrase') then
                position(' ' || b.term_words || ' ' in v_words) > 0
                or (char_length(private.squeeze(b.term_compact)) >= 4
                    and position(' ' || private.squeeze(b.term_words) || ' ' in v_squeezed) > 0)
              else
                position(b.term_compact in v_compact) > 0
                or (char_length(private.squeeze(b.term_compact)) >= 4
                    and position(private.squeeze(b.term_compact) in v_compact_squeezed) > 0)
            end
            or (b.match_type in ('word', 'substring')
                and exists (select 1 from unnest(v_patterns) pat where b.term_compact ~ pat)));
end;
$$;

create or replace function public.check_display_name(p_name text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := private.require_signed_in();
  v_name text := nullif(btrim(left(p_name, 200)), '');
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

-- 5. Server-side created_at -----------------------------------------------------------------------
create or replace function private.before_answer_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- Account deletion anonymises answers (foreign key ON DELETE SET NULL): let exactly that through.
  if tg_op = 'UPDATE' and old.user_id is not null and new.user_id is null
     and new.body is not distinct from old.body and new.episode = old.episode then
    return new;
  end if;
  new.body := btrim(new.body);
  if tg_op = 'UPDATE' then
    new.id := old.id;
    new.episode := old.episode;
    new.user_id := old.user_id;
    new.created_at := old.created_at;
    if coalesce(current_setting('app.feature_change', true), '') <> 'on' then
      new.featured_at := old.featured_at;
      new.featured_by := old.featured_by;
    end if;
  else
    new.created_at := now();
    new.featured_at := null;
    new.featured_by := null;
  end if;
  if coalesce(current_setting('app.feature_change', true), '') <> 'on' then
    if auth.uid() is not null and not public.qotw_is_open(new.episode) then
      raise exception 'This question is closed, so answers can no longer be changed.' using errcode = 'P0001', hint = 'question_closed';
    end if;
    if private.contains_blocked_word(new.body) then
      raise exception 'That text isn''t allowed. Please reword it.' using errcode = 'P0001', hint = 'blocked_text';
    end if;
    new.updated_at := now();
    perform private.enforce_rate_limit('qotw_answer', 20, interval '1 hour');
  end if;
  return new;
end;
$$;

create or replace function private.before_vote_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_answer record;
begin
  new.created_at := now();
  select a.episode, a.user_id into v_answer from public.qotw_answers a where a.id = new.answer_id;
  if v_answer is null or not public.qotw_is_closed(v_answer.episode) then
    raise exception 'You can vote once a question has closed.' using errcode = 'P0001', hint = 'question_open';
  end if;
  if v_answer.user_id = new.user_id then
    raise exception 'You can''t vote for your own answer.' using errcode = 'P0001', hint = 'own_answer';
  end if;
  perform private.enforce_rate_limit('qotw_vote', 120, interval '1 hour');
  return new;
end;
$$;

create or replace function private.before_profile_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
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
  else
    new.created_at := now();
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

-- 6. Export completeness ----------------------------------------------------------------------------
create or replace function public.export_my_data()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := private.require_signed_in();
begin
  return jsonb_build_object(
    'exported_at', now(),
    'account', (select jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at)
                  from auth.users u where u.id = v_uid),
    'sign_in_methods', coalesce((select jsonb_agg(jsonb_build_object('provider', i.provider, 'email', i.identity_data ->> 'email',
                                       'linked_at', i.created_at) order by i.created_at) from auth.identities i where i.user_id = v_uid), '[]'::jsonb),
    'profile', (select to_jsonb(p) - 'display_name_key' from public.profiles p where p.id = v_uid),
    'notification_switches', (select to_jsonb(n) from public.notification_prefs n where n.user_id = v_uid),
    'role', (select r.role from public.user_roles r where r.user_id = v_uid),
    'reserved_name_exception', exists (select 1 from private.name_exceptions e where e.user_id = v_uid),
    'ban', (select to_jsonb(b) - 'banned_by' from public.bans b where b.user_id = v_uid),
    'qotw_answers', coalesce((select jsonb_agg(jsonb_build_object('episode', a.episode, 'answer', a.body, 'created_at', a.created_at,
                                     'updated_at', a.updated_at, 'featured', a.featured_at is not null) order by a.episode)
                                from public.qotw_answers a where a.user_id = v_uid), '[]'::jsonb),
    'qotw_votes', coalesce((select jsonb_agg(jsonb_build_object('answer_id', v.answer_id, 'created_at', v.created_at))
                              from public.qotw_answer_votes v where v.user_id = v_uid), '[]'::jsonb),
    'roster_requests', coalesce((select jsonb_agg(to_jsonb(r) - 'user_id' order by r.created_at)
                                   from public.roster_requests r where r.user_id = v_uid), '[]'::jsonb),
    'audit_entries_about_you', coalesce((select jsonb_agg(jsonb_build_object('at', a.created_at, 'action', a.action) order by a.created_at)
                                           from public.audit_log a where a.target_id = v_uid or a.actor_id = v_uid), '[]'::jsonb)
  );
end;
$$;

-- create or replace keeps existing grants; make sure the new helper isn't callable through the API.
revoke all on function private.has_non_latin_letters(text) from public, anon, authenticated;

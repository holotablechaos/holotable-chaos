-- The moderation lists (blocked terms, allowlist, reserved names) must never be readable through the
-- API, by anyone, including the owner. Management works by typing terms; results are counts only.
--
-- After this migration the only public functions that touch the lists are:
--   admin_moderation_counts()      counts by category / list
--   admin_test_text(text, bool)    blocked yes/no, categories, reserved yes/no, taken yes/no
--   admin_add_terms(...)           returns how many were added
--   admin_remove_terms(...)        returns how many were removed and how many were not found
--   admin_update_terms(...)        returns how many were changed and how many were not found
-- None of them returns, echoes or audits a term. Inputs are validated before touching the tables so
-- no database error can echo a term back.

drop function public.admin_list_terms(text);
drop function public.admin_remove_terms(text, bigint[]);
drop function public.admin_update_terms(text, bigint[], text, text);
drop function public.admin_test_text(text, boolean);
drop function public.admin_add_terms(text, text[], text, text);

-- Shared input validation. Raises one generic message; never includes the input.
create function private.clean_term_input(p_list text, p_terms text[], p_match_type text, p_category text)
returns text[] language plpgsql immutable set search_path = '' as $$
declare
  v_terms text[];
begin
  if p_list not in ('blocked', 'allowed', 'reserved') then
    raise exception 'Unknown list.' using errcode = 'P0001';
  end if;
  if p_match_type is not null and not (
       (p_list = 'blocked' and p_match_type in ('word', 'substring', 'phrase'))
    or (p_list = 'reserved' and p_match_type in ('word', 'contains'))) then
    raise exception 'That match type isn''t available for this list.' using errcode = 'P0001';
  end if;
  if p_category is not null and (p_list <> 'blocked' or p_category not in
       ('profanity', 'slur', 'sexual', 'sexual_violence', 'harassment', 'self_harm', 'hate_symbol', 'other')) then
    raise exception 'That category isn''t available for this list.' using errcode = 'P0001';
  end if;
  select coalesce(array_agg(distinct btrim(t)), '{}') into v_terms
    from unnest(coalesce(p_terms, '{}')) t where btrim(t) <> '';
  if exists (select 1 from unnest(v_terms) t
              where char_length(t) < 2 or char_length(t) > (case when p_list = 'reserved' then 60 else 80 end)
                 or private.norm_words(t) = '') then
    raise exception 'Each entry needs 2 to 80 characters, including at least one letter or number. Nothing was changed.'
      using errcode = 'P0001';
  end if;
  if array_length(v_terms, 1) > 2000 then
    raise exception 'Add at most 2000 entries at a time.' using errcode = 'P0001';
  end if;
  return v_terms;
end;
$$;

create function public.admin_add_terms(p_list text, p_terms text[], p_match_type text default null, p_category text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_terms text[];
  v_added integer;
begin
  perform private.require_admin();
  v_terms := private.clean_term_input(p_list, p_terms, p_match_type, p_category);
  if p_list = 'blocked' then
    insert into private.blocked_terms (term, match_type, category)
    select t, coalesce(p_match_type, 'word'), coalesce(p_category, 'other') from unnest(v_terms) t
    on conflict do nothing;
  elsif p_list = 'allowed' then
    insert into private.allowed_terms (term) select t from unnest(v_terms) t on conflict do nothing;
  else
    insert into private.reserved_names (name, match_type)
    select t, coalesce(p_match_type, 'word') from unnest(v_terms) t on conflict do nothing;
  end if;
  get diagnostics v_added = row_count;
  perform private.audit('moderation_terms_added', null,
    jsonb_build_object('list', p_list, 'count', v_added, 'match_type', p_match_type, 'category', p_category));
  return v_added;
end;
$$;

-- Remove by typing the exact entries (compared after normalisation). Counts only.
create function public.admin_remove_terms(p_list text, p_terms text[], p_match_type text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_terms text[];
  v_keys text[];
  v_removed integer;
  v_found integer;
begin
  perform private.require_admin();
  v_terms := private.clean_term_input(p_list, p_terms, p_match_type, null);
  if p_list = 'reserved' then
    select array_agg(distinct private.name_key(t)) into v_keys from unnest(v_terms) t;
    select count(distinct name_key) into v_found from private.reserved_names where name_key = any (v_keys);
    delete from private.reserved_names where name_key = any (v_keys);
  else
    select array_agg(distinct private.norm_words(t)) into v_keys from unnest(v_terms) t;
    if p_list = 'blocked' then
      select count(distinct term_words) into v_found from private.blocked_terms
       where term_words = any (v_keys) and (p_match_type is null or match_type = p_match_type);
      delete from private.blocked_terms where term_words = any (v_keys) and (p_match_type is null or match_type = p_match_type);
    else
      select count(distinct term_words) into v_found from private.allowed_terms where term_words = any (v_keys);
      delete from private.allowed_terms where term_words = any (v_keys);
    end if;
  end if;
  get diagnostics v_removed = row_count;
  perform private.audit('moderation_terms_removed', null, jsonb_build_object('list', p_list, 'count', v_removed));
  return jsonb_build_object('removed', v_removed, 'not_found', coalesce(array_length(v_keys, 1), 0) - v_found);
end;
$$;

-- Change match type and/or category by typing the exact entries. Counts only.
create function public.admin_update_terms(p_list text, p_terms text[], p_match_type text default null, p_category text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_terms text[];
  v_keys text[];
  v_changed integer;
  v_found integer;
begin
  perform private.require_admin();
  if p_list = 'allowed' then
    raise exception 'Allowlist entries have no match type or category.' using errcode = 'P0001';
  end if;
  if p_match_type is null and p_category is null then
    raise exception 'Choose a match type or category to change.' using errcode = 'P0001';
  end if;
  v_terms := private.clean_term_input(p_list, p_terms, p_match_type, p_category);
  if p_list = 'blocked' then
    select array_agg(distinct private.norm_words(t)) into v_keys from unnest(v_terms) t;
    select count(distinct term_words) into v_found from private.blocked_terms where term_words = any (v_keys);
    -- If the new match type already exists for a term, keep that row and drop the duplicate.
    if p_match_type is not null then
      delete from private.blocked_terms b
       where b.term_words = any (v_keys) and b.match_type <> p_match_type
         and exists (select 1 from private.blocked_terms o where o.term_words = b.term_words and o.match_type = p_match_type);
    end if;
    update private.blocked_terms set match_type = coalesce(p_match_type, match_type), category = coalesce(p_category, category)
     where term_words = any (v_keys);
  else
    select array_agg(distinct private.name_key(t)) into v_keys from unnest(v_terms) t;
    select count(distinct name_key) into v_found from private.reserved_names where name_key = any (v_keys);
    update private.reserved_names set match_type = coalesce(p_match_type, match_type) where name_key = any (v_keys);
  end if;
  get diagnostics v_changed = row_count;
  perform private.audit('moderation_terms_changed', null,
    jsonb_build_object('list', p_list, 'count', v_changed, 'match_type', p_match_type, 'category', p_category));
  return jsonb_build_object('changed', v_changed, 'not_found', coalesce(array_length(v_keys, 1), 0) - v_found);
end;
$$;

-- Tester: whether text would be blocked and which categories. Never returns terms, matched words,
-- positions or a normalised copy of the text.
create function public.admin_test_text(p_text text, p_as_name boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_categories text[];
  v_reserved boolean;
begin
  perform private.require_admin();
  select coalesce(array_agg(distinct m.category order by m.category), '{}') into v_categories from private.blocked_matches(p_text) m;
  v_reserved := p_as_name and private.reserved_match(p_text);
  return jsonb_build_object(
    'blocked', cardinality(v_categories) > 0 or v_reserved,
    'categories', to_jsonb(v_categories),
    'reserved_name', v_reserved,
    'name_taken', p_as_name and exists (select 1 from public.profiles where display_name_key = private.name_key(p_text)));
end;
$$;

revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function
  public.admin_add_terms(text, text[], text, text), public.admin_remove_terms(text, text[], text),
  public.admin_update_terms(text, text[], text, text), public.admin_test_text(text, boolean)
from public, anon, authenticated;
grant execute on function
  public.admin_add_terms(text, text[], text, text), public.admin_remove_terms(text, text[], text),
  public.admin_update_terms(text, text[], text, text), public.admin_test_text(text, boolean)
to authenticated;

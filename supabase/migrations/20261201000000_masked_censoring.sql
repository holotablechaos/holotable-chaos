-- Catch symbol-censored words such as "f*ck", "sh*t", "f**k", "b#tch" or "gr%bble".
--
-- Only masks INSIDE a word count (letters or digits on both sides), so markdown like **bold**,
-- ratings like 4* and questions like "what?" are untouched. A masked word needs at least two real
-- letters (so "5*3=15" is ignored). Each run of mask characters stands for 1..n letters, where n is
-- the run length, and the whole masked word must then equal a blocked word or substring term.
-- Underscores and dots are not masks, so names like "jd_5" behave as before.

create function private.masked_patterns(p text) returns setof text
language plpgsql immutable parallel safe set search_path = '' as $$
declare
  v_text text;
  v_token text;
  v_letters integer;
  v_pattern text;
begin
  if p is null then
    return;
  end if;
  v_text := lower(normalize(p, NFKC));
  v_text := regexp_replace(v_text, '[­​-‏⁠-⁤﻿]', '', 'g');
  v_text := private.unaccent_immutable(v_text);
  for v_token in
    select m[1] from regexp_matches(v_text, '([a-z0-9@$!|]+(?:[*#%?]+[a-z0-9@$!|]+)+)', 'g') m
  loop
    v_letters := char_length(regexp_replace(v_token, '[^a-z]', '', 'g'));
    continue when v_letters < 2 or char_length(v_token) > 30;
    -- Same character swaps as norm_words, then every mask run becomes ".{1,n}".
    v_pattern := translate(v_token, '@4$5310!|7', 'aasseioiit');
    v_pattern := regexp_replace(v_pattern, '([a-z0-9])\1+', '\1+', 'g');           -- stretched letters
    select string_agg(case when part ~ '^[*#%?]+$' then '.{1,' || char_length(part) || '}' else part end, '' order by n)
      into v_pattern
      from regexp_matches(v_pattern, '([*#%?]+|[a-z0-9+]+)', 'g') with ordinality as x(m, n), lateral (select m[1] as part) y;
    return next '^' || v_pattern || '$';
  end loop;
end;
$$;

create or replace function private.blocked_matches(p text)
returns table (id bigint, term text, match_type text, category text)
language plpgsql stable security definer set search_path = '' as $$
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
  v_words := ' ' || private.norm_words(p) || ' ';
  for v_allowed in select a.term_words from private.allowed_terms a where a.term_words <> '' loop
    while position(' ' || v_allowed || ' ' in v_words) > 0 loop
      v_words := replace(v_words, ' ' || v_allowed || ' ', ' ');
    end loop;
  end loop;
  v_squeezed := private.squeeze(v_words);
  v_compact := replace(v_words, ' ', '');
  v_compact_squeezed := private.squeeze(v_compact);
  -- Masked words, minus any that could be an allowlisted word.
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

revoke execute on all functions in schema private from public, anon, authenticated;

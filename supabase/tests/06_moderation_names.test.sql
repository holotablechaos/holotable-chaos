-- Blocked terms, allowlist, reserved names, exceptions and unique display names.
-- FICTIONAL words and names only: the real lists never live in this repository.
--   "grobble" = a blocked word, "zork" = a substring-only term, "go jump in a vat" = a phrase,
--   "Zebra Crew" = the show's name, "QX7" / "Hey Folks" = hosts' in-game names, "Kip" = a host.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.as_db() returns void language sql as $$
  select set_config('request.jwt.claims', '', true);
$$;

-- ---------------- normalisation ----------------
select is(private.norm_words('GR0BBLE'), 'grobble', 'upper case and 0 -> o');
select is(private.norm_words('gr@bble 4ll $3t'), 'grabble all set', '@ 4 -> a, $ -> s, 3 -> e');
select is(private.norm_words('g.r.o.b.b.l.e'), 'grobble', 'dotted letters are joined');
select is(private.norm_words('g r o b b l e'), 'grobble', 'spaced letters are joined');
select is(private.norm_words(E'gro​bble'), 'grobble', 'zero-width characters are removed');
select is(private.norm_words('gróbblé'), 'grobble', 'accents are removed');
select is(private.norm_words('ｇｒｏｂｂｌｅ'), 'grobble', 'full-width letters are normalised');
select is(private.norm_words('I am a fan'), 'i am a fan', 'one or two single letters stay separate words');
select is(private.name_key('Hooolo   K@aat?'), 'holokat', 'name keys drop spaces and punctuation and collapse repeats');

-- ---------------- blocked terms ----------------
insert into private.blocked_terms (term, match_type, category) values
  ('grobble', 'word', 'profanity'), ('zork', 'substring', 'slur'), ('go jump in a vat', 'phrase', 'self_harm'), ('pff', 'word', 'other');
insert into private.allowed_terms (term) values ('Zorkington');

select ok(private.contains_blocked_word('what a GR0BBLE move'), 'a word with a swap is caught');
select ok(private.contains_blocked_word('g.r.o.b.b.l.e'), 'dotted obfuscation is caught');
select ok(private.contains_blocked_word('grooobbbllle'), 'stretched letters are caught');
select ok(not private.contains_blocked_word('grobbleton and grobbles'), 'word terms match whole words only');
select ok(private.contains_blocked_word('total zorkhead'), 'substring terms match inside words');
select ok(not private.contains_blocked_word('I live in Zorkington'), 'allowlisted words are exempt');
select ok(private.contains_blocked_word('you should go jump in a vat'), 'phrases match');
select ok(not private.contains_blocked_word('go jump over the vat'), 'partial phrases do not');
select ok(not private.contains_blocked_word('pf and pfff'), 'short terms never match through letter collapsing');
select ok(not private.contains_blocked_word('Kill, destroy, attack and execute on the Dark Side'), 'ordinary game violence is fine');
select ok(not private.contains_blocked_word(null), 'empty text is fine');

-- ---------------- reserved names ----------------
insert into private.reserved_names (name, match_type) values
  ('Zebra Crew', 'contains'), ('ZC', 'word'), ('QX7', 'word'), ('Hey Folks', 'contains'),
  ('Kip ZC', 'word'), ('real Kip', 'word');

insert into private.owner_claim (email) values ('owner@example.test');
select pg_temp.new_user('owner@example.test', 'google', true) as owner_id \gset
select pg_temp.new_user('admin@example.test', 'google', true) as admin_id \gset
select pg_temp.new_user('host2@example.test', 'google', true) as host_id \gset
select pg_temp.new_user('a@example.test', 'google', true) as a_id \gset
select pg_temp.new_user('b@example.test', 'google', true) as b_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin');
insert into public.profiles (id) values (:'a_id'), (:'b_id'), (:'owner_id'), (:'admin_id'), (:'host_id');

set local role authenticated;
select pg_temp.as_user(:'a_id');
select throws_ok(format('update public.profiles set display_name = %L where id = auth.uid()', n), 'P0001',
                 'That text isn''t allowed. Please reword it.', format('a listener cannot use the reserved name "%s"', n))
  from unnest(array['Zebra Crew', 'zebracrew', 'ZEBRA CREW fan club', 'Z e b r a C r e w', 'ZC', 'Z C', 'QX7', 'Q X 7', 'qx_7', 'q.x.7',
                    'Hey Folks', 'HeyFolks', 'Hey_Folks', 'Hey-Folks', 'Kip ZC', 'KipZC', 'real Kip', 'reaaal Kipp', 'R3al K1p',
                    'Listener', 'Listener 1234', 'Dee · 1234']) n;
select throws_ok($$update public.profiles set in_game_name = 'QX7' where id = auth.uid()$$, 'P0001',
  'That text isn''t allowed. Please reword it.', 'reserved names apply to in-game names too');
select lives_ok($$update public.profiles set in_game_name = 'Kip' where id = auth.uid()$$, 'a bare host first name is fine');
reset role;

-- Lookalikes that aren't reserved are fine (checked one at a time, as a fresh name each).
select pg_temp.as_db();
select is((select count(*)::int from unnest(array['Kip', 'Kipper', 'ZCX', 'Zebra', 'Crew Chief', 'QX8', 'Hey Folk']) n
            where not private.name_allowed(:'a_id', n)), 0, 'names that only look similar are allowed');

-- Owner, admins and excepted accounts may use reserved names.
set local role authenticated;
select pg_temp.as_user(:'owner_id');
select lives_ok($$update public.profiles set display_name = 'Zebra Crew', in_game_name = 'QX7' where id = auth.uid()$$, 'the owner can use reserved names');
select pg_temp.as_user(:'admin_id');
select lives_ok($$update public.profiles set display_name = 'Hey Folks' where id = auth.uid()$$, 'an admin can use reserved names');
select pg_temp.as_user(:'host_id');
select throws_like($$update public.profiles set display_name = 'Kip ZC' where id = auth.uid()$$, '%isn''t allowed%', 'a co-host without an exception cannot');
select throws_like(format('select public.admin_add_name_exception(%L)', :'host_id'), '%Only the owner%', 'only the owner manages exceptions');
select pg_temp.as_user(:'admin_id');
select throws_like(format('select public.admin_add_name_exception(%L)', :'host_id'), '%Only the owner%', 'admins cannot manage exceptions');
select pg_temp.as_user(:'owner_id');
select lives_ok(format('select public.admin_add_name_exception(%L, %L)', :'host_id', 'co-host'), 'the owner adds an exception');
select is((select count(*)::int from public.admin_list_name_exceptions()), 1, 'the exception is listed');
select pg_temp.as_user(:'host_id');
select lives_ok($$update public.profiles set display_name = 'Kip ZC' where id = auth.uid()$$, 'an excepted account can use a reserved name');
reset role;
select is((select count(*)::int from public.audit_log where action = 'name_exception_added'), 1, 'adding an exception is audited');

-- ---------------- unique display names ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok($$update public.profiles set display_name = 'Holo Kat' where id = auth.uid()$$, 'A takes "Holo Kat"');
select pg_temp.as_user(:'b_id');
select throws_ok(format('update public.profiles set display_name = %L where id = auth.uid()', n), 'P0001',
                 'That name is already taken. Please choose another.', format('"%s" collides with "Holo Kat"', n))
  from unnest(array['Holo Kat', 'holo kat', 'HoloKat', 'H0lo K@t', 'Hoolo Kaat', 'Holo-Kat', 'h o l o k a t', 'Hólo Kät']) n;
select throws_ok($$update public.profiles set display_name = 'Zebra Crew' where id = auth.uid()$$, 'P0001',
  'That text isn''t allowed. Please reword it.', 'a reserved name held by the owner says "not allowed", not "taken"');
select lives_ok($$update public.profiles set display_name = 'Holo Kit' where id = auth.uid()$$, 'a different name is fine');
reset role;

-- The database itself refuses duplicates, even if two saves race past the friendly check.
set local session_replication_role = replica;  -- skip the trigger to imitate two saves at the same instant
select throws_ok(format($$update public.profiles set display_name = 'Holo Kat', display_name_key = 'holokat' where id = %L$$, :'b_id'), '23505', null,
  'with the check skipped, the second simultaneous save still fails on the unique index');
set local session_replication_role = origin;

set local role authenticated;
select pg_temp.as_user(:'b_id');
select is(public.check_display_name('h0lo kat'), 'taken', 'the inline check reports a taken name');
select is(public.check_display_name('Zebra Crew'), 'not_allowed', 'and a reserved one, without saying why');
select is(public.check_display_name('Brand New Name'), 'ok', 'and a free one');
select is(public.check_display_name('Holo Kit'), 'ok', 'your own current name is fine');
reset role;
set local role anon;
select throws_ok($$select public.check_display_name('x')$$, '42501', null, 'signed-out visitors cannot use the check');
reset role;

-- One change every 30 days; clearing counts as a change.
set local role authenticated;
select pg_temp.as_user(:'b_id');
select throws_like($$update public.profiles set display_name = 'Holo Kit Two' where id = auth.uid()$$, '%once every 30 days%',
  'a second change within 30 days is refused');
select throws_like($$update public.profiles set display_name = null where id = auth.uid()$$, '%once every 30 days%',
  'clearing the name also counts as a change');
select isnt(public.my_name_change_available_at(), null, 'the page can show when the next change is allowed');
select lives_ok($$update public.profiles set bio = 'still editable' where id = auth.uid()$$, 'other fields can still be edited');
reset role;
select pg_temp.as_db();
update public.profiles set display_name_changed_at = now() - interval '31 days' where id = :'b_id';
set local role authenticated;
select pg_temp.as_user(:'b_id');
select lives_ok($$update public.profiles set display_name = 'Holo Kit Two' where id = auth.uid()$$, 'after 30 days the name can change');
select pg_temp.as_user(:'b_id');
select is(public.my_name_change_available_at() > now() + interval '29 days', true, 'and the 30 days start again');
reset role;

-- Deleting an account releases its name.
select pg_temp.new_user('c@example.test', 'google', true) as c_id \gset
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok('select public.delete_my_account()', 'A deletes their account');
select pg_temp.as_user(:'c_id');
select lives_ok($$insert into public.profiles (id, display_name) values (auth.uid(), 'Holo Kat')$$, 'the freed name can be taken by someone else');
reset role;

-- Owner reclaim.
set local role authenticated;
select pg_temp.as_user(:'admin_id');
select throws_like($$select public.admin_lookup_name('Holo Kat')$$, '%Only the owner%', 'admins cannot look up name holders');
select throws_like(format('select public.admin_reclaim_name(%L)', :'c_id'), '%Only the owner%', 'admins cannot reclaim names');
select pg_temp.as_user(:'owner_id');
select is(public.admin_lookup_name('h0lo kat') ->> 'id', :'c_id', 'the owner can look up who holds a name (lookalikes too)');
select is(public.admin_lookup_name('Nobody Here'), null, 'an unused name returns nothing');
select lives_ok(format('select public.admin_reclaim_name(%L)', :'c_id'), 'the owner reclaims the name');
reset role;
select is((select display_name from public.profiles where id = :'c_id'), null, 'the name is cleared');
select is((select count(*)::int from public.audit_log where action = 'display_name_reclaimed' and target_id = :'c_id'), 1, 'the reclaim is audited');
set local role authenticated;
select pg_temp.as_user(:'c_id');
select lives_ok($$update public.profiles set display_name = 'Brand New Me' where id = auth.uid()$$, 'after a reclaim the listener can pick a new name at once');
reset role;

-- ---------------- fallback names ----------------
insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'twin1@example.test', now(), '{}', '{}', now(), now()),
       ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'twin2@example.test', now(), '{}', '{}', now(), now());
insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
values ('twin-1', '11111111-1111-1111-1111-111111111111', '{"email": "twin1@example.test", "email_verified": true, "full_name": "Same Name"}', 'google', now(), now()),
       ('twin-2', '22222222-2222-2222-2222-222222222222', '{"email": "twin2@example.test", "email_verified": true, "full_name": "Same Name"}', 'google', now(), now());
select matches(private.display_name_for('11111111-1111-1111-1111-111111111111'), '^Same Name · [0-9]{4}$', 'fallback names carry a numbered suffix');
select isnt(private.display_name_for('11111111-1111-1111-1111-111111111111'), private.display_name_for('22222222-2222-2222-2222-222222222222'),
  'two people with the same provider name look different');
select is(private.display_name_for('11111111-1111-1111-1111-111111111111'), private.display_name_for('11111111-1111-1111-1111-111111111111'),
  'the suffix is stable for the same account');
insert into public.profiles (id, display_name) values ('11111111-1111-1111-1111-111111111111', 'Twin One');
select is(private.display_name_for('11111111-1111-1111-1111-111111111111'), 'Twin One', 'setting a real name removes the suffix');

-- ---------------- admin tools ----------------
set local role authenticated;
select pg_temp.as_user(:'admin_id');
select is((public.admin_test_text('what a gr0bble') ->> 'blocked')::boolean, true, 'the tester flags blocked text');
select is(public.admin_test_text('what a gr0bble') -> 'categories', '["profanity"]'::jsonb, 'and says which category, never the term');
select is((public.admin_test_text('Zebra Crew', true) ->> 'reserved_name')::boolean, true, 'and reports reserved names');
select is((public.admin_test_text('Cassian and Plo Koon') ->> 'blocked')::boolean, false, 'clean text passes');
select is(public.admin_add_terms('blocked', array['wibblet', 'grobble', '  '], 'word', 'profanity'), 1, 'bulk add skips duplicates and blanks');
select is(public.admin_update_terms('blocked', array['Wibblet', 'nothere'], 'substring', 'harassment'), '{"changed": 1, "not_found": 1}'::jsonb,
  'match type and category change by typing the term');
select is(public.admin_remove_terms('blocked', array['WIBBLET', 'nothere']), '{"removed": 1, "not_found": 1}'::jsonb,
  'terms are removed by typing them; only counts come back');
select is(public.admin_add_terms('allowed', array['Grobbleshire']), 1, 'allowlist entries can be added');
select is(public.admin_add_terms('reserved', array['Night Desk'], 'word'), 1, 'reserved names can be added');
select is((public.admin_moderation_counts() -> 'blocked_by_category' ->> 'profanity')::int, 1, 'counts by category');
reset role;
select is((select count(*)::int from public.audit_log where action like 'moderation_terms_%'), 5, 'every list change is audited');
select ok(not exists (select 1 from public.audit_log where details::text like '%wibblet%' or details::text like '%Grobbleshire%'),
  'audit entries record counts, not the words');

-- The out-of-repo loader replaces only list rows and is repeatable.
select pg_temp.as_db();
select is(private.load_list('blocked', '[{"term": "snorf", "match_type": "word", "category": "profanity"}, {"term": "blorp", "match_type": "substring", "category": "slur"}]') ->> 'loaded', '2', 'a list loads');
select is(private.load_list('blocked', '[{"term": "snorf", "match_type": "word", "category": "profanity"}, {"term": "blorp", "match_type": "substring", "category": "slur"}]') ->> 'loaded', '2', 'loading again gives the same result');
select ok(exists (select 1 from private.blocked_terms where term = 'grobble' and source = 'admin'), 'admin-added terms survive a reload');
select is((select array_agg(text_value order by text_value) from private.blocked_texts(array['snorf you', 'Cassian Andor', 'xblorpx'])), array['snorf you', 'xblorpx'],
  'the batch checker reports only the texts that would be blocked');

select * from finish();
rollback;

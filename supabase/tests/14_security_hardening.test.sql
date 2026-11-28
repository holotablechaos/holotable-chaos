-- Security review fixes. Fictional data only.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
select private.qotw_apply('{"current_episode": 2, "questions": [{"episode": 1, "text": "Closed fictional question?"}, {"episode": 2, "text": "Open fictional question?"}]}');

insert into private.owner_claim (email) values ('owner@example.test');
select pg_temp.new_user('owner@example.test', 'google', true) as owner_id \gset
select pg_temp.new_user('admin@example.test', 'google', true) as admin_id \gset
select pg_temp.new_user('admin2@example.test', 'google', true) as admin2_id \gset
select pg_temp.new_user('a@example.test', 'google', true) as a_id \gset
select pg_temp.new_user('b@example.test', 'google', true) as b_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin'), (:'admin2_id', 'admin');
insert into public.profiles (id, display_name) values (:'b_id', 'Fictional Host');

-- ---------------- 1. a banned admin loses admin powers ----------------
set local role authenticated;
select pg_temp.as_user(:'owner_id');
select lives_ok(format('select public.admin_ban(%L, %L)', :'admin_id', 'fictional reason'), 'the owner bans an admin');
select pg_temp.as_user(:'admin_id');
select is(public.is_admin(), false, 'a banned admin is not treated as an admin');
select throws_like(format('select public.admin_unban(%L)', :'admin_id'), '%Only admins%', 'a banned admin cannot unban themselves');
select throws_like(format('select public.admin_ban(%L)', :'a_id'), '%Only admins%', 'a banned admin cannot ban others');
select throws_like('select public.admin_list_accounts()', '%Only admins%', 'a banned admin cannot list accounts');
select throws_like('select public.admin_content_counts()', '%Only admins%', 'a banned admin cannot read admin counts');
select throws_like($$select public.admin_test_text('anything')$$, '%Only admins%', 'a banned admin cannot use the filter tester');
select is((select count(*)::int from public.audit_log), 0, 'a banned admin cannot read the audit log');
select is((select count(*)::int from public.profiles where id <> auth.uid()), 0, 'a banned admin cannot read other profiles');
select is((select count(*)::int from public.bans where user_id <> auth.uid()), 0, 'a banned admin only sees their own ban');
select pg_temp.as_user(:'admin2_id');
select throws_like(format('select public.admin_unban(%L)', :'admin_id'), '%Only the owner%', 'another admin cannot lift an admin''s ban');
select lives_ok(format('select public.admin_ban(%L)', :'a_id'), 'an admin can still ban a listener');
select lives_ok(format('select public.admin_unban(%L)', :'a_id'), 'and lift a listener''s ban');
select pg_temp.as_user(:'owner_id');
select lives_ok(format('select public.admin_unban(%L)', :'admin_id'), 'the owner can lift an admin''s ban');
select pg_temp.as_user(:'admin_id');
select is(public.is_admin(), true, 'once unbanned, the admin is an admin again');
select is(public.is_owner(), false, 'and is still not the owner');
reset role;

-- ---------------- 2. profiles can't be deleted to dodge the name limit ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok($$insert into public.profiles (id, display_name) values (auth.uid(), 'Fictional Alpha')$$, 'A sets a first name');
select throws_like($$update public.profiles set display_name = 'Fictional Beta' where id = auth.uid()$$, '%once every 30 days%',
  'changing it again straight away is refused');
select throws_ok('delete from public.profiles where id = auth.uid()', '42501', null, 'A cannot delete their profile row to reset the limit');
select lives_ok($$update public.profiles set bio = null, in_game_name = null, ally_code = null where id = auth.uid()$$,
  'clearing profile fields still works');
reset role;
select is((select display_name from public.profiles where id = :'a_id'), 'Fictional Alpha', 'the name is unchanged');

-- ---------------- 3. look-alike letters from other alphabets ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select is(public.check_display_name('Fictional Hоst'), 'not_allowed', 'a Cyrillic o inside a Latin name is refused');
select is(public.check_display_name('Fictiοnal Gamma'), 'not_allowed', 'a Greek omicron is refused');
select is(public.check_display_name('Fictional Hɑst'), 'not_allowed', 'an IPA alpha is refused');
select is(public.check_display_name('Fictional Host'), 'taken', 'the real name is reported as taken');
select is(public.check_display_name('Ｆｉｃｔｉｏｎａｌ Ｈｏｓｔ'), 'taken', 'full-width letters fold to the same name');
select is(public.check_display_name('José Zoë Łukasz'), 'ok', 'accented Latin names are still fine');
select is(public.check_display_name('Fictional Delta 🎙️'), 'ok', 'emoji are still fine');
select throws_like($$update public.profiles set in_game_name = 'Fictiоnal' where id = auth.uid()$$, '%isn''t allowed%',
  'look-alike letters are refused in in-game names too');
reset role;

-- ---------------- 4. overlong text is refused before filtering ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select throws_ok(format('update public.profiles set bio = %L where id = auth.uid()', repeat('fictional words ', 20000)), '22001', null,
  'a huge bio is refused as too long');
select throws_ok(format('insert into public.qotw_answers (episode, user_id, body) values (2, auth.uid(), %L)', repeat('a*b ', 40000)), '22001', null,
  'a huge answer is refused as too long');
select throws_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (auth.uid(), '123456789', %L)$$, repeat('x', 100000)), '22001', null,
  'huge roster goals are refused as too long');
select is(public.check_display_name(repeat('fictional', 100000)), 'not_allowed', 'a huge name check answers quickly');
select throws_ok(format('update public.profiles set bio = %L where id = auth.uid()', repeat('b', 501)), '23514', null,
  'the normal 500-character limit still applies');
reset role;

-- ---------------- 5. created_at comes from the database ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok($$insert into public.qotw_answers (episode, user_id, body, created_at) values (2, auth.uid(), 'Fictional answer', '2001-01-01')$$,
  'an answer with a made-up created_at is accepted');
select pg_temp.as_user(:'b_id');
select lives_ok($$insert into public.profiles (id, display_name, created_at) values (auth.uid(), 'Ignored', '2001-01-01')
                  on conflict (id) do update set bio = 'Fictional bio'$$, 'a profile upsert with a made-up created_at is accepted');
reset role;
select ok((select created_at > now() - interval '1 minute' from public.qotw_answers where user_id = :'a_id'), 'but the answer''s created_at is now');
select set_config('request.jwt.claims', '', true);  -- maintenance context: no signed-in user
insert into public.qotw_answers (episode, user_id, body) values (1, :'b_id', 'Fictional closed answer');
select id as b_answer from public.qotw_answers where user_id = :'b_id' and episode = 1 \gset
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok(format($$insert into public.qotw_answer_votes (answer_id, user_id, created_at) values (%L, auth.uid(), '2001-01-01')$$, :'b_answer'),
  'a vote with a made-up created_at is accepted');
reset role;
select ok((select created_at > now() - interval '1 minute' from public.qotw_answer_votes where user_id = :'a_id'), 'but the vote''s created_at is now');

-- ---------------- 6. export ----------------
insert into private.name_exceptions (user_id, note) values (:'a_id', 'Fictional note');
set local role authenticated;
select pg_temp.as_user(:'a_id');
select is(public.export_my_data() ->> 'reserved_name_exception', 'true', 'the export says the account has a reserved-name exception');
select ok(public.export_my_data()::text !~ 'Fictional note', 'without the owner''s private note');
select pg_temp.as_user(:'b_id');
select is(public.export_my_data() ->> 'reserved_name_exception', 'false', 'and says false for everyone else');
reset role;

-- The helper is not reachable through the API.
select ok(not has_function_privilege('authenticated', 'private.has_non_latin_letters(text)', 'execute'), 'listeners cannot call the new helper');
select ok(not has_function_privilege('anon', 'private.has_non_latin_letters(text)', 'execute'), 'nor can signed-out visitors');

select * from finish();
rollback;

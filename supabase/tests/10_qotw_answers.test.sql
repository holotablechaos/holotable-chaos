-- Question of the Week answers. Fictional questions, people and words only.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.feed(p_current integer, p_episodes integer[]) returns jsonb language sql as $$
  select jsonb_build_object('schema', 1, 'current_episode', p_current, 'questions',
    (select jsonb_agg(jsonb_build_object('episode', e, 'episode_title', 'Episode ' || e, 'text', 'Fictional question ' || e || '?',
                                         'published_at', '2026-01-0' || least(e, 9) || 'T12:00:00Z')) from unnest(p_episodes) e));
$$;

-- ---------------- question sync ----------------
select is(private.qotw_apply(pg_temp.feed(3, array[1, 2, 3])) ->> 'open', '3', 'the feed loads with question 3 open');
select is((select array_agg(episode order by episode) from public.qotw_questions where closed_at is null), array[3], 'only the current question is open');
select is((select count(*)::int from public.qotw_questions where closed_at is not null), 2, 'earlier questions are closed');
select lives_ok($$select private.qotw_apply(pg_temp.feed(3, array[1, 2, 3]))$$, 'applying the same feed again is harmless');
select throws_like($$select private.qotw_apply('{"questions": "nope"}')$$, '%expected format%', 'a malformed feed is refused');
select is(private.qotw_apply('{"current_episode": 3, "questions": [{"episode": "x", "text": "bad"}, {"episode": 2, "text": ""}]}') ->> 'questions', '0',
  'invalid entries are skipped');
select is((select count(*)::int from cron.job where jobname = 'qotw-sync'), 1, 'the hourly sync job is scheduled');

insert into private.blocked_terms (term, match_type, category) values ('grobble', 'word', 'profanity');
select pg_temp.new_user('a@example.test', 'google', true) as a_id \gset
select pg_temp.new_user('b@example.test', 'google', true) as b_id \gset
select pg_temp.new_user('admin@example.test', 'google', true) as admin_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin');

-- ---------------- answering ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok(format($$insert into public.qotw_answers (episode, user_id, body) values (3, %L, '  My fictional answer  ')$$, :'a_id'),
  'A answers the open question');
select is((select body from public.qotw_answers where user_id = :'a_id'), 'My fictional answer', 'answers are trimmed');
select throws_ok(format($$insert into public.qotw_answers (episode, user_id, body) values (3, %L, 'again')$$, :'a_id'), '23505', null,
  'one answer per listener per question');
select lives_ok($$update public.qotw_answers set body = 'Edited answer' where episode = 3 and user_id = auth.uid()$$, 'A edits while open');
select throws_like($$update public.qotw_answers set body = 'what a grobble' where episode = 3 and user_id = auth.uid()$$, '%isn''t allowed%',
  'the blocked-words filter applies to answers');
select throws_like(format($$insert into public.qotw_answers (episode, user_id, body) values (2, %L, 'late')$$, :'a_id'), '%closed%',
  'closed questions take no new answers');
select throws_ok(format($$insert into public.qotw_answers (episode, user_id, body) values (3, %L, 'pretending')$$, :'b_id'), '42501', null,
  'nobody can answer as someone else');
select lives_ok($$update public.qotw_answers set featured_at = now() where user_id = auth.uid()$$,
  'a listener trying to feature their own answer is quietly ignored');
reset role;
select is((select featured_at from public.qotw_answers where user_id = :'a_id'), null, 'the answer is still not featured');
set local role authenticated;
select pg_temp.as_user(:'a_id');
select throws_ok($$delete from public.qotw_answers where user_id = auth.uid()$$, '42501', null, 'deleting an answer is refused');
reset role;
select is((select count(*)::int from public.qotw_answers where user_id = :'a_id'), 1, 'answers cannot be deleted individually');

-- Hidden until the question closes.
set local role authenticated;
select pg_temp.as_user(:'b_id');
select lives_ok(format($$insert into public.qotw_answers (episode, user_id, body) values (3, %L, 'B answer')$$, :'b_id'), 'B answers too');
select is((select count(*)::int from public.qotw_answers), 1, 'B sees only their own answer while the question is open');
select is((select count(*)::int from public.qotw_answers_for(3)), 0, 'the listing is empty while open');
select throws_like(format($$insert into public.qotw_answer_votes (answer_id, user_id) select id, %L from public.qotw_answers where user_id = %L$$, :'b_id', :'b_id'),
  '%once a question has closed%', 'no voting while open');
select pg_temp.as_user(:'admin_id');
select is((select count(*)::int from public.qotw_answers_for(3)), 2, 'admins can read answers to the open question');
reset role;
set local role anon;
select throws_ok('select count(*) from public.qotw_answers', '42501', null, 'signed-out visitors cannot read answers');
select is((select count(*)::int from public.qotw_questions), 3, 'but questions are public');
reset role;

-- The rotation moves on: 3 closes, 4 opens.
select is(private.qotw_apply(pg_temp.feed(4, array[1, 2, 3, 4])) ->> 'open', '4', 'question 4 opens');
select ok(public.qotw_is_closed(3), 'question 3 is closed');
set local role authenticated;
select pg_temp.as_user(:'b_id');
select is((select count(*)::int from public.qotw_answers where episode = 3), 2, 'everyone signed in can now read the closed answers');
select throws_like($$update public.qotw_answers set body = 'too late' where episode = 3 and user_id = auth.uid()$$, '%closed%',
  'closed answers can no longer change');
select is((select count(*)::int from public.qotw_answers_for(3)), 2, 'the listing shows both answers');
select ok((select bool_and(a ? 'author' and a -> 'author' ? 'name') from public.qotw_answers_for(3) a), 'each answer comes with a name');
select ok(not exists (select 1 from public.qotw_answers_for(3) a where a::text ~ '@example\.test'), 'no email addresses in the listing');

-- Votes
select lives_ok(format($$insert into public.qotw_answer_votes (answer_id, user_id) select id, %L from public.qotw_answers where user_id = %L$$, :'b_id', :'a_id'),
  'B upvotes A''s answer');
select throws_like(format($$insert into public.qotw_answer_votes (answer_id, user_id) select id, %L from public.qotw_answers where user_id = %L$$, :'b_id', :'b_id'),
  '%own answer%', 'no voting for your own answer');
select throws_ok(format($$insert into public.qotw_answer_votes (answer_id, user_id) select id, %L from public.qotw_answers where user_id = %L$$, :'b_id', :'a_id'),
  '23505', null, 'one vote per answer');
select is((select (a ->> 'votes')::int from public.qotw_answers_for(3) a where (a ->> 'mine')::boolean = false), 1, 'the vote is counted');
select lives_ok($$delete from public.qotw_answer_votes where user_id = auth.uid()$$, 'B can take the vote back');
reset role;

-- Featuring (admins only, audited)
set local role authenticated;
select pg_temp.as_user(:'b_id');
select throws_like(format('select public.admin_feature_answer(id, true) from public.qotw_answers where user_id = %L', :'a_id'), '%Only admins%',
  'listeners cannot feature answers');
select pg_temp.as_user(:'admin_id');
select lives_ok(format('select public.admin_feature_answer(id, true) from public.qotw_answers where user_id = %L', :'a_id'), 'an admin features an answer');
select is((select (a ->> 'featured')::boolean from public.qotw_answers_for(3) a where a -> 'author' ->> 'id' = :'a_id'), true, 'it shows as featured');
select is((select a ->> 'id' from public.qotw_answers_for(3) a limit 1), (select id::text from public.qotw_answers where user_id = :'a_id'),
  'featured answers come first');
reset role;
select is((select count(*)::int from public.audit_log where action = 'answer_featured'), 1, 'featuring is audited');

-- Bans and rate limits
insert into public.bans (user_id, reason) values (:'b_id', 'test');
set local role authenticated;
select pg_temp.as_user(:'b_id');
select throws_ok(format($$insert into public.qotw_answers (episode, user_id, body) values (4, %L, 'banned answer')$$, :'b_id'), '42501', null,
  'banned listeners cannot answer');
reset role;
delete from public.bans where user_id = :'b_id';
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok(format($$insert into public.qotw_answers (episode, user_id, body) values (4, %L, 'first')$$, :'a_id'), 'A answers question 4');
select throws_like($q$do $do$ begin for i in 1..25 loop update public.qotw_answers set body = 'edit ' || i where episode = 4 and user_id = auth.uid(); end loop; end $do$ $q$,
  '%Too many changes%', 'answer edits are rate limited');

-- Stats and badge (answered 3 and 4; not 1 or 2)
select is(public.my_qotw_stats() ->> 'answers', '2', 'two answers counted');
select is(public.my_qotw_stats() ->> 'current_streak', '2', 'streak of two');
select is(public.my_qotw_stats() ->> 'badge', 'Rookie', 'participation badge');
select is((select count(*)::int from public.my_qotw_answers()), 2, 'A sees their own past answers');
select ok(public.export_my_data() -> 'qotw_answers' -> 0 ? 'answer', 'the data export includes answers');
reset role;
-- An open, unanswered question doesn't break the streak; a closed unanswered one does.
select is(private.qotw_stats_for(:'b_id') ->> 'current_streak', '1', 'B''s streak survives the open question 4');
select private.qotw_apply(pg_temp.feed(5, array[1, 2, 3, 4, 5]));
select is(private.qotw_stats_for(:'b_id') ->> 'current_streak', '0', 'once 4 closes unanswered, B''s streak resets');
select is(private.qotw_stats_for(:'b_id') ->> 'best_streak', '1', 'but the best streak is remembered');

-- Account deletion anonymises answers and removes votes
set local role authenticated;
select pg_temp.as_user(:'b_id');
select lives_ok(format($$insert into public.qotw_answer_votes (answer_id, user_id) select id, %L from public.qotw_answers where user_id = %L and episode = 3$$, :'b_id', :'a_id'),
  'B votes again');
select lives_ok('select public.delete_my_account()', 'B deletes their account');
reset role;
select is((select count(*)::int from public.qotw_answers where episode = 3 and user_id is null), 1, 'B''s answer remains, without an owner');
select is((select count(*)::int from public.qotw_answer_votes), 0, 'B''s votes are gone');
set local role authenticated;
select pg_temp.as_user(:'a_id');
select is((select a -> 'author' ->> 'name' from public.qotw_answers_for(3) a where (a -> 'author' ->> 'id') is null), 'Deleted listener',
  'it shows as "Deleted listener"');
reset role;

select * from finish();
rollback;

-- Admin deletion of QotW answers and roster requests. Fictional data only.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
select private.qotw_apply('{"current_episode": 3, "questions": [{"episode": 1, "text": "First fictional question?"}, {"episode": 2, "text": "Second fictional question?"}, {"episode": 3, "text": "Open fictional question?"}]}');

insert into private.owner_claim (email) values ('owner@example.test');
select pg_temp.new_user('owner@example.test', 'google', true) as owner_id \gset
select pg_temp.new_user('admin@example.test', 'google', true) as admin_id \gset
select pg_temp.new_user('a@example.test', 'google', true) as a_id \gset
select pg_temp.new_user('b@example.test', 'google', true) as b_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin');

-- Answers to questions 1 and 2 (closed via the database role), an upvote, and requests.
insert into public.qotw_answers (episode, user_id, body) values
  (1, :'a_id', 'A secret fictional answer one'), (2, :'a_id', 'A secret fictional answer two'),
  (2, :'b_id', 'B fictional answer'), (2, :'owner_id', 'Owner fictional answer'), (2, :'admin_id', 'Admin fictional answer');
insert into public.qotw_answer_votes (answer_id, user_id) select id, :'b_id' from public.qotw_answers where user_id = :'a_id' and episode = 2;
insert into public.roster_requests (user_id, ally_code, goals) values (:'a_id', '111222333', 'A secret fictional goal');
select id as a_answer2 from public.qotw_answers where user_id = :'a_id' and episode = 2 \gset
select id as owner_answer from public.qotw_answers where user_id = :'owner_id' \gset
select id as admin_answer from public.qotw_answers where user_id = :'admin_id' \gset
select id as a_request from public.roster_requests where user_id = :'a_id' \gset
select is(private.qotw_stats_for(:'a_id') ->> 'current_streak', '2', 'A starts with a streak of two');

-- ---------------- access matrix ----------------
set local role anon;
select throws_ok(format('select public.admin_delete_answer(%L)', :'a_answer2'), '42501', null, 'signed-out visitors cannot delete answers');
select throws_ok(format('select public.admin_delete_roster_request(%L)', :'a_request'), '42501', null, 'signed-out visitors cannot delete requests');
reset role;
set local role authenticated;
select pg_temp.as_user(:'a_id');
select throws_like(format('select public.admin_delete_answer(%L)', :'a_answer2'), '%Only admins%', 'the author cannot use the admin delete');
select throws_like(format('select public.admin_delete_roster_request(%L)', :'a_request'), '%Only admins%', 'the requester cannot use the admin delete');
select throws_ok('delete from public.qotw_answers where user_id = auth.uid()', '42501', null, 'authors still cannot delete their answers directly');
select throws_ok('delete from public.roster_requests where user_id = auth.uid()', '42501', null, 'requesters still cannot delete requests directly');
select pg_temp.as_user(:'b_id');
select throws_like(format('select public.admin_delete_answer(%L)', :'a_answer2'), '%Only admins%', 'another listener cannot delete answers');
reset role;
select is((select count(*)::int from public.qotw_answers), 5, 'nothing was deleted so far');

-- ---------------- an admin deletes ----------------
set local role authenticated;
select pg_temp.as_user(:'admin_id');
select lives_ok(format('select public.admin_delete_answer(%L)', :'a_answer2'), 'an admin deletes an answer');
select throws_like(format('select public.admin_delete_answer(%L)', :'a_answer2'), '%No answer with that id%', 'deleting it again is refused');
select throws_like(format('select public.admin_delete_answer(%L)', :'a_request'), '%No answer with that id%', 'the answer function ignores other kinds of ids');
select throws_like(format('select public.admin_delete_roster_request(%L)', :'owner_answer'), '%No request with that id%', 'the request function ignores other kinds of ids');
select throws_like(format('select public.admin_delete_roster_request(%L)', :'owner_id'), '%No request with that id%', 'an account id is not a request');
select lives_ok(format('select public.admin_delete_answer(%L)', :'owner_answer'), 'an admin can delete the owner''s answer too');
select lives_ok(format('select public.admin_delete_roster_request(%L)', :'a_request'), 'an admin deletes a roster request');
reset role;
set local role authenticated;
select pg_temp.as_user(:'owner_id');
select lives_ok(format('select public.admin_delete_answer(%L)', :'admin_answer'), 'the owner can delete an admin''s answer');
reset role;

select is((select count(*)::int from public.qotw_answers), 2, 'three answers are gone');
select is((select count(*)::int from public.qotw_answer_votes), 0, 'the deleted answer''s upvotes are gone');
select is(private.qotw_stats_for(:'a_id') ->> 'answers', '1', 'A''s answer count drops');
select is(private.qotw_stats_for(:'a_id') ->> 'current_streak', '0', 'and the streak updates (question 2 is no longer answered)');
select is((select count(*)::int from public.roster_requests where user_id = :'a_id'), 0, 'the request is gone');

-- Audit: in the same transaction, with ids and no text.
select is((select count(*)::int from public.audit_log where action = 'answer_deleted'), 3, 'each answer deletion is audited');
select is((select count(*)::int from public.audit_log where action = 'roster_request_deleted'), 1, 'the request deletion is audited');
select is((select target_id from public.audit_log where action = 'roster_request_deleted'), :'a_id'::uuid, 'the audit names the account');
select ok((select actor_id from public.audit_log where action = 'roster_request_deleted') = :'admin_id', 'and the admin who did it');
select is((select details ->> 'episode' from public.audit_log where action = 'answer_deleted' and target_id = :'a_id'), '2', 'and the episode');
select is((select details ->> 'status' from public.audit_log where action = 'roster_request_deleted'), 'received', 'and the request status');
select ok(not exists (select 1 from public.audit_log where details::text ~* 'secret fictional|fictional answer|fictional goal'),
  'no audit entry stores the deleted text');

-- The one-open-request slot is free again.
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '111222333', 'A new fictional goal')$$, :'a_id'),
  'A can request again after the open request was deleted');
select ok(public.export_my_data()::text !~ 'secret fictional answer two|secret fictional goal', 'A''s own export no longer includes deleted rows');
reset role;
set local role authenticated;
select pg_temp.as_user(:'owner_id');
select ok(public.admin_export_everything()::text !~ 'secret fictional answer two|secret fictional goal|Owner fictional answer|Admin fictional answer',
  'Export everything no longer includes deleted rows');
select ok(not exists (select 1 from public.admin_answers_export() a where a::text ~ 'secret fictional answer two'), 'nor does the answers CSV source');
reset role;

-- No alert is queued for deletions.
select is((select count(*)::int from net.http_request_queue), 0, 'deletions send no Discord alert');

select * from finish();
rollback;

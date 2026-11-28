-- Roster review requests. Fictional people, ally codes and words only.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
insert into private.blocked_terms (term, match_type, category) values ('grobble', 'word', 'profanity');
select pg_temp.new_user('a@example.test', 'google', true) as a_id \gset
select pg_temp.new_user('b@example.test', 'google', true) as b_id \gset
select pg_temp.new_user('admin@example.test', 'google', true) as admin_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin');

set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok(format($$insert into public.roster_requests (user_id, ally_code, swgoh_gg_url, goals, status)
                         values (%L, '111-222-333', 'https://swgoh.gg/p/111222333/', 'Reach Kyber', 'aired')$$, :'a_id'), 'A requests a review');
select is((select status from public.roster_requests where user_id = :'a_id'), 'received', 'a new request always starts as received');
select is((select ally_code from public.roster_requests where user_id = :'a_id'), '111222333', 'ally codes are stored as 9 digits');
select throws_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '111222333', 'Again')$$, :'a_id'), '23505', null,
  'only one open request per account');
select throws_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '12345', 'Bad code')$$, :'b_id'), '42501', null,
  'nobody can request on someone else''s behalf');
select throws_ok($$update public.roster_requests set ally_code = '123' where user_id = auth.uid()$$, '23514', null, 'ally codes are validated');
select throws_ok($$update public.roster_requests set swgoh_gg_url = 'https://evil.example/p/111222333/' where user_id = auth.uid()$$, '23514', null,
  'only swgoh.gg links are accepted');
select throws_like($$update public.roster_requests set goals = 'a grobble goal' where user_id = auth.uid()$$, '%isn''t allowed%', 'goals are filtered');
select throws_like($$update public.roster_requests set current_projects = 'grobble' where user_id = auth.uid()$$, '%isn''t allowed%', 'projects are filtered');
select lives_ok($$update public.roster_requests set goals = 'Reach Kyber in GAC', current_projects = 'Farming a fictional legend' where user_id = auth.uid()$$,
  'A edits while received');
select lives_ok($$update public.roster_requests set status = 'queued' where user_id = auth.uid()$$, 'a listener trying to queue it is ignored');
select is((select status from public.roster_requests where user_id = :'a_id'), 'received', 'and the status stays received');
select throws_ok('delete from public.roster_requests', '42501', null, 'requests cannot be deleted directly');
reset role;

-- Admin moves it along; then it's locked for the listener.
select id as a_request from public.roster_requests where user_id = :'a_id' \gset
set local role authenticated;
select pg_temp.as_user(:'b_id');
select is((select count(*)::int from public.roster_requests), 0, 'B cannot see A''s request');
select throws_like(format('select public.admin_set_roster_status(%L, %L)', :'a_request', 'queued'), '%Only admins%', 'listeners cannot change statuses');
select pg_temp.as_user(:'admin_id');
select is((select count(*)::int from public.roster_requests), 1, 'admins see all requests');
select lives_ok(format('select public.admin_set_roster_status(id, %L) from public.roster_requests where user_id = %L', 'queued', :'a_id'), 'an admin queues it');
select throws_like(format('select public.admin_set_roster_status(id, %L) from public.roster_requests where user_id = %L', 'aired', :'a_id'), '%episode number%',
  '"aired" needs an episode number');
reset role;
set local role authenticated;
select pg_temp.as_user(:'a_id');
select throws_like($$update public.roster_requests set goals = 'Changed my mind' where user_id = auth.uid()$$, '%no longer be changed%',
  'once queued, the listener can no longer edit');
select throws_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '111222333', 'Second')$$, :'a_id'), '23505', null,
  'queued still counts as open');
select pg_temp.as_user(:'admin_id');
select lives_ok(format('select public.admin_set_roster_status(id, %L, 42) from public.roster_requests where user_id = %L', 'aired', :'a_id'), 'it airs in episode 42');
reset role;
select is((select aired_episode from public.roster_requests where user_id = :'a_id'), 42, 'the airing episode is recorded');
select is((select count(*)::int from public.audit_log where action = 'roster_status_changed'), 2, 'status changes are audited');
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '111222333', 'Round two')$$, :'a_id'),
  'after it aired, A can request again');
select lives_ok($$update public.roster_requests set status = 'closed' where user_id = auth.uid() and status = 'received'$$, 'A withdraws the new one');
select lives_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '111222333', 'Round three')$$, :'a_id'),
  'a withdrawn request no longer blocks a new one');
select is(jsonb_array_length(public.export_my_data() -> 'roster_requests'), 3, 'the data export includes requests');
reset role;

-- Bans and rate limits
insert into public.bans (user_id, reason) values (:'b_id', 'test');
set local role authenticated;
select pg_temp.as_user(:'b_id');
select throws_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '444555666', 'Banned')$$, :'b_id'), '42501', null,
  'banned listeners cannot request');
reset role;
delete from public.bans;
set local role authenticated;
select pg_temp.as_user(:'b_id');
select lives_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '444555666', 'B goals')$$, :'b_id'), 'B requests');
select throws_like($q$do $do$ begin for i in 1..12 loop update public.roster_requests set goals = 'edit ' || i where user_id = auth.uid(); end loop; end $do$ $q$,
  '%Too many changes%', 'request edits are rate limited');
reset role;
set local role anon;
select throws_ok('select count(*) from public.roster_requests', '42501', null, 'signed-out visitors cannot read requests');
reset role;

-- Deletion removes requests
set local role authenticated;
select pg_temp.as_user(:'b_id');
select lives_ok('select public.delete_my_account()', 'B deletes their account');
reset role;
select is((select count(*)::int from public.roster_requests where user_id = :'b_id'), 0, 'B''s requests are gone');

select * from finish();
rollback;

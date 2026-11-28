-- Feedback sent with an account. Fictional data only; everything is rolled back, so no alert is sent.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.queued() returns integer language sql as $$ select count(*)::int from net.http_request_queue $$;

insert into private.blocked_terms (term, match_type, category) values ('grobble', 'word', 'profanity');
insert into private.owner_claim (email) values ('owner@example.test');
select pg_temp.new_user('owner@example.test', 'google', true) as owner_id \gset
select pg_temp.new_user('admin@example.test', 'google', true) as admin_id \gset
select pg_temp.new_user('a@example.test', 'google', true) as a_id \gset
select pg_temp.new_user('b@example.test', 'google', true) as b_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin');
insert into public.profiles (id, display_name) values (:'a_id', '@everyone **Fictional Ana**');
select vault.create_secret('https://discord.com/api/webhooks/1/fictional-token', 'discord_admin_webhook_url');

-- ---------------- sending ----------------
set local role anon;
select throws_ok($$insert into public.feedback (user_id, message_type, subject, message) values ('00000000-0000-0000-0000-000000000000', 'Other', 'S', 'M')$$,
  '42501', null, 'signed-out visitors cannot send feedback');
select throws_ok('select count(*) from public.feedback', '42501', null, 'signed-out visitors cannot read feedback');
reset role;

set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok($$insert into public.feedback (user_id, message_type, subject, message, status, created_at)
                  values (auth.uid(), 'Podcast Feedback', '  A fictional subject  ', '  A secret fictional message  ', 'resolved', '2001-01-01')$$,
  'A sends feedback with an account');
select throws_ok(format($$insert into public.feedback (user_id, message_type, subject, message) values (%L, 'Other', 'S', 'M')$$, :'b_id'),
  '42501', null, 'A cannot send feedback as B');
select throws_ok($$insert into public.feedback (user_id, message_type, subject, message) values (auth.uid(), 'Complaint', 'S', 'M')$$,
  '23514', null, 'only the form''s message types are accepted');
select throws_like($$insert into public.feedback (user_id, message_type, subject, message) values (auth.uid(), 'Other', 'S', 'a grobble message')$$,
  '%isn''t allowed%', 'the message is filtered');
select throws_like($$insert into public.feedback (user_id, message_type, subject, message) values (auth.uid(), 'Other', 'grobble', 'M')$$,
  '%isn''t allowed%', 'the subject is filtered');
select throws_ok(format($$insert into public.feedback (user_id, message_type, subject, message) values (auth.uid(), 'Other', 'S', %L)$$, repeat('m', 1001)),
  '22001', null, 'messages over 1000 characters are refused before filtering');
select throws_ok(format($$insert into public.feedback (user_id, message_type, subject, message) values (auth.uid(), 'Other', %L, 'M')$$, repeat('s', 181)),
  '23514', null, 'subjects over 180 characters are refused');
select throws_ok($$insert into public.feedback (user_id, message_type, subject, message) values (auth.uid(), 'Other', '   ', 'M')$$,
  '23514', null, 'an empty subject is refused');
reset role;
select is((select status from public.feedback where user_id = :'a_id'), 'received', 'new feedback always starts as received');
select ok((select created_at > now() - interval '1 minute' from public.feedback where user_id = :'a_id'), 'created_at is set by the database');
select is((select subject from public.feedback where user_id = :'a_id'), 'A fictional subject', 'text is trimmed');

-- The Discord alert names the type and sender only.
select is(pg_temp.queued(), 1, 'one admin alert is queued for the new message');
select ok((select convert_from(body, 'utf8') from net.http_request_queue limit 1) like '%New podcast feedback from%', 'it gives the message type');
select ok((select convert_from(body, 'utf8') from net.http_request_queue limit 1) !~ 'secret fictional message|A fictional subject', 'it contains no subject or message');
select ok((select convert_from(body, 'utf8') from net.http_request_queue limit 1) like '%\\\\@everyone%', 'mentions in names are neutralised');
select ok((select convert_from(body, 'utf8')::jsonb -> 'allowed_mentions' -> 'parse' from net.http_request_queue limit 1) = '[]'::jsonb,
  'and Discord is told not to ping anyone');

select id as fb from public.feedback where user_id = :'a_id' \gset

-- ---------------- reading ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select is((select count(*)::int from public.feedback), 1, 'A sees their own message');
select pg_temp.as_user(:'b_id');
select is((select count(*)::int from public.feedback), 0, 'another listener sees nothing');
select throws_like('select public.admin_feedback()', '%Only admins%', 'listeners cannot use the admin list');
select throws_like(format('select public.admin_set_feedback_status(%L, %L)', :'fb', 'read'), '%Only admins%', 'listeners cannot change the status');
select throws_like(format('select public.admin_delete_feedback(%L)', :'fb'), '%Only admins%', 'listeners cannot delete messages');
update public.feedback set message = 'B was here' where id = :'fb';
select pg_temp.as_user(:'admin_id');
select is((select count(*)::int from public.feedback), 1, 'admins see every message');
select is((select count(*)::int from public.admin_feedback('open')), 1, 'the admin list shows open messages');
select is((select f ->> 'subject' from public.admin_feedback() f), 'A fictional subject', 'with the subject');
select is((select f -> 'author' ->> 'name' from public.admin_feedback() f), '@everyone **Fictional Ana**', 'and the sender''s display name');
select pg_temp.as_user(:'owner_id');
select is((select count(*)::int from public.feedback), 1, 'the owner sees every message');
reset role;
select is((select message from public.feedback where id = :'fb'), 'A secret fictional message', 'B could not change A''s message');

-- ---------------- editing while received, then locked ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok(format($$update public.feedback set message = 'An edited fictional message', status = 'archived' where id = %L$$, :'fb'),
  'A can edit while the message is received');
select throws_ok(format('delete from public.feedback where id = %L', :'fb'), '42501', null, 'A cannot delete their message');
reset role;
select is((select status from public.feedback where id = :'fb'), 'received', 'but cannot change its status');
select is((select message from public.feedback where id = :'fb'), 'An edited fictional message', 'the edit was saved');

set local role authenticated;
select pg_temp.as_user(:'admin_id');
select throws_like(format('select public.admin_set_feedback_status(%L, %L)', :'fb', 'deleted'), '%Unknown status%', 'unknown statuses are refused');
select lives_ok(format('select public.admin_set_feedback_status(%L, %L)', :'fb', 'read'), 'an admin marks it read');
select pg_temp.as_user(:'a_id');
select throws_like(format($$update public.feedback set message = 'Too late' where id = %L$$, :'fb'), '%can no longer be changed%',
  'once read, the sender cannot edit it');
select pg_temp.as_user(:'admin_id');
select lives_ok(format('select public.admin_set_feedback_status(%L, %L)', :'fb', 'resolved'), 'then resolved');
select lives_ok(format('select public.admin_set_feedback_status(%L, %L)', :'fb', 'archived'), 'then archived');
reset role;
select is((select count(*)::int from public.audit_log where action = 'feedback_status_changed'), 3, 'each status change is audited');
select ok(not exists (select 1 from public.audit_log where details::text ~* 'fictional message|fictional subject'), 'audit entries hold no message text');

-- ---------------- bans and rate limits ----------------
set local role authenticated;
select pg_temp.as_user(:'admin_id');
select public.admin_ban(:'b_id', 'fictional reason');
select pg_temp.as_user(:'b_id');
select throws_ok($$insert into public.feedback (user_id, message_type, subject, message) values (auth.uid(), 'Other', 'S', 'M')$$,
  '42501', null, 'a banned listener cannot send feedback');
reset role;

set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok($$insert into public.feedback (user_id, message_type, subject, message)
                  select auth.uid(), 'Suggestion', 'Fictional subject ' || n, 'Fictional idea ' || n from generate_series(1, 8) n$$,
  'eight more messages fit in the hourly limit (with the first message and one edit, that makes ten writes)');
select throws_like($$insert into public.feedback (user_id, message_type, subject, message) values (auth.uid(), 'Other', 'S', 'M')$$,
  '%Too many changes%', 'the eleventh write in an hour is rate limited');
reset role;

-- ---------------- exports ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select is(jsonb_array_length(public.export_my_data() -> 'feedback'), 9, 'Download my data includes the sender''s messages');
select ok(not (public.export_my_data() -> 'feedback' -> 0 ? 'user_id'), 'without repeating the account id');
select pg_temp.as_user(:'admin_id');
select throws_like('select public.admin_export_everything()', '%Only the owner%', 'admins cannot export everything');
select pg_temp.as_user(:'owner_id');
select is(jsonb_array_length(public.admin_export_everything() -> 'feedback'), 9, 'Export everything includes feedback');
select is((public.admin_content_counts() ->> 'feedback_received')::int, 8, 'the overview counts new messages');
reset role;

-- ---------------- deletion ----------------
set local role authenticated;
select pg_temp.as_user(:'admin_id');
select lives_ok(format('select public.admin_delete_feedback(%L)', :'fb'), 'an admin deletes a message');
select throws_like(format('select public.admin_delete_feedback(%L)', :'fb'), '%No message with that id%', 'deleting it again is refused');
reset role;
select is((select count(*)::int from public.audit_log where action = 'feedback_deleted'), 1, 'the deletion is audited');
select is((select details ->> 'type' from public.audit_log where action = 'feedback_deleted'), 'Podcast Feedback', 'with the type');
select ok(not exists (select 1 from public.audit_log where details::text ~* 'fictional message|fictional subject'), 'and no message text');

set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok('select public.delete_my_account()', 'A deletes their account');
reset role;
select is((select count(*)::int from public.feedback where user_id = :'a_id'), 0, 'their feedback is deleted with the account');

-- Nothing was sent: the alerts above sit in the queue of a transaction that is rolled back.
select * from finish();
rollback;

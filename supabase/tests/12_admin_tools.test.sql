-- Admin views, exports and Discord alerts. Fictional data only. Everything runs in a rolled-back
-- transaction, so no alert is ever sent (pg_net only sends committed requests).
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.queued() returns integer language sql as $$ select count(*)::int from net.http_request_queue $$;

select private.qotw_apply('{"current_episode": 2, "questions": [{"episode": 1, "text": "Old fictional question?"}, {"episode": 2, "text": "Open fictional question?"}]}');
insert into private.blocked_terms (term, match_type, category) values ('qwerzoid', 'word', 'profanity');
insert into private.owner_claim (email) values ('owner@example.test');
select pg_temp.new_user('owner@example.test', 'google', true) as owner_id \gset
select pg_temp.new_user('admin@example.test', 'google', true) as admin_id \gset
select pg_temp.new_user('a@example.test', 'google', true) as a_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin');
insert into public.profiles (id, display_name) values (:'a_id', '@everyone **Kat**');
update public.profiles set display_name_changed_at = null;

-- ---------------- alerts ----------------
select is(pg_temp.queued(), 0, 'nothing queued to start with');
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok(format($$insert into public.qotw_answers (episode, user_id, body) values (2, %L, 'A secret fictional answer')$$, :'a_id'),
  'answering works with no webhook configured');
reset role;
select is(pg_temp.queued(), 0, 'with no webhook secret, no alert is queued');

select vault.create_secret('https://example.com/not-a-discord-webhook', 'discord_admin_webhook_url');
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '111222333', 'Fictional goals')$$, :'a_id'),
  'requesting works with a non-Discord URL configured');
reset role;
select is(pg_temp.queued(), 0, 'a URL that is not a Discord webhook is ignored');

select vault.update_secret((select id from vault.decrypted_secrets where name = 'discord_admin_webhook_url'), 'https://discord.com/api/webhooks/1/fictional-token');
set local role authenticated;
select pg_temp.as_user(:'a_id');
select lives_ok($$update public.roster_requests set status = 'closed' where user_id = auth.uid()$$, 'withdrawing sends no alert');
select lives_ok(format($$insert into public.roster_requests (user_id, ally_code, goals) values (%L, '111222333', 'More fictional goals')$$, :'a_id'),
  'a new request with a webhook configured');
reset role;
select is(pg_temp.queued(), 1, 'exactly one alert is queued');
select ok((select url from net.http_request_queue limit 1) like 'https://discord.com/api/webhooks/%', 'it goes to the configured webhook');
select ok((select convert_from(body, 'utf8') from net.http_request_queue limit 1) like '%New roster review request from%', 'it says what was submitted');
select ok((select convert_from(body, 'utf8') from net.http_request_queue limit 1) not like '%More fictional goals%', 'it contains no request details');
select ok((select convert_from(body, 'utf8') from net.http_request_queue limit 1) not like '%example.test%', 'it contains no email address');
select ok((select convert_from(body, 'utf8') from net.http_request_queue limit 1) like '%\\\\@everyone%', 'mentions in names are neutralised');
select ok((select convert_from(body, 'utf8')::jsonb -> 'allowed_mentions' -> 'parse' from net.http_request_queue limit 1) = '[]'::jsonb,
  'and Discord is told not to ping anyone');

-- ---------------- admin views ----------------
set local role authenticated;
select pg_temp.as_user(:'a_id');
select throws_like('select public.admin_answers_export()', '%Only admins%', 'listeners cannot export answers');
select throws_like('select public.admin_roster_requests()', '%Only admins%', 'listeners cannot list requests');
select throws_like('select public.admin_content_counts()', '%Only admins%', 'listeners cannot see counts');
select throws_like('select public.admin_alerts_configured()', '%Only admins%', 'listeners cannot check alerts');
select throws_like('select public.admin_export_everything()', '%Only the owner%', 'listeners cannot export everything');
select pg_temp.as_user(:'admin_id');
select is((select count(*)::int from public.admin_answers_export(2)), 1, 'admins can read answers to the open question');
select is((select count(*)::int from public.admin_roster_requests('open')), 1, 'admins can filter open requests');
select is((select count(*)::int from public.admin_roster_requests()), 2, 'and list all requests');
select ok(not exists (select 1 from public.admin_answers_export() a where a::text like '%example.test%'), 'answer exports contain no email addresses');
select ok(not exists (select 1 from public.admin_roster_requests() r where r::text like '%example.test%'), 'request lists contain no email addresses');
select is(public.admin_alerts_configured(), true, 'admins can see whether alerts are configured');
select ok(public.admin_alerts_configured()::text not like '%discord%', 'but never the webhook URL');
select is((public.admin_content_counts() ->> 'roster_open')::int, 1, 'counts for the overview');
select throws_like('select public.admin_export_everything()', '%Only the owner%', 'admins cannot export everything');
select pg_temp.as_user(:'owner_id');
select ok(public.admin_export_everything() ? 'qotw_answers', 'the owner can export everything');
select ok(public.admin_export_everything()::text not like '%qwerzoid%', 'the export never contains moderation list entries');
select ok(public.admin_export_everything()::text not like '%fictional-token%', 'nor the webhook secret');
reset role;
select ok((select count(*) from public.audit_log where action = 'everything_exported') >= 1, 'exporting everything is audited');

select * from finish();
rollback;

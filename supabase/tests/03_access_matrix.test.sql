-- Row-level security matrix: signed-out visitor, user A, user B, an admin and the owner.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

insert into private.owner_claim (email) values ('owner@example.test');
select pg_temp.new_user('owner@example.test', 'google', true) as owner_id \gset
select pg_temp.new_user('admin@example.test', 'discord', true, '123456789012345678') as admin_id \gset
select pg_temp.new_user('a@example.test', 'google', true) as a_id \gset
select pg_temp.new_user('b@example.test', 'discord', true, '876543210987654321') as b_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin');
insert into public.profiles (id, display_name, ally_code) values (:'a_id', 'Reader A', '123-456-789');
insert into public.profiles (id, display_name) values (:'b_id', 'Reader B');
insert into public.notification_prefs (user_id, episode_alerts) values (:'b_id', true);
insert into public.bans (user_id, reason) values (:'b_id', 'test ban');
insert into public.admin_invites (kind, value) values ('email', 'future@example.test');
insert into public.audit_log (action) values ('test_entry');
insert into private.blocked_terms (term, match_type, category) values ('frak', 'word', 'profanity');

select is((select ally_code from public.profiles where id = :'a_id'), '123456789', 'ally codes are stored as 9 digits');
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public', 'private') and c.relkind = 'r' and not c.relrowsecurity),
  null, 'every table in public and private has row-level security turned on');

-- ---------------- signed-out visitor (anon) ----------------
set local role anon;
select set_config('request.jwt.claims', '{"role": "anon"}', true);
select throws_ok('select count(*) from public.profiles', '42501', null, 'anon cannot read profiles');
select throws_ok('select count(*) from public.notification_prefs', '42501', null, 'anon cannot read notification switches');
select throws_ok('select count(*) from public.user_roles', '42501', null, 'anon cannot read roles');
select throws_ok('select count(*) from public.audit_log', '42501', null, 'anon cannot read the audit log');
select throws_ok('select count(*) from public.bans', '42501', null, 'anon cannot read bans');
select throws_ok('select count(*) from public.admin_invites', '42501', null, 'anon cannot read invites');
select throws_ok($$insert into public.profiles (id) values (gen_random_uuid())$$, '42501', null, 'anon cannot create profiles');
select throws_ok('select count(*) from private.owner_claim', '42501', null, 'anon cannot see the owner claim');
select throws_ok('select public.export_my_data()', '42501', null, 'anon cannot call export_my_data');
select throws_ok('select public.admin_list_accounts()', '42501', null, 'anon cannot list accounts');
select throws_ok('select public.is_admin()', '42501', null, 'anon cannot call is_admin');
select isnt(public.keep_alive(), null, 'anon CAN call keep_alive (used by the scheduled keep-alive)');
reset role;

-- ---------------- user A ----------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'a_id', 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.profiles), 1, 'A sees only their own profile');
select is((select display_name from public.profiles), 'Reader A', 'and it is A''s profile');
select is((select count(*)::int from public.notification_prefs), 0, 'A sees no one else''s switches');
select is((select count(*)::int from public.user_roles), 0, 'A sees no roles (A has none)');
select is((select count(*)::int from public.audit_log), 0, 'A cannot read the audit log');
select is((select count(*)::int from public.bans), 0, 'A sees no bans (A is not banned)');
select is((select count(*)::int from public.admin_invites), 0, 'A cannot see invites');
select throws_ok('select count(*) from private.owner_claim', '42501', null, 'A cannot see the owner claim');
select throws_ok('select count(*) from private.blocked_terms', '42501', null, 'A cannot read the blocked terms');
select throws_ok('select count(*) from private.reserved_names', '42501', null, 'A cannot read the reserved names');
select throws_ok('select count(*) from private.allowed_terms', '42501', null, 'A cannot read the allowlist');

select lives_ok($$update public.profiles set bio = 'Hello' where id = auth.uid()$$, 'A can edit their own profile');
update public.profiles set bio = 'hacked' where id = :'b_id';
select lives_ok($$insert into public.notification_prefs (user_id, qotw_alerts) values (auth.uid(), true)$$, 'A can turn on their own switch');
select throws_ok(format($$insert into public.profiles (id, display_name) values (%L, 'Fake')$$, :'b_id'), '42501', null,
  'A cannot create a profile for B');
select throws_ok(format($$insert into public.notification_prefs (user_id) values (%L)$$, :'owner_id'), '42501', null,
  'A cannot create switches for someone else');
update public.profiles set id = :'b_id' where id = auth.uid();
select is((select count(*)::int from public.profiles where id = auth.uid()), 1,
  'A cannot move their profile onto B''s account (the id is pinned)');
delete from public.profiles where id = :'b_id';
delete from public.notification_prefs where user_id = :'b_id';
select throws_ok(format($$insert into public.user_roles (user_id, role) values (%L, 'admin')$$, :'a_id'), '42501', null,
  'A cannot make themselves admin');
select throws_ok(format($$insert into public.bans (user_id) values (%L)$$, :'b_id'), '42501', null, 'A cannot ban directly');
select throws_ok($$insert into public.audit_log (action) values ('forged')$$, '42501', null, 'A cannot write the audit log');
select throws_ok($$insert into public.admin_invites (kind, value) values ('email', 'x@example.test')$$, '42501', null,
  'A cannot create invites directly');
select throws_like(format('select public.admin_ban(%L)', :'b_id'), '%Only admins%', 'A cannot call admin_ban');
select throws_like('select public.admin_list_accounts()', '%Only admins%', 'A cannot list accounts');
select throws_like(format('select public.admin_grant_admin(%L)', :'a_id'), '%Only the owner%', 'A cannot grant admin');
select throws_like($$select public.admin_add_terms('blocked', array['word'])$$, '%Only admins%', 'A cannot edit the blocked terms');
select throws_like($$select public.admin_test_text('anything')$$, '%Only admins%', 'A cannot use the filter tester');
select throws_like($$select public.admin_lookup_name('anyone')$$, '%Only the owner%', 'A cannot look up who holds a name');
select is(public.is_admin(), false, 'is_admin() is false for A');
select is(public.is_owner(), false, 'is_owner() is false for A');
reset role;
select is((select bio from public.profiles where id = :'b_id'), null, 'B''s profile was not changed by A');
select is((select count(*)::int from public.profiles where id = :'b_id'), 1, 'B''s profile was not deleted by A');
select is((select count(*)::int from public.notification_prefs where user_id = :'b_id'), 1, 'B''s switches were not deleted by A');

-- ---------------- user B (banned) ----------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'b_id', 'role', 'authenticated')::text, true);
select is(public.is_banned(), true, 'B knows they are banned');
select is((select count(*)::int from public.bans), 1, 'B can see their own ban');
select throws_ok($$update public.profiles set bio = 'still here' where id = auth.uid()$$, '42501', null,
  'a banned listener cannot edit their profile');
select throws_ok($$update public.notification_prefs set qotw_alerts = true where user_id = auth.uid()$$, '42501', null,
  'a banned listener cannot change switches');
select is((select count(*)::int from public.profiles), 1, 'a banned listener can still read their own profile');
select ok(public.export_my_data() ? 'profile', 'a banned listener can still download their data');
reset role;

-- ---------------- admin ----------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'admin_id', 'role', 'authenticated')::text, true);
select is(public.is_admin(), true, 'is_admin() is true for an admin');
select is(public.is_owner(), false, 'is_owner() is false for an admin');
select is((select count(*)::int from public.profiles), 2, 'admins can read every profile');
select is((select count(*)::int from public.notification_prefs), 0, 'admins cannot read others'' notification switches');
select is((select count(*)::int from public.user_roles), 2, 'admins see all roles');
select ok((select count(*)::int from public.audit_log) >= 1, 'admins can read the audit log');
select is((select count(*)::int from public.admin_invites), 0, 'only the owner sees invites');
update public.profiles set bio = 'admin edit' where id = :'a_id';
reset role;
select isnt((select bio from public.profiles where id = :'a_id'), 'admin edit',
  'admins cannot edit someone else''s profile directly');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'admin_id', 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.admin_list_accounts()), 4, 'admins can list accounts');
select is((select count(*)::int from public.admin_list_accounts() where email is not null), 0, 'admins do not see email addresses');
select throws_like(format('select public.admin_grant_admin(%L)', :'a_id'), '%Only the owner%', 'admins cannot grant admin');
select throws_like($$select public.admin_create_invite('email', 'x@example.test')$$, '%Only the owner%', 'admins cannot invite admins');
select throws_ok($$update public.audit_log set action = 'edited'$$, '42501', null, 'admins cannot edit the audit log');
select lives_ok(format('select public.admin_ban(%L, %L)', :'a_id', 'spam'), 'admins can ban a listener');
select lives_ok(format('select public.admin_unban(%L)', :'a_id'), 'admins can lift a ban');
reset role;

-- ---------------- owner ----------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_id', 'role', 'authenticated')::text, true);
select is(public.is_owner(), true, 'is_owner() is true for the owner');
select is((select count(*)::int from public.admin_invites), 1, 'the owner sees invites');
select is((select count(*)::int from public.admin_list_accounts() where email is not null), 4, 'the owner sees email addresses');
select is((select count(*)::int from public.notification_prefs), 0, 'even the owner cannot read others'' notification switches');
select throws_ok($$delete from public.audit_log$$, '42501', null, 'even the owner cannot delete audit entries');
select throws_ok(format($$delete from public.bans where user_id = %L$$, :'b_id'), '42501', null,
  'bans change only through the audited functions');
reset role;

select * from finish();
rollback;

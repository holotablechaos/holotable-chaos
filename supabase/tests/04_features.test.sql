-- Admin invites, bans, audit trail, account deletion, data export, rate limits, blocked words.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

insert into private.owner_claim (email) values ('owner@example.test');
select pg_temp.new_user('owner@example.test', 'google', true) as owner_id \gset
select pg_temp.new_user('a@example.test', 'google', true) as a_id \gset
select pg_temp.new_user('existing@example.test', 'discord', true, '765432109876543210') as existing_id \gset

-- ---------------- invites ----------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_id', 'role', 'authenticated')::text, true);
select lives_ok($$select public.admin_create_invite('discord', '112233445566778899')$$, 'the owner invites by Discord id');
select lives_ok($$select public.admin_create_invite('email', ' New.Admin@Example.test ')$$, 'the owner invites by email (normalised)');
select throws_ok($$select public.admin_create_invite('email', 'not-an-email')$$, '23514', null, 'invalid invite values are rejected');
select throws_ok($$select public.admin_create_invite('discord', 'abc')$$, '23514', null, 'Discord ids must be numeric');
-- An invite for someone who already signed in takes effect immediately.
select lives_ok($$select public.admin_create_invite('discord', '765432109876543210')$$, 'invite an existing Discord user');
reset role;
select is(pg_temp.role_of(:'existing_id'), 'admin', 'an existing Discord user becomes admin as soon as they are invited');
select is((select count(*)::int from public.admin_invites), 2, 'the used invite is removed');

select pg_temp.new_user('discord-person@example.test', 'discord', true, '112233445566778899') as invited_discord \gset
select is(pg_temp.role_of(:'invited_discord'), 'admin', 'signing in with the invited Discord id grants admin');

select pg_temp.new_user('new.admin@example.test', 'google', false) as unverified_invitee \gset
select is(pg_temp.role_of(:'unverified_invitee'), null, 'an UNVERIFIED identity with an invited email gets nothing');
select is((select count(*)::int from public.admin_invites where kind = 'email'), 1, 'the email invite is still pending');
update auth.identities set identity_data = identity_data || '{"email_verified": true}'
 where user_id = :'unverified_invitee';
update auth.users set email_confirmed_at = now() where id = :'unverified_invitee';
select is(pg_temp.role_of(:'unverified_invitee'), 'admin', 'once the provider verifies the email, the invite applies');
select is((select count(*)::int from public.admin_invites), 0, 'all invites are used up');
select ok((select count(*) from public.audit_log where action = 'admin_invite_accepted') = 3, 'each accepted invite is audited');

-- ---------------- grant / revoke / ban ----------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_id', 'role', 'authenticated')::text, true);
select lives_ok(format('select public.admin_grant_admin(%L)', :'a_id'), 'the owner grants admin');
select lives_ok(format('select public.admin_revoke_admin(%L)', :'a_id'), 'the owner revokes admin');
select throws_like(format('select public.admin_ban(%L, null, now() - interval %L)', :'a_id', '1 day'), '%future%',
  'a ban cannot end in the past');
select lives_ok(format('select public.admin_ban(%L, %L, now() + interval %L)', :'a_id', 'cool off', '7 days'),
  'the owner can ban for a week');
select lives_ok(format('select public.admin_ban(%L, %L)', :'existing_id', 'admin misbehaving'), 'only the owner can ban an admin');
reset role;
select is((select count(*)::int from public.bans), 2, 'two bans recorded');
select ok((select count(*) from public.audit_log where action in ('admin_granted', 'admin_revoked', 'user_banned')
            and actor_id = :'owner_id') = 4, 'grant, revoke and both bans are audited with the owner as actor');

-- An expired ban no longer applies.
update public.bans set expires_at = now() - interval '1 minute', created_at = now() - interval '8 days' where user_id = :'a_id';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'a_id', 'role', 'authenticated')::text, true);
select is(public.is_banned(), false, 'an expired ban no longer applies');
select lives_ok($$insert into public.profiles (id, display_name) values (auth.uid(), 'Back again')$$, 'and writing works again');
reset role;

-- An admin can't ban another admin.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'invited_discord', 'role', 'authenticated')::text, true);
select throws_like(format('select public.admin_ban(%L)', :'unverified_invitee'), '%Only the owner can ban an admin%',
  'an admin cannot ban another admin');
reset role;

-- ---------------- blocked words and validation ----------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_id', 'role', 'authenticated')::text, true);
select lives_ok($$select public.admin_add_blocked_word('Frak')$$, 'admins can add a blocked word');
select is((select array_agg(w) from public.admin_list_blocked_words() w), array['frak'], 'words are stored lower-case');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'a_id', 'role', 'authenticated')::text, true);
select throws_like($$update public.profiles set display_name = 'Total FRAK up' where id = auth.uid()$$, '%not allowed%',
  'a blocked word in a display name is rejected');
select lives_ok($$update public.profiles set display_name = 'Frakture fan' where id = auth.uid()$$,
  'whole words only: a longer word containing it is fine');
select throws_ok($$update public.profiles set ally_code = '12345' where id = auth.uid()$$, '23514', null, 'ally codes must be 9 digits');
select throws_ok($$update public.profiles set swgoh_gg_url = 'https://evil.example/p/123456789/' where id = auth.uid()$$,
  '23514', null, 'only swgoh.gg profile links are accepted');
select lives_ok($$update public.profiles set swgoh_gg_url = 'https://swgoh.gg/p/123456789/', display_name = '   ' where id = auth.uid()$$,
  'a valid swgoh.gg link is accepted, and a blank name is stored as empty');
select is((select display_name from public.profiles where id = auth.uid()), null, 'blank text is stored as empty (null)');
select lives_ok($$update public.profiles set display_name = null, bio = null, ally_code = null, swgoh_gg_url = null where id = auth.uid()$$,
  'every profile field can be cleared');
reset role;

-- ---------------- rate limit ----------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'a_id', 'role', 'authenticated')::text, true);
select lives_ok($$
  do $do$ begin
    for i in 1..25 loop
      update public.profiles set bio = 'edit ' || i where id = auth.uid();
    end loop;
  end $do$;
$$, 'normal editing stays under the limit');
select throws_like($$
  do $do$ begin
    for i in 1..10 loop
      update public.profiles set bio = 'spam ' || i where id = auth.uid();
    end loop;
  end $do$;
$$, '%Too many changes%', 'more than 30 profile saves an hour is refused');
reset role;

-- ---------------- data export ----------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'a_id', 'role', 'authenticated')::text, true);
select is(public.export_my_data() -> 'account' ->> 'email', 'a@example.test', 'the export includes the account email');
select is(jsonb_array_length(public.export_my_data() -> 'sign_in_methods'), 1, 'the export lists sign-in methods');
select ok(public.export_my_data() ? 'profile', 'the export includes the profile');
select ok(public.export_my_data() -> 'ban' is not null, 'the export includes the (expired) ban record');
select ok(public.export_my_data() -> 'ban' -> 'banned_by' is null, 'without naming which admin banned them');
reset role;

-- An empty account exports cleanly.
select pg_temp.new_user('empty@example.test', 'google', true) as empty_id \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'empty_id', 'role', 'authenticated')::text, true);
select is(public.export_my_data() -> 'profile', 'null'::jsonb, 'an empty profile exports as null, not an error');

-- ---------------- account deletion ----------------
select lives_ok('select public.delete_my_account()', 'a listener can delete their account');
reset role;
select is((select count(*)::int from auth.users where id = :'empty_id'), 0, 'the sign-in is gone');
select is((select count(*)::int from public.audit_log where action = 'account_deleted' and target_id = :'empty_id'), 1,
  'the deletion is audited');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'a_id', 'role', 'authenticated')::text, true);
select lives_ok('select public.delete_my_account()', 'a listener with a profile, switches and a ban can delete their account');
reset role;
select is((select count(*)::int from public.profiles where id = :'a_id'), 0, 'their profile is gone');
select is((select count(*)::int from public.bans where user_id = :'a_id'), 0, 'their ban record is gone');
select is((select count(*)::int from private.rate_limit_hits where user_id = :'a_id'), 0, 'their rate-limit records are gone');
select ok((select count(*) from public.audit_log where target_id = :'a_id') > 0, 'audit entries about them remain');

-- Deleting an admin removes their role too.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'existing_id', 'role', 'authenticated')::text, true);
select lives_ok('select public.delete_my_account()', 'an admin can delete their own account');
reset role;
select is(pg_temp.role_of(:'existing_id'), null, 'their admin role is gone');

-- ---------------- keep-alive ----------------
select ok(public.keep_alive() <= now(), 'keep_alive records a heartbeat');
select is((select count(*)::int from private.heartbeat), 1, 'the heartbeat is a single row');

select * from finish();
rollback;

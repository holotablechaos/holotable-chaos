begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

-- Scenario: the owner signed in BEFORE the claim was recorded; the SQL snippet then claims it.
-- Also covers: one owner only, and the owner can't be removed or demoted from the site.

select pg_temp.new_user('owner@example.test', 'google', true) as early_user \gset
select is(pg_temp.role_of(:'early_user'), null, 'no owner is granted before the claim row exists');

insert into private.owner_claim (email) values ('owner@example.test');
select is(private.try_claim_owner(), :'early_user'::uuid, 'the SQL snippet''s try_claim_owner() grants the earlier verified sign-in');
select is(pg_temp.role_of(:'early_user'), 'owner', 'that account is now owner');
select is((select count(*)::int from public.audit_log where action = 'owner_claimed'), 1, 'the claim is audited');

-- Supabase allows only one account per email address, so a look-alike can't exist;
-- a second verified account (another address) can't become a second owner.
select throws_ok($$select pg_temp.new_user('owner@example.test', 'discord', true, '999999999999999999')$$, '23505', null,
  'Supabase refuses a second account with the owner email');
select pg_temp.new_user('admin@example.test', 'discord', true, '222222222222222222') as second_verified \gset
select is(pg_temp.role_of(:'second_verified'), null, 'a second verified account does not become owner');
select is(private.try_claim_owner(), null, 'try_claim_owner does nothing once an owner exists');
select throws_ok(
  format('insert into public.user_roles (user_id, role) values (%L, %L)', :'second_verified', 'owner'),
  '23505', null, 'the database refuses a second owner row');
select is((select count(*)::int from public.user_roles where role = 'owner'), 1, 'exactly one owner');
select throws_ok($$insert into private.owner_claim (email) values ('else@example.test')$$, '23505', null,
  'a second claim row cannot be added');

-- Owner protection, even for the database's own role.
select throws_like(format('delete from public.user_roles where user_id = %L', :'early_user'),
  '%cannot be removed%', 'the owner row cannot be deleted');
select throws_like(format('update public.user_roles set role = %L where user_id = %L', 'admin', :'early_user'),
  '%cannot be changed%', 'the owner cannot be demoted');
select throws_like(format('delete from auth.users where id = %L', :'early_user'),
  '%cannot be removed%', 'deleting the owner''s sign-in is blocked until ownership is transferred');

-- Signed in as the owner, the site's functions can't remove the owner either.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'early_user', 'role', 'authenticated')::text, true);
select throws_like(format('select public.admin_revoke_admin(%L)', :'early_user'), '%cannot be removed%',
  'admin_revoke_admin refuses to remove the owner');
select throws_like(format('select public.admin_ban(%L)', :'early_user'), '%cannot ban yourself%',
  'the owner cannot ban themselves');
select throws_like('select public.delete_my_account()', '%cannot be deleted%',
  'the owner cannot delete their own account from the site');
select throws_ok('delete from public.user_roles', '42501', null, 'nobody can write user_roles directly');
select throws_ok('select private.try_claim_owner()', '42501', null, 'the site cannot call the private claim function');
select throws_ok(format('select private.transfer_ownership(%L)', :'second_verified'), '42501', null,
  'the site cannot call transfer_ownership');
reset role;
select is(pg_temp.role_of(:'early_user'), 'owner', 'the owner is still owner');

-- An admin can't touch the owner.
insert into public.user_roles (user_id, role) values (:'second_verified', 'admin');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'second_verified', 'role', 'authenticated')::text, true);
select throws_like(format('select public.admin_ban(%L)', :'early_user'), '%owner cannot be banned%',
  'an admin cannot ban the owner');
select throws_like(format('select public.admin_revoke_admin(%L)', :'early_user'), '%Only the owner%',
  'an admin cannot call owner-only functions');
reset role;

-- Ownership moves only by hand in the SQL editor.
select lives_ok(format('select private.transfer_ownership(%L)', :'second_verified'), 'transfer_ownership works from the SQL editor');
select is(pg_temp.role_of(:'second_verified'), 'owner', 'the new owner holds the role');
select is(pg_temp.role_of(:'early_user'), 'admin', 'the previous owner becomes an admin');
select is((select count(*)::int from public.user_roles where role = 'owner'), 1, 'still exactly one owner');
select is(current_setting('app.owner_change_allowed', true), 'off', 'the bypass switch is turned back off');

select * from finish();
rollback;

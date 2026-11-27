begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

-- Scenario: the claim is recorded first; unverified and wrong sign-ins come in, then the real owner.

insert into private.owner_claim (email) values ('owner@example.test');

-- Each look-alike is created on its own (Supabase allows one account per email), checked, then removed.
select pg_temp.new_user('owner@example.test', 'discord', false, '111111111111111111') as lookalike \gset
select is(pg_temp.role_of(:'lookalike'), null, 'an UNVERIFIED Discord sign-up with the owner email is not made owner');
delete from auth.users where id = :'lookalike';

select pg_temp.new_user('owner@example.test', 'google', false) as lookalike \gset
select is(pg_temp.role_of(:'lookalike'), null, 'an UNVERIFIED Google sign-up with the owner email is not made owner');
delete from auth.users where id = :'lookalike';

select pg_temp.new_user('owner@example.test', 'email', true) as lookalike \gset
select is(pg_temp.role_of(:'lookalike'), null, 'a confirmed email/password or magic-link account is never made owner');
delete from auth.users where id = :'lookalike';

-- Provider says verified, but Supabase never confirmed the account.
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'owner@example.test', '{}', '{}', now(), now());
insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
values ('444444444444444444', '00000000-0000-0000-0000-0000000000aa',
        '{"email": "owner@example.test", "email_verified": true}', 'discord', now(), now());
select is(pg_temp.role_of('00000000-0000-0000-0000-0000000000aa'), null, 'an unconfirmed account is not made owner');
delete from auth.users where id = '00000000-0000-0000-0000-0000000000aa';

-- An unverified identity *linked* to someone else's account, carrying the owner email.
select pg_temp.new_user('someone@example.test', 'google', true) as other_user \gset
insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
values ('555555555555555555', :'other_user',
        '{"email": "owner@example.test", "email_verified": false}', 'discord', now(), now());
select is(pg_temp.role_of(:'other_user'), null, 'a linked but UNVERIFIED identity with the owner email gives nothing');
select is((select count(*)::int from public.user_roles), 0, 'no roles at all so far');
select is(private.try_claim_owner(), null, 'running the claim by hand still finds no verified identity');

-- The real owner signs in with a verified Discord email (Supabase confirms the email last).
select pg_temp.new_user('Owner@Example.test', 'discord', true, '333333333333333333', false) as real_owner \gset
select is(pg_temp.role_of(:'real_owner'), 'owner', 'a verified Discord sign-in becomes owner automatically');
select is((select count(*)::int from public.user_roles), 1, 'only the owner role was created');
select is((select count(*)::int from public.profiles), 0, 'no profile row is created at sign-in');
select is((select count(*)::int from public.notification_prefs), 0, 'no notification switches are created at sign-in');

-- Linking Google with the same verified email keeps one owner.
insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values ('google-sub-1', :'real_owner',
        jsonb_build_object('sub', 'google-sub-1', 'email', 'owner@example.test', 'email_verified', true),
        'google', now(), now(), now());
select is((select count(*)::int from public.user_roles where role = 'owner'), 1, 'linking a second sign-in method keeps one owner');
select is(pg_temp.role_of(:'other_user'), null, 'the account with the unverified look-alike identity still has no role');

select * from finish();
rollback;

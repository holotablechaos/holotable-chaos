-- Member cards: display-name fallbacks, avatar choice and safety, who may read them.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

select pg_temp.new_user('d@example.test', 'discord', true, '100000000000000001') as d_id \gset
select pg_temp.new_user('g@example.test', 'google', true) as g_id \gset
select pg_temp.new_user('admin@example.test', 'google', true) as admin_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin');

update auth.identities set identity_data = identity_data || jsonb_build_object(
  'full_name', 'd_username', 'custom_claims', jsonb_build_object('global_name', 'Discord Dee'),
  'avatar_url', 'https://cdn.discordapp.com/avatars/100000000000000001/abc123.png')
 where user_id = :'d_id';
update auth.identities set identity_data = identity_data || jsonb_build_object(
  'full_name', 'Google Gee', 'avatar_url', 'https://lh3.googleusercontent.com/a/photo-id=s96-c')
 where user_id = :'g_id';

-- Names
select is(private.display_name_for(:'d_id'), 'Discord Dee', 'with no profile, the Discord display name is used');
select is(private.display_name_for(:'g_id'), 'Google Gee', 'with no profile, the Google name is used');
select is((select count(*)::int from public.profiles), 0, 'resolving a name never creates a profile');
insert into private.blocked_words (word) values ('frak');
update auth.identities set identity_data = identity_data || '{"full_name": "Frak Lord"}' where user_id = :'g_id';
select is(private.display_name_for(:'g_id'), 'Listener', 'a provider name with a blocked word falls back to Listener');
insert into public.profiles (id, display_name) values (:'g_id', 'Chosen Name');
select is(private.display_name_for(:'g_id'), 'Chosen Name', 'a saved display name always wins');

-- Avatars
select is(private.avatar_url_for(:'d_id'), 'https://cdn.discordapp.com/avatars/100000000000000001/abc123.png',
  'auto picks the Discord picture');
insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
values ('google-d', :'d_id', '{"email": "d@example.test", "email_verified": true, "avatar_url": "https://lh3.googleusercontent.com/a/other"}',
        'google', now(), now());
insert into public.profiles (id, avatar_source) values (:'d_id', 'google');
select is(private.avatar_url_for(:'d_id'), 'https://lh3.googleusercontent.com/a/other', 'the listener can choose the Google picture');
update public.profiles set avatar_source = 'initials' where id = :'d_id';
select is(private.avatar_url_for(:'d_id'), null, 'choosing initials returns no picture');
update public.profiles set avatar_source = 'discord' where id = :'g_id';
select is(private.avatar_url_for(:'g_id'), null, 'choosing a provider you have not linked returns no picture');
select is(private.safe_avatar_url('https://evil.example/a.png'), null, 'pictures from other hosts are never returned');
select is(private.safe_avatar_url('https://cdn.discordapp.com.evil.example/avatars/1/a.png'), null, 'look-alike hosts are refused');
select is(private.safe_avatar_url('javascript:alert(1)'), null, 'non-https values are refused');
select throws_ok($$update public.profiles set avatar_source = 'upload' where id = (select id from public.profiles limit 1)$$,
  '23514', null, 'only discord, google or initials can be chosen');

-- Profile fields
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'d_id', 'role', 'authenticated')::text, true);
select lives_ok($$update public.profiles set in_game_name = 'Holo Dee' where id = auth.uid()$$, 'in-game name can be saved');
select throws_like($$update public.profiles set in_game_name = 'frak master' where id = auth.uid()$$, '%isn''t allowed%',
  'in-game names are filtered');
select throws_ok($$update public.profiles set in_game_name = repeat('x', 41) where id = auth.uid()$$, '23514', null,
  'in-game names are at most 40 characters');
select is(public.my_member_card() ->> 'name', 'Discord Dee', 'my_member_card returns my resolved name');
select ok(public.my_member_card() ? 'member_since', 'my_member_card includes member since');
select throws_like(format('select public.admin_member_cards(array[%L]::uuid[])', :'g_id'), '%Only admins%',
  'listeners cannot look up other people''s cards');
select throws_like('select * from public.admin_list_accounts()', '%Only admins%', 'listeners cannot list accounts');
reset role;

set local role anon;
select throws_ok('select public.my_member_card()', '42501', null, 'signed-out visitors cannot call my_member_card');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'admin_id', 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.admin_member_cards(array[:'d_id', :'g_id']::uuid[])), 2, 'admins can look up cards');
select is((select avatar_url from public.admin_list_accounts() where id = :'d_id'), null,
  'the account list respects the initials choice');
select is((select display_name from public.admin_list_accounts() where id = :'g_id'), 'Chosen Name',
  'the account list shows resolved names');
reset role;

select * from finish();
rollback;

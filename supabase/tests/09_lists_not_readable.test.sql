-- The moderation lists can't be read through the API by anyone, including admins and the owner.
-- FICTIONAL entries only.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir _helpers.psql

-- ---------------- the catalog: which public functions can touch the lists ----------------
select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and pg_get_functiondef(p.oid) ~* '(blocked_terms|allowed_terms|reserved_names|blocked_matches|load_list|masked_patterns)'),
  array['admin_add_terms', 'admin_moderation_counts', 'admin_remove_terms', 'admin_test_text', 'admin_update_terms'],
  'only the five counting/adding/removing/changing/testing functions touch the lists');
select is(
  (select array_agg(distinct format_type(p.prorettype, null) order by format_type(p.prorettype, null))
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('admin_add_terms', 'admin_moderation_counts', 'admin_remove_terms', 'admin_test_text', 'admin_update_terms')),
  array['integer', 'jsonb'], 'and they return only counts or a small JSON summary (no rows, no sets)');
select ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.prokind = 'f' and p.proretset and pg_get_functiondef(p.oid) ~* '(blocked_terms|allowed_terms|reserved_names)'),
  'no public function returns a set built from the lists');
select ok(not exists (select 1 from pg_views where schemaname = 'public' and definition ~* '(blocked_terms|allowed_terms|reserved_names)'),
  'no public view exposes the lists');
select ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.proname in ('admin_list_terms', 'admin_list_blocked_words')),
  'the old list-reading functions are gone');
select ok(not has_schema_privilege('authenticated', 'private', 'usage') and not has_schema_privilege('anon', 'private', 'usage'),
  'signed-in and signed-out roles cannot even use the private schema');

-- ---------------- fictional lists ----------------
insert into private.blocked_terms (term, match_type, category) values
  ('qwerzoid', 'word', 'profanity'), ('blixnatch', 'substring', 'slur'), ('go eat a cactus', 'phrase', 'harassment');
insert into private.allowed_terms (term) values ('Blixnatchington');
insert into private.reserved_names (name, match_type) values ('Flibberty Gib', 'contains');
create temp table secret_words (w text);
insert into secret_words values ('qwerzoid'), ('blixnatch'), ('cactus'), ('blixnatchington'), ('flibberty');
grant select on secret_words to authenticated;

create function pg_temp.leaks(p jsonb) returns boolean language sql as $$
  select exists (select 1 from secret_words where lower(p::text) like '%' || w || '%');
$$;
create function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
declare v_msg text; v_detail text; v_hint text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail, v_hint = pg_exception_hint;
  return concat_ws(' | ', v_msg, v_detail, v_hint);
end;
$$;

insert into private.owner_claim (email) values ('owner@example.test');
select pg_temp.new_user('owner@example.test', 'google', true) as owner_id \gset
select pg_temp.new_user('admin@example.test', 'google', true) as admin_id \gset
insert into public.user_roles (user_id, role) values (:'admin_id', 'admin');

do $$ begin perform 1; end $$;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_id', 'role', 'authenticated')::text, true);

-- Every way the dashboard talks to the lists returns no entry text.
select ok(not pg_temp.leaks(public.admin_moderation_counts()), 'counts contain no entries');
select ok(not pg_temp.leaks(public.admin_test_text('you qwerzoid, go eat a cactus', true)), 'the tester never echoes a matched word');
select is((public.admin_test_text('you qwerzoid') -> 'categories'), '["profanity"]'::jsonb, 'the tester still names the category');
select ok(not pg_temp.leaks(public.admin_test_text('Flibberty Gib', true)), 'nor a reserved name');
select ok(not (public.admin_test_text('x') ? 'normalized') and not (public.admin_test_text('x') ? 'blocked_terms'), 'no normalised copy or term list in the tester output');
select ok(not pg_temp.leaks(to_jsonb(public.admin_add_terms('blocked', array['zigzagoon'], 'word', 'other'))), 'adding returns a count');
select ok(not pg_temp.leaks(public.admin_remove_terms('blocked', array['qwerzoid', 'nope'])), 'removing returns counts only');
select is(public.admin_remove_terms('blocked', array['qwerzoid']), '{"removed": 0, "not_found": 1}'::jsonb, '"not found" is reported as a count');
select ok(not pg_temp.leaks(public.admin_update_terms('blocked', array['blixnatch'], 'word', 'other')), 'changing returns counts only');
select ok(not pg_temp.leaks(public.export_my_data()), 'the owner''s data export contains no entries');
select ok(not pg_temp.leaks((select jsonb_agg(a) from public.admin_list_accounts() a)), 'the account list contains no entries');
select ok(not pg_temp.leaks((select jsonb_agg(c) from public.admin_list_name_exceptions() c)), 'the exception list contains no entries');
select ok(not pg_temp.leaks((select jsonb_agg(l) from public.audit_log l)), 'no audit entry contains an entry');

-- Error messages never echo the input.
select ok(pg_temp.error_of($$select public.admin_add_terms('blocked', array[repeat('qwerzoid', 20)])$$) not like '%qwerzoid%',
  'a too-long entry is refused without echoing it');
select ok(pg_temp.error_of($$select public.admin_add_terms('blocked', array['qwerzoid'], 'bogus')$$) not like '%qwerzoid%',
  'a bad match type is refused without echoing the entry');
select ok(pg_temp.error_of($$select public.admin_update_terms('allowed', array['Blixnatchington'], 'word')$$) not like '%lixnatch%',
  'a bad list change is refused without echoing the entry');

-- Direct reads are refused for admins and the owner.
select throws_ok('select count(*) from private.blocked_terms', '42501', null, 'the owner cannot read blocked terms directly');
select throws_ok('select count(*) from private.allowed_terms', '42501', null, 'nor the allowlist');
select throws_ok('select count(*) from private.reserved_names', '42501', null, 'nor reserved names');
select throws_ok($$select * from private.blocked_matches('qwerzoid')$$, '42501', null, 'nor call the internal matcher');
select set_config('request.jwt.claims', json_build_object('sub', :'admin_id', 'role', 'authenticated')::text, true);
select throws_ok('select count(*) from private.blocked_terms', '42501', null, 'an admin cannot read blocked terms directly');
select ok(not pg_temp.leaks(public.admin_test_text('blixnatchy qwerzoid')), 'an admin''s tester output has no entries');
reset role;

select * from finish();
rollback;

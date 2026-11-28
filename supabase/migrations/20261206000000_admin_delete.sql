-- Admins (and the owner) can permanently delete a QotW answer or a roster review request.
--
-- Listeners still can't delete anything (no delete grants or policies are added). Each delete is
-- audited in the same transaction with the account, the episode or request id and status, never
-- the deleted text. Deleting an answer removes its upvotes (foreign key cascade); stats and streaks
-- are computed from the remaining answers. Deleting an open request frees the one-open slot.
-- No Discord alert is sent and nobody is notified. These functions touch only their own table.

create function public.admin_delete_answer(p_answer uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_episode integer;
  v_user uuid;
begin
  perform private.require_admin();
  select episode, user_id into v_episode, v_user from public.qotw_answers where id = p_answer;
  if v_episode is null then
    raise exception 'No answer with that id.' using errcode = 'P0001';
  end if;
  delete from public.qotw_answers where id = p_answer;  -- upvotes go with it (on delete cascade)
  perform private.audit('answer_deleted', v_user, jsonb_build_object('answer_id', p_answer, 'episode', v_episode));
end;
$$;

create function public.admin_delete_roster_request(p_request uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_status text;
  v_user uuid;
begin
  perform private.require_admin();
  select status, user_id into v_status, v_user from public.roster_requests where id = p_request;
  if v_status is null then
    raise exception 'No request with that id.' using errcode = 'P0001';
  end if;
  delete from public.roster_requests where id = p_request;
  perform private.audit('roster_request_deleted', v_user, jsonb_build_object('request_id', p_request, 'status', v_status));
end;
$$;

-- Export everything: leave out empty values instead of writing them as null (otherwise unchanged).
create or replace function public.admin_export_everything() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_result jsonb;
begin
  perform private.require_owner();
  v_result := jsonb_build_object(
    'exported_at', now(),
    'note', 'Everything the site stores, except the moderation lists, which are never exported.',
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at,
        'last_sign_in_at', u.last_sign_in_at,
        'sign_in_methods', (select coalesce(jsonb_agg(i.provider order by i.provider), '[]'::jsonb) from auth.identities i where i.user_id = u.id))
        order by u.created_at) from auth.users u where u.deleted_at is null), '[]'::jsonb),
    'profiles', coalesce((select jsonb_agg(to_jsonb(p) - 'display_name_key') from public.profiles p), '[]'::jsonb),
    'notification_switches', coalesce((select jsonb_agg(to_jsonb(n)) from public.notification_prefs n), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(to_jsonb(r)) from public.user_roles r), '[]'::jsonb),
    'bans', coalesce((select jsonb_agg(to_jsonb(b)) from public.bans b), '[]'::jsonb),
    'admin_invites', coalesce((select jsonb_agg(to_jsonb(i)) from public.admin_invites i), '[]'::jsonb),
    'reserved_name_exceptions', coalesce((select jsonb_agg(jsonb_build_object('user_id', e.user_id, 'note', e.note, 'created_at', e.created_at))
        from private.name_exceptions e), '[]'::jsonb),
    'qotw_questions', coalesce((select jsonb_agg(to_jsonb(q) order by q.episode) from public.qotw_questions q), '[]'::jsonb),
    'qotw_answers', coalesce((select jsonb_agg(to_jsonb(a) order by a.episode, a.created_at) from public.qotw_answers a), '[]'::jsonb),
    'qotw_votes', coalesce((select jsonb_agg(to_jsonb(v)) from public.qotw_answer_votes v), '[]'::jsonb),
    'roster_requests', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from public.roster_requests r), '[]'::jsonb),
    'audit_log', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at) from public.audit_log l), '[]'::jsonb));
  perform private.audit('everything_exported', null);
  return jsonb_strip_nulls(v_result);  -- missing values are left out rather than written as null
end;
$$;

revoke execute on function public.admin_delete_answer(uuid), public.admin_delete_roster_request(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_answer(uuid), public.admin_delete_roster_request(uuid) to authenticated;

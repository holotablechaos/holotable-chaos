-- General questions & feedback sent with an account (the email route stays for everyone).
--
-- Statuses: received, read, resolved, archived. Like roster requests, a listener can edit their own
-- message only while it is "received"; after that only admins change it (audited). Nobody else can
-- read a message: only its sender and admins. Messages are deleted with the account. The filter,
-- the 1000-character guard (messages are capped at 1000 characters), rate limits and bans apply.
-- New messages post a Discord admin alert with only the message type and display name.

create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  message_type text not null
    check (message_type in ('General Question', 'Podcast Feedback', 'Website Feedback', 'Suggestion', 'Other')),
  subject text not null check (char_length(subject) between 1 and 180),
  message text not null check (char_length(message) between 1 and 1000),
  status text not null default 'received' check (status in ('received', 'read', 'resolved', 'archived')),
  status_changed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index feedback_status on public.feedback (status, created_at);
create index feedback_user on public.feedback (user_id, created_at desc);

create function private.before_feedback_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_admin_change boolean := coalesce(current_setting('app.feedback_admin_change', true), '') = 'on';
begin
  new.subject := btrim(new.subject);
  new.message := btrim(new.message);
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.status := 'received';
    end if;
    new.status_changed_at := now();
    new.created_at := now();
  else
    new.id := old.id;
    new.user_id := old.user_id;
    new.created_at := old.created_at;
    if not v_admin_change and auth.uid() is not null then
      if old.status <> 'received' then
        raise exception 'The crew has already seen this message, so it can no longer be changed.'
          using errcode = 'P0001', hint = 'feedback_locked';
      end if;
      new.status := old.status;  -- listeners edit the text only
    end if;
    if new.status is distinct from old.status then
      new.status_changed_at := now();
    else
      new.status_changed_at := old.status_changed_at;
    end if;
  end if;
  if not v_admin_change then
    if private.contains_blocked_word(new.subject) or private.contains_blocked_word(new.message) then
      raise exception 'That text isn''t allowed. Please reword it.' using errcode = 'P0001', hint = 'blocked_text';
    end if;
    perform private.enforce_rate_limit('feedback', 10, interval '1 hour');
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger before_feedback_write before insert or update on public.feedback
  for each row execute function private.before_feedback_write();

create function private.after_feedback_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.notify_admins(format('New %s from %s. Review: https://holotablechaos.com/admin/index.html#feedback',
    private.discord_plain(lower(new.message_type)), private.discord_plain(private.display_name_for(new.user_id))));
  return null;
end;
$$;
create trigger after_feedback_insert after insert on public.feedback
  for each row execute function private.after_feedback_insert();

alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;
grant select, insert, update on public.feedback to authenticated;

create policy "Read your own feedback; admins read all" on public.feedback for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
create policy "Send feedback unless banned" on public.feedback for insert to authenticated
  with check (user_id = (select auth.uid()) and not (select public.is_banned()));
create policy "Edit your own new feedback unless banned" on public.feedback for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and not (select public.is_banned()));
-- No delete policy: messages go away with the account, or when an admin deletes them (audited).

-- Admin functions ---------------------------------------------------------------------------------
create function public.admin_feedback(p_status text default null)
returns setof jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return query
    select jsonb_build_object(
             'id', f.id, 'author', private.member_card(f.user_id), 'message_type', f.message_type, 'subject', f.subject,
             'message', f.message, 'status', f.status, 'created_at', f.created_at, 'updated_at', f.updated_at,
             'status_changed_at', f.status_changed_at)
      from public.feedback f
     where p_status is null or f.status = p_status
            or (p_status = 'open' and f.status in ('received', 'read'))
     order by (f.status in ('received', 'read')) desc, f.created_at desc;
end;
$$;

create function public.admin_set_feedback_status(p_feedback uuid, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_old text;
  v_user uuid;
begin
  perform private.require_admin();
  if p_status is null or p_status not in ('received', 'read', 'resolved', 'archived') then
    raise exception 'Unknown status.' using errcode = 'P0001';
  end if;
  select status, user_id into v_old, v_user from public.feedback where id = p_feedback;
  if v_old is null then
    raise exception 'No message with that id.' using errcode = 'P0001';
  end if;
  perform set_config('app.feedback_admin_change', 'on', true);
  update public.feedback set status = p_status where id = p_feedback;
  perform set_config('app.feedback_admin_change', 'off', true);
  perform private.audit('feedback_status_changed', v_user,
    jsonb_build_object('feedback_id', p_feedback, 'from', v_old, 'to', p_status));
end;
$$;

create function public.admin_delete_feedback(p_feedback uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_row record;
begin
  perform private.require_admin();
  select status, user_id, message_type into v_row from public.feedback where id = p_feedback;
  if v_row.status is null then
    raise exception 'No message with that id.' using errcode = 'P0001';
  end if;
  delete from public.feedback where id = p_feedback;
  perform private.audit('feedback_deleted', v_row.user_id,
    jsonb_build_object('feedback_id', p_feedback, 'type', v_row.message_type, 'status', v_row.status));
end;
$$;

create or replace function public.admin_content_counts()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return jsonb_build_object(
    'answers', (select count(*) from public.qotw_answers),
    'answers_open_question', (select count(*) from public.qotw_answers a join public.qotw_questions q on q.episode = a.episode where q.closed_at is null),
    'roster_open', (select count(*) from public.roster_requests where status in ('received', 'queued', 'reviewed')),
    'roster_received', (select count(*) from public.roster_requests where status = 'received'),
    'feedback_received', (select count(*) from public.feedback where status = 'received'));
end;
$$;

-- Exports -------------------------------------------------------------------------------------------
create or replace function public.export_my_data()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_signed_in();
begin
  return jsonb_build_object(
    'exported_at', now(),
    'account', (select jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at)
                  from auth.users u where u.id = v_uid),
    'sign_in_methods', coalesce((select jsonb_agg(jsonb_build_object('provider', i.provider, 'email', i.identity_data ->> 'email',
                                       'linked_at', i.created_at) order by i.created_at) from auth.identities i where i.user_id = v_uid), '[]'::jsonb),
    'profile', (select to_jsonb(p) - 'display_name_key' from public.profiles p where p.id = v_uid),
    'notification_switches', (select to_jsonb(n) from public.notification_prefs n where n.user_id = v_uid),
    'role', (select r.role from public.user_roles r where r.user_id = v_uid),
    'reserved_name_exception', exists (select 1 from private.name_exceptions e where e.user_id = v_uid),
    'ban', (select to_jsonb(b) - 'banned_by' from public.bans b where b.user_id = v_uid),
    'qotw_answers', coalesce((select jsonb_agg(jsonb_build_object('episode', a.episode, 'answer', a.body, 'created_at', a.created_at,
                                     'updated_at', a.updated_at, 'featured', a.featured_at is not null) order by a.episode)
                                from public.qotw_answers a where a.user_id = v_uid), '[]'::jsonb),
    'qotw_votes', coalesce((select jsonb_agg(jsonb_build_object('answer_id', v.answer_id, 'created_at', v.created_at))
                              from public.qotw_answer_votes v where v.user_id = v_uid), '[]'::jsonb),
    'roster_requests', coalesce((select jsonb_agg(to_jsonb(r) - 'user_id' order by r.created_at)
                                   from public.roster_requests r where r.user_id = v_uid), '[]'::jsonb),
    'feedback', coalesce((select jsonb_agg(to_jsonb(f) - 'user_id' order by f.created_at)
                            from public.feedback f where f.user_id = v_uid), '[]'::jsonb),
    'audit_entries_about_you', coalesce((select jsonb_agg(jsonb_build_object('at', a.created_at, 'action', a.action) order by a.created_at)
                                           from public.audit_log a where a.target_id = v_uid or a.actor_id = v_uid), '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_export_everything()
returns jsonb language plpgsql security definer set search_path = '' as $$
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
    'feedback', coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at) from public.feedback f), '[]'::jsonb),
    'audit_log', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at) from public.audit_log l), '[]'::jsonb));
  perform private.audit('everything_exported', null);
  return jsonb_strip_nulls(v_result);
end;
$$;

-- Only signed-in callers; each function checks the role itself.
revoke all on function public.admin_feedback(text) from public, anon;
revoke all on function public.admin_set_feedback_status(uuid, text) from public, anon;
revoke all on function public.admin_delete_feedback(uuid) from public, anon;
grant execute on function public.admin_feedback(text) to authenticated;
grant execute on function public.admin_set_feedback_status(uuid, text) to authenticated;
grant execute on function public.admin_delete_feedback(uuid) to authenticated;
revoke all on function private.before_feedback_write() from public, anon, authenticated;
revoke all on function private.after_feedback_insert() from public, anon, authenticated;

-- Phase 2, task 5: roster review requests from signed-in listeners. No uploads or screenshots.
--
-- Statuses: received, queued, reviewed (open) and aired, declined, closed (finished). One open
-- request per account, enforced by a partial unique index. Listeners can edit or withdraw a request
-- while it is "received"; after that only admins change it (audited). Requests are deleted with
-- the account. The filter, rate limits and bans apply to the text fields.

create table public.roster_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  ally_code text not null check (ally_code ~ '^[0-9]{9}$'),                                   -- self-reported
  swgoh_gg_url text check (swgoh_gg_url is null or swgoh_gg_url ~ '^https://swgoh\.gg/p/[0-9]{9}/?$'), -- self-reported
  in_game_name text check (in_game_name is null or char_length(in_game_name) between 1 and 40),
  goals text not null check (char_length(goals) between 1 and 1000),
  current_projects text check (current_projects is null or char_length(current_projects) <= 1000),
  status text not null default 'received'
    check (status in ('received', 'queued', 'reviewed', 'aired', 'declined', 'closed')),
  aired_episode integer check (aired_episode is null or aired_episode > 0),
  status_changed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint roster_aired_needs_episode check (status <> 'aired' or aired_episode is not null)
);
create unique index roster_requests_one_open on public.roster_requests (user_id)
  where status in ('received', 'queued', 'reviewed');
create index roster_requests_status on public.roster_requests (status, created_at);

create function private.before_roster_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_admin_change boolean := coalesce(current_setting('app.roster_admin_change', true), '') = 'on';
begin
  new.ally_code := regexp_replace(coalesce(new.ally_code, ''), '[^0-9]', '', 'g');
  new.swgoh_gg_url := nullif(btrim(new.swgoh_gg_url), '');
  new.in_game_name := nullif(btrim(new.in_game_name), '');
  new.goals := btrim(new.goals);
  new.current_projects := nullif(btrim(new.current_projects), '');
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.status := 'received';
      new.aired_episode := null;
    end if;
    new.status_changed_at := now();
    new.created_at := now();
  else
    new.id := old.id;
    new.user_id := old.user_id;
    new.created_at := old.created_at;
    if not v_admin_change and auth.uid() is not null then
      if old.status <> 'received' then
        raise exception 'This request is already with the crew, so it can no longer be changed.'
          using errcode = 'P0001', hint = 'request_locked';
      end if;
      -- A listener may only edit the text, or withdraw (received -> closed).
      if new.status not in ('received', 'closed') then
        new.status := old.status;
      end if;
      new.aired_episode := old.aired_episode;
    end if;
    if new.status is distinct from old.status then
      new.status_changed_at := now();
    else
      new.status_changed_at := old.status_changed_at;
    end if;
  end if;
  if not v_admin_change then
    if not private.name_allowed(new.user_id, coalesce(new.in_game_name, 'ok'))
       or private.contains_blocked_word(new.goals) or private.contains_blocked_word(new.current_projects) then
      raise exception 'That text isn''t allowed. Please reword it.' using errcode = 'P0001', hint = 'blocked_text';
    end if;
    perform private.enforce_rate_limit('roster_request', 10, interval '1 hour');
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger before_roster_write before insert or update on public.roster_requests
  for each row execute function private.before_roster_write();

alter table public.roster_requests enable row level security;
revoke all on public.roster_requests from anon, authenticated;
grant select, insert, update on public.roster_requests to authenticated;

create policy "Read your own requests; admins read all" on public.roster_requests for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
create policy "Request a review unless banned" on public.roster_requests for insert to authenticated
  with check (user_id = (select auth.uid()) and not (select public.is_banned()));
create policy "Edit or withdraw your own request unless banned" on public.roster_requests for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and not (select public.is_banned()));
-- No delete policy: requests go away only with the account.

-- Admins move requests through the statuses. Audited.
create function public.admin_set_roster_status(p_request uuid, p_status text, p_aired_episode integer default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_old text;
  v_user uuid;
begin
  perform private.require_admin();
  if p_status not in ('received', 'queued', 'reviewed', 'aired', 'declined', 'closed') then
    raise exception 'Unknown status.';
  end if;
  if p_status = 'aired' and (p_aired_episode is null or p_aired_episode < 1) then
    raise exception 'Enter the episode number the review aired in.';
  end if;
  select status, user_id into v_old, v_user from public.roster_requests where id = p_request;
  if v_old is null then
    raise exception 'No request with that id.';
  end if;
  perform set_config('app.roster_admin_change', 'on', true);
  update public.roster_requests
     set status = p_status, aired_episode = case when p_status = 'aired' then p_aired_episode end
   where id = p_request;
  perform set_config('app.roster_admin_change', 'off', true);
  perform private.audit('roster_status_changed', v_user,
    jsonb_build_object('request_id', p_request, 'from', v_old, 'to', p_status, 'aired_episode', p_aired_episode));
end;
$$;

-- Data export now includes roster requests.
create or replace function public.export_my_data() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
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
    'ban', (select to_jsonb(b) - 'banned_by' from public.bans b where b.user_id = v_uid),
    'qotw_answers', coalesce((select jsonb_agg(jsonb_build_object('episode', a.episode, 'answer', a.body, 'created_at', a.created_at,
                                     'updated_at', a.updated_at, 'featured', a.featured_at is not null) order by a.episode)
                                from public.qotw_answers a where a.user_id = v_uid), '[]'::jsonb),
    'qotw_votes', coalesce((select jsonb_agg(jsonb_build_object('answer_id', v.answer_id, 'created_at', v.created_at))
                              from public.qotw_answer_votes v where v.user_id = v_uid), '[]'::jsonb),
    'roster_requests', coalesce((select jsonb_agg(to_jsonb(r) - 'user_id' order by r.created_at)
                                   from public.roster_requests r where r.user_id = v_uid), '[]'::jsonb),
    'audit_entries_about_you', coalesce((select jsonb_agg(jsonb_build_object('at', a.created_at, 'action', a.action) order by a.created_at)
                                           from public.audit_log a where a.target_id = v_uid or a.actor_id = v_uid), '[]'::jsonb)
  );
end;
$$;

revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.admin_set_roster_status(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.admin_set_roster_status(uuid, text, integer) to authenticated;

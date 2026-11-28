-- Phase 2, task 6: admin views and exports, and Discord alerts for new submissions.
--
-- Discord alerts: a webhook URL stored in Supabase Vault under the name
-- 'discord_admin_webhook_url' (entered by the owner in the dashboard; never in the repo). When it
-- isn't set, alerts are skipped quietly. Alerts never block a submission and contain no answer
-- text, request details or email addresses, only what was submitted and the person's display name.
-- Exports never include the moderation lists.

-- ---------------------------------------------------------------------------
-- Alerts
-- ---------------------------------------------------------------------------
create function private.notify_admins(p_message text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_url text;
begin
  begin
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'discord_admin_webhook_url' limit 1;
  exception when others then
    v_url := null;
  end;
  if v_url is null or v_url !~ '^https://(discord\.com|discordapp\.com|ptb\.discord\.com|canary\.discord\.com)/api/webhooks/' then
    return;  -- not configured (or not a Discord webhook): skip quietly
  end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('content', left(p_message, 1900), 'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb)),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 10000);
exception when others then
  raise warning 'Discord admin alert skipped: %', sqlerrm;  -- never block the submission
end;
$$;

-- Display names can contain Discord markdown; neutralise it so alerts read as plain text.
create function private.discord_plain(p text) returns text
language sql immutable set search_path = '' as $$
  select regexp_replace(coalesce(p, ''), '([*_~`|>#\[\]()@<:\\])', '\\\1', 'g');
$$;

create function private.after_answer_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.notify_admins(format('New Question of the Week answer on QotW #%s from %s. Review: https://holotablechaos.com/admin/index.html#qotw',
    new.episode, private.discord_plain(private.display_name_for(new.user_id))));
  return null;
end;
$$;
create trigger after_answer_insert after insert on public.qotw_answers
  for each row execute function private.after_answer_insert();

create function private.after_roster_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.notify_admins(format('New roster review request from %s. Review: https://holotablechaos.com/admin/index.html#roster',
    private.discord_plain(private.display_name_for(new.user_id))));
  return null;
end;
$$;
create trigger after_roster_insert after insert on public.roster_requests
  for each row execute function private.after_roster_insert();

-- Whether alerts are configured (admins see a note on the dashboard). Never returns the URL.
create function public.admin_alerts_configured() returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_found boolean;
begin
  perform private.require_admin();
  begin
    select exists (select 1 from vault.decrypted_secrets where name = 'discord_admin_webhook_url'
                    and decrypted_secret ~ '^https://(discord\.com|discordapp\.com|ptb\.discord\.com|canary\.discord\.com)/api/webhooks/')
      into v_found;
  exception when others then
    v_found := false;
  end;
  return v_found;
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin views and CSV sources (no email addresses)
-- ---------------------------------------------------------------------------
create function public.admin_answers_export(p_episode integer default null) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return query
    select jsonb_build_object(
             'id', a.id, 'episode', a.episode, 'question', q.question, 'open', q.closed_at is null,
             'author', private.answer_card(a.user_id), 'answer', a.body, 'featured', a.featured_at is not null,
             'votes', (select count(*) from public.qotw_answer_votes v where v.answer_id = a.id),
             'created_at', a.created_at, 'updated_at', a.updated_at)
      from public.qotw_answers a join public.qotw_questions q on q.episode = a.episode
     where p_episode is null or a.episode = p_episode
     order by a.episode desc, (a.featured_at is not null) desc, a.created_at;
end;
$$;

create function public.admin_roster_requests(p_status text default null) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return query
    select jsonb_build_object(
             'id', r.id, 'author', private.member_card(r.user_id), 'ally_code', r.ally_code, 'swgoh_gg_url', r.swgoh_gg_url,
             'in_game_name', r.in_game_name, 'goals', r.goals, 'current_projects', r.current_projects, 'status', r.status,
             'aired_episode', r.aired_episode, 'created_at', r.created_at, 'status_changed_at', r.status_changed_at)
      from public.roster_requests r
     where p_status is null or r.status = p_status
            or (p_status = 'open' and r.status in ('received', 'queued', 'reviewed'))
     order by (r.status in ('received', 'queued', 'reviewed')) desc, r.created_at;
end;
$$;

create function public.admin_content_counts() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return jsonb_build_object(
    'answers', (select count(*) from public.qotw_answers),
    'answers_open_question', (select count(*) from public.qotw_answers a join public.qotw_questions q on q.episode = a.episode where q.closed_at is null),
    'roster_open', (select count(*) from public.roster_requests where status in ('received', 'queued', 'reviewed')),
    'roster_received', (select count(*) from public.roster_requests where status = 'received'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Owner: export everything (never the moderation lists). Audited.
-- ---------------------------------------------------------------------------
create function public.admin_export_everything() returns jsonb
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
  return v_result;
end;
$$;

revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.admin_alerts_configured(), public.admin_answers_export(integer), public.admin_roster_requests(text),
  public.admin_content_counts(), public.admin_export_everything() from public, anon, authenticated;
grant execute on function public.admin_alerts_configured(), public.admin_answers_export(integer), public.admin_roster_requests(text),
  public.admin_content_counts(), public.admin_export_everything() to authenticated;

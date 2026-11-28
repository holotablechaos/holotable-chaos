-- Phase 2, task 4: Question of the Week answers on the site.
--
-- Questions are public and come from the published site (community/qotw.json, written by
-- scripts/build_qotw.py). An hourly job fetches that file and keeps public.qotw_questions in step:
-- the current question is open, every other one is closed. Nothing personal is stored in the repo.
--
-- Answers: one per listener per question, editable while the question is open, never individually
-- deletable. Other listeners can read them only after the question closes. When an account is
-- deleted its answers stay, anonymised as "Deleted listener"; its votes are removed.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------
-- Questions (public, written only by the sync)
-- ---------------------------------------------------------------------------
create table public.qotw_questions (
  episode integer primary key check (episode > 0),
  episode_title text check (char_length(episode_title) <= 300),
  question text not null check (char_length(question) between 1 and 600),
  published_at timestamptz,
  opened_at timestamptz,
  closed_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.qotw_questions enable row level security;
revoke all on public.qotw_questions from anon, authenticated;
grant select on public.qotw_questions to anon, authenticated;
create policy "Questions are public" on public.qotw_questions for select to anon, authenticated using (true);

create table private.qotw_fetches (
  request_id bigint primary key,
  requested_at timestamptz not null default now(),
  processed_at timestamptz,
  status integer,
  result jsonb
);
alter table private.qotw_fetches enable row level security;
revoke all on private.qotw_fetches from public, anon, authenticated;

-- Apply a published feed: {"schema": 1, "current_episode": 23, "questions": [{episode, episode_title, text, published_at}]}
create function private.qotw_apply(p_feed jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_current integer := nullif(p_feed ->> 'current_episode', '')::integer;
  v_item jsonb;
  v_count integer := 0;
begin
  if jsonb_typeof(p_feed -> 'questions') <> 'array' or jsonb_array_length(p_feed -> 'questions') > 1000 then
    raise exception 'The question feed is not in the expected format.';
  end if;
  for v_item in select * from jsonb_array_elements(p_feed -> 'questions') loop
    continue when (v_item ->> 'episode') !~ '^[0-9]{1,5}$' or nullif(btrim(v_item ->> 'text'), '') is null
               or char_length(v_item ->> 'text') > 600;
    insert into public.qotw_questions as q (episode, episode_title, question, published_at, opened_at, closed_at, updated_at)
    values ((v_item ->> 'episode')::integer, left(v_item ->> 'episode_title', 300), btrim(v_item ->> 'text'),
            case when (v_item ->> 'published_at') ~ '^\d{4}-\d{2}-\d{2}' then (v_item ->> 'published_at')::timestamptz end,
            now(), case when (v_item ->> 'episode')::integer = v_current then null else now() end, now())
    on conflict (episode) do update
      set episode_title = excluded.episode_title, question = excluded.question, published_at = excluded.published_at,
          opened_at = coalesce(q.opened_at, excluded.opened_at),
          closed_at = case when q.episode = v_current then null else coalesce(q.closed_at, now()) end,
          updated_at = now();
    v_count := v_count + 1;
  end loop;
  -- Anything else that is still open closes (the rotation moved on, or there is no open question).
  update public.qotw_questions set closed_at = now(), updated_at = now()
   where closed_at is null and episode is distinct from v_current;
  return jsonb_build_object('questions', v_count, 'open', v_current);
end;
$$;

-- Hourly: apply any fetched feed, then request the latest one.
create function private.qotw_sync_tick() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_row record;
  v_result jsonb := '{}'::jsonb;
begin
  for v_row in
    select r.id, r.status_code, r.content
      from net._http_response r join private.qotw_fetches f on f.request_id = r.id
     where f.processed_at is null order by r.id
  loop
    begin
      if v_row.status_code = 200 then
        v_result := private.qotw_apply(v_row.content::jsonb);
      else
        v_result := jsonb_build_object('http_status', v_row.status_code);
      end if;
    exception when others then
      v_result := jsonb_build_object('error', left(sqlerrm, 200));
    end;
    update private.qotw_fetches set processed_at = now(), status = v_row.status_code, result = v_result where request_id = v_row.id;
  end loop;
  insert into private.qotw_fetches (request_id)
  values (net.http_get(url := 'https://holotablechaos.com/community/qotw.json?t=' || extract(epoch from now())::bigint,
                       timeout_milliseconds := 15000));
  delete from private.qotw_fetches where requested_at < now() - interval '14 days';
  return v_result;
end;
$$;

select cron.schedule('qotw-sync', '11 * * * *', 'select private.qotw_sync_tick()');

-- ---------------------------------------------------------------------------
-- Answers and votes
-- ---------------------------------------------------------------------------
create table public.qotw_answers (
  id uuid primary key default gen_random_uuid(),
  episode integer not null references public.qotw_questions (episode),
  user_id uuid references auth.users (id) on delete set null,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  featured_at timestamptz,
  featured_by uuid,
  unique (episode, user_id)
);
create index qotw_answers_user on public.qotw_answers (user_id);

create table public.qotw_answer_votes (
  answer_id uuid not null references public.qotw_answers (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (answer_id, user_id)
);
create index qotw_answer_votes_user on public.qotw_answer_votes (user_id);

-- Public helpers (whether a question is open is public information); used by the policies below.
create function public.qotw_is_open(p_episode integer) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.qotw_questions where episode = p_episode and closed_at is null);
$$;
create function public.qotw_is_closed(p_episode integer) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.qotw_questions where episode = p_episode and closed_at is not null);
$$;

create function private.before_answer_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Account deletion anonymises answers (foreign key ON DELETE SET NULL): let exactly that through.
  if tg_op = 'UPDATE' and old.user_id is not null and new.user_id is null
     and new.body is not distinct from old.body and new.episode = old.episode then
    return new;
  end if;
  new.body := btrim(new.body);
  if tg_op = 'UPDATE' then
    new.id := old.id;
    new.episode := old.episode;
    new.user_id := old.user_id;
    new.created_at := old.created_at;
    if coalesce(current_setting('app.feature_change', true), '') <> 'on' then
      new.featured_at := old.featured_at;
      new.featured_by := old.featured_by;
    end if;
  else
    new.featured_at := null;
    new.featured_by := null;
  end if;
  if coalesce(current_setting('app.feature_change', true), '') <> 'on' then
    if auth.uid() is not null and not public.qotw_is_open(new.episode) then
      raise exception 'This question is closed, so answers can no longer be changed.' using errcode = 'P0001', hint = 'question_closed';
    end if;
    if private.contains_blocked_word(new.body) then
      raise exception 'That text isn''t allowed. Please reword it.' using errcode = 'P0001', hint = 'blocked_text';
    end if;
    new.updated_at := now();
    perform private.enforce_rate_limit('qotw_answer', 20, interval '1 hour');
  end if;
  return new;
end;
$$;
create trigger before_answer_write before insert or update on public.qotw_answers
  for each row execute function private.before_answer_write();

create function private.before_vote_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_answer record;
begin
  select a.episode, a.user_id into v_answer from public.qotw_answers a where a.id = new.answer_id;
  if v_answer is null or not public.qotw_is_closed(v_answer.episode) then
    raise exception 'You can vote once a question has closed.' using errcode = 'P0001', hint = 'question_open';
  end if;
  if v_answer.user_id = new.user_id then
    raise exception 'You can''t vote for your own answer.' using errcode = 'P0001', hint = 'own_answer';
  end if;
  perform private.enforce_rate_limit('qotw_vote', 120, interval '1 hour');
  return new;
end;
$$;
create trigger before_vote_write before insert on public.qotw_answer_votes
  for each row execute function private.before_vote_write();

alter table public.qotw_answers enable row level security;
alter table public.qotw_answer_votes enable row level security;
revoke all on public.qotw_answers, public.qotw_answer_votes from anon, authenticated;
grant select, insert, update on public.qotw_answers to authenticated;
grant select, insert, delete on public.qotw_answer_votes to authenticated;

create policy "Read your own answers, everyone's once closed; admins read all"
  on public.qotw_answers for select to authenticated
  using (user_id = (select auth.uid()) or public.qotw_is_closed(episode) or (select public.is_admin()));
create policy "Answer an open question unless banned"
  on public.qotw_answers for insert to authenticated
  with check (user_id = (select auth.uid()) and not (select public.is_banned()));
create policy "Edit your own answer while open unless banned"
  on public.qotw_answers for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and not (select public.is_banned()));
-- No delete policy: answers can't be deleted individually.

create policy "See your own votes" on public.qotw_answer_votes for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Vote unless banned" on public.qotw_answer_votes for insert to authenticated
  with check (user_id = (select auth.uid()) and not (select public.is_banned()));
create policy "Take back your own vote" on public.qotw_answer_votes for delete to authenticated
  using (user_id = (select auth.uid()));


-- ---------------------------------------------------------------------------
-- Reading answers (with each author's display name and chosen picture)
-- ---------------------------------------------------------------------------
create function private.answer_card(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when p_user is null then jsonb_build_object('id', null, 'name', 'Deleted listener', 'avatar_url', null, 'role', null)
              else private.member_card(p_user) end;
$$;

-- Answers to one question: everyone signed in once it's closed; admins any time.
create function public.qotw_answers_for(p_episode integer) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_signed_in();
begin
  if not public.qotw_is_closed(p_episode) and not public.is_admin() then
    return;  -- hidden until the question closes
  end if;
  return query
    select jsonb_build_object(
             'id', a.id, 'episode', a.episode, 'body', a.body, 'created_at', a.created_at, 'updated_at', a.updated_at,
             'featured', a.featured_at is not null, 'votes', (select count(*) from public.qotw_answer_votes v where v.answer_id = a.id),
             'voted', exists (select 1 from public.qotw_answer_votes v where v.answer_id = a.id and v.user_id = v_uid),
             'mine', a.user_id = v_uid, 'author', private.answer_card(a.user_id))
      from public.qotw_answers a
     where a.episode = p_episode
     order by (a.featured_at is not null) desc,
              (select count(*) from public.qotw_answer_votes v where v.answer_id = a.id) desc, a.created_at;
end;
$$;

-- How many answers each closed question has (signed-in listeners).
create function public.qotw_answer_counts() returns table (episode integer, answers bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_signed_in();
  return query select a.episode, count(*) from public.qotw_answers a
                where public.qotw_is_closed(a.episode) group by a.episode;
end;
$$;

-- Your answers, newest question first.
create function public.my_qotw_answers() returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_signed_in();
begin
  return query
    select jsonb_build_object('episode', a.episode, 'question', q.question, 'body', a.body, 'updated_at', a.updated_at,
                              'open', q.closed_at is null, 'featured', a.featured_at is not null,
                              'votes', (select count(*) from public.qotw_answer_votes v where v.answer_id = a.id))
      from public.qotw_answers a join public.qotw_questions q on q.episode = a.episode
     where a.user_id = v_uid order by a.episode desc;
end;
$$;

-- Streaks and the participation badge, from QotW answers only.
create function private.qotw_stats_for(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_total integer;
  v_current integer := 0;
  v_best integer := 0;
  v_run integer := 0;
  v_counting boolean := true;
  v_row record;
begin
  select count(*) into v_total from public.qotw_answers where user_id = p_user;
  for v_row in
    select q.episode, q.closed_at is null as open,
           exists (select 1 from public.qotw_answers a where a.episode = q.episode and a.user_id = p_user) as answered
      from public.qotw_questions q order by q.episode desc
  loop
    if v_row.answered then
      v_run := v_run + 1;
      if v_counting then v_current := v_current + 1; end if;
    elsif v_row.open then
      null;  -- an open, unanswered question doesn't break a streak yet
    else
      v_counting := false;
      v_run := 0;
    end if;
    v_best := greatest(v_best, v_run);
  end loop;
  return jsonb_build_object('answers', v_total, 'current_streak', v_current, 'best_streak', v_best,
    'badge', case when v_total >= 25 then 'Legend' when v_total >= 10 then 'Veteran'
                  when v_total >= 5 then 'Regular' when v_total >= 1 then 'Rookie' end);
end;
$$;

create function public.my_qotw_stats() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return private.qotw_stats_for(private.require_signed_in());
end;
$$;

-- Hosts feature answers (admins and the owner). Audited.
create function public.admin_feature_answer(p_answer uuid, p_featured boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_episode integer;
begin
  perform private.require_admin();
  select episode into v_episode from public.qotw_answers where id = p_answer;
  if v_episode is null then
    raise exception 'No answer with that id.';
  end if;
  perform set_config('app.feature_change', 'on', true);
  update public.qotw_answers
     set featured_at = case when p_featured then coalesce(featured_at, now()) end,
         featured_by = case when p_featured then auth.uid() end
   where id = p_answer;
  perform set_config('app.feature_change', 'off', true);
  perform private.audit(case when p_featured then 'answer_featured' else 'answer_unfeatured' end, null,
                        jsonb_build_object('answer_id', p_answer, 'episode', v_episode));
end;
$$;

-- ---------------------------------------------------------------------------
-- Data export now includes answers and votes
-- ---------------------------------------------------------------------------
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
    'audit_entries_about_you', coalesce((select jsonb_agg(jsonb_build_object('at', a.created_at, 'action', a.action) order by a.created_at)
                                           from public.audit_log a where a.target_id = v_uid or a.actor_id = v_uid), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.qotw_is_open(integer), public.qotw_is_closed(integer) from public;
grant execute on function public.qotw_is_open(integer), public.qotw_is_closed(integer) to anon, authenticated;
revoke execute on function public.qotw_answers_for(integer), public.qotw_answer_counts(), public.my_qotw_answers(),
  public.my_qotw_stats(), public.admin_feature_answer(uuid, boolean) from public, anon, authenticated;
grant execute on function public.qotw_answers_for(integer), public.qotw_answer_counts(), public.my_qotw_answers(),
  public.my_qotw_stats(), public.admin_feature_answer(uuid, boolean) to authenticated;

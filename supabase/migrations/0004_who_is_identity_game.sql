-- SquadQuest · Milestone 2: private stories, anonymous guesses, and host-led reveal.
-- Client roles never receive direct access to the answer or vote tables; all
-- reads and writes go through membership-checked SECURITY DEFINER functions.

alter table squadquest.rooms
  add column if not exists identity_step text not null default 'collecting'
  check (identity_step in ('collecting', 'voting', 'reveal', 'complete'));

create table if not exists squadquest.identity_submissions (
  player_id uuid primary key references squadquest.players(id) on delete cascade,
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  hidden_story text not null check (char_length(btrim(hidden_story)) between 2 and 500),
  dream text not null check (char_length(btrim(dream)) between 2 and 500),
  unexpected_story text not null check (char_length(btrim(unexpected_story)) between 2 and 500),
  submitted_at timestamptz not null default now(),
  unique (room_id, player_id)
);

create table if not exists squadquest.identity_rounds (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  round_number smallint not null check (round_number between 1 and 3),
  prompt_key text not null check (prompt_key in ('hidden_story', 'dream', 'unexpected_story')),
  answer_text text not null,
  author_player_id uuid not null references squadquest.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  revealed_at timestamptz,
  unique (room_id, round_number),
  unique (room_id, author_player_id),
  unique (id, room_id)
);

create table if not exists squadquest.identity_votes (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null,
  room_id uuid not null,
  voter_player_id uuid not null references squadquest.players(id) on delete cascade,
  guessed_player_id uuid not null references squadquest.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  foreign key (round_id, room_id) references squadquest.identity_rounds(id, room_id) on delete cascade,
  unique (round_id, voter_player_id)
);

alter table squadquest.identity_submissions enable row level security;
alter table squadquest.identity_rounds enable row level security;
alter table squadquest.identity_votes enable row level security;

-- Prevent a late join from entering after the host has begun the activity.
drop policy if exists "sessions join as themselves" on squadquest.players;
create policy "sessions join as themselves"
  on squadquest.players for insert to authenticated
  with check (
    session_id = auth.uid()
    and (
      (is_host and exists (
        select 1 from squadquest.rooms where id = room_id and phase = 'waiting' and created_by = auth.uid()
      ))
      or (not is_host and exists (
        select 1 from squadquest.rooms where id = room_id and phase = 'waiting'
      ))
    )
  );

-- The browser may no longer set phases directly. Valid transitions are exposed
-- by the functions below, where host authority and activity state are checked.
revoke update on squadquest.rooms from authenticated;
grant select, insert on squadquest.rooms to authenticated;

revoke all on squadquest.identity_submissions from public, anon, authenticated;
revoke all on squadquest.identity_rounds from public, anon, authenticated;
revoke all on squadquest.identity_votes from public, anon, authenticated;

create or replace function squadquest.start_squadquest_identity(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  participant_count integer;
begin
  if not exists (
    select 1 from squadquest.players
    where room_id = target_room_id and session_id = auth.uid() and is_host
  ) then
    raise exception 'Only this room’s Game Master can start the activity';
  end if;

  select count(*) into participant_count
  from squadquest.players where room_id = target_room_id and not is_host;
  if participant_count < 2 then
    raise exception 'At least two players are needed to begin Who Is?';
  end if;

  update squadquest.rooms
  set phase = 'identity', identity_step = 'collecting'
  where id = target_room_id and phase = 'waiting';

  if not found then raise exception 'The activity has already started'; end if;
  return true;
end;
$$;

create or replace function squadquest.submit_squadquest_identity_answers(
  target_room_id uuid,
  answer_hidden_story text,
  answer_dream text,
  answer_unexpected_story text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  actor_player_id uuid;
begin
  select id into actor_player_id
  from squadquest.players
  where room_id = target_room_id and session_id = auth.uid() and not is_host;

  if actor_player_id is null then raise exception 'Player session not found in this room'; end if;
  if not exists (
    select 1 from squadquest.rooms
    where id = target_room_id and phase = 'identity' and identity_step = 'collecting'
  ) then
    raise exception 'Answers are no longer being collected';
  end if;
  if exists (select 1 from squadquest.identity_submissions where player_id = actor_player_id) then
    raise exception 'Your answers have already been submitted';
  end if;

  insert into squadquest.identity_submissions
    (player_id, room_id, hidden_story, dream, unexpected_story)
  values
    (actor_player_id, target_room_id, btrim(answer_hidden_story), btrim(answer_dream), btrim(answer_unexpected_story));
  return true;
end;
$$;

create or replace function squadquest.start_squadquest_identity_round(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  next_round smallint;
  current_step text;
  participant_count integer;
  submission_count integer;
  selected_author uuid;
  selected_prompt text;
  selected_answer text;
begin
  if not exists (
    select 1 from squadquest.players
    where room_id = target_room_id and session_id = auth.uid() and is_host
  ) then
    raise exception 'Only this room’s Game Master can draw a story';
  end if;

  select identity_step into current_step
  from squadquest.rooms where id = target_room_id and phase = 'identity' for update;
  if not found then raise exception 'The activity is not in progress'; end if;

  select count(*) into participant_count
  from squadquest.players where room_id = target_room_id and not is_host;
  select count(*) into submission_count
  from squadquest.identity_submissions where room_id = target_room_id;
  if participant_count < 2 or submission_count <> participant_count then
    raise exception 'Wait until at least two players have submitted their answers';
  end if;

  select coalesce(max(round_number), 0) + 1 into next_round
  from squadquest.identity_rounds where room_id = target_room_id;
  if next_round > 3 then
    update squadquest.rooms set identity_step = 'complete' where id = target_room_id;
    return true;
  end if;
  if next_round > 1 and current_step <> 'reveal' then
    raise exception 'Reveal the current story before drawing another';
  end if;
  if next_round = 1 and current_step <> 'collecting' then
    raise exception 'The first story can only be drawn after answers are collected';
  end if;

  select candidate.player_id, candidate.prompt_key, candidate.answer_text
    into selected_author, selected_prompt, selected_answer
  from (
    select s.player_id, prompts.prompt_key, prompts.answer_text
    from squadquest.identity_submissions s
    cross join lateral (values
      ('hidden_story'::text, s.hidden_story),
      ('dream'::text, s.dream),
      ('unexpected_story'::text, s.unexpected_story)
    ) as prompts(prompt_key, answer_text)
    where s.room_id = target_room_id
      and not exists (
        select 1 from squadquest.identity_rounds used
        where used.room_id = target_room_id and used.author_player_id = s.player_id
      )
    order by random()
    limit 1
  ) candidate;

  if selected_author is null then
    update squadquest.rooms set identity_step = 'complete' where id = target_room_id;
    return true;
  end if;

  insert into squadquest.identity_rounds
    (room_id, round_number, prompt_key, answer_text, author_player_id)
  values (target_room_id, next_round, selected_prompt, selected_answer, selected_author);

  update squadquest.rooms set identity_step = 'voting' where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.submit_squadquest_identity_vote(
  target_room_id uuid,
  guessed_player_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  actor_player_id uuid;
  active_round_id uuid;
begin
  select id into actor_player_id
  from squadquest.players
  where room_id = target_room_id and session_id = auth.uid() and not is_host;
  if actor_player_id is null then raise exception 'Player session not found in this room'; end if;

  select ir.id into active_round_id
  from squadquest.identity_rounds ir
  join squadquest.rooms r on r.id = ir.room_id
  where ir.room_id = target_room_id and r.phase = 'identity' and r.identity_step = 'voting'
  order by ir.round_number desc limit 1;
  if active_round_id is null then raise exception 'There is no active story to vote on'; end if;
  if not exists (
    select 1 from squadquest.players
    where id = guessed_player_id and room_id = target_room_id and not is_host
  ) then raise exception 'Choose a player from this room'; end if;

  insert into squadquest.identity_votes (round_id, room_id, voter_player_id, guessed_player_id)
  values (active_round_id, target_room_id, actor_player_id, guessed_player_id);
  return true;
end;
$$;

create or replace function squadquest.reveal_squadquest_identity_round(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  active_round_id uuid;
  active_round_number smallint;
begin
  if not exists (
    select 1 from squadquest.players
    where room_id = target_room_id and session_id = auth.uid() and is_host
  ) then raise exception 'Only this room’s Game Master can reveal the story'; end if;

  select ir.id, ir.round_number into active_round_id, active_round_number
  from squadquest.identity_rounds ir
  join squadquest.rooms r on r.id = ir.room_id
  where ir.room_id = target_room_id and r.phase = 'identity' and r.identity_step = 'voting'
  order by ir.round_number desc limit 1;
  if active_round_id is null then raise exception 'There is no active story to reveal'; end if;

  update squadquest.identity_rounds set revealed_at = now() where id = active_round_id;
  update squadquest.rooms
  set identity_step = case when active_round_number >= 3 then 'complete' else 'reveal' end
  where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.get_squadquest_identity_state(target_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  actor_player_id uuid;
  actor_is_host boolean;
  current_step text;
  current_round jsonb;
  participants jsonb;
  submitted_count integer;
  participant_count integer;
  has_submitted boolean;
  has_voted boolean;
begin
  select id, is_host into actor_player_id, actor_is_host
  from squadquest.players
  where room_id = target_room_id and session_id = auth.uid();
  if actor_player_id is null then raise exception 'You are not a member of this room'; end if;

  select identity_step into current_step
  from squadquest.rooms where id = target_room_id and phase = 'identity';
  if current_step is null then raise exception 'The activity has not started'; end if;

  select count(*) into participant_count
  from squadquest.players where room_id = target_room_id and not is_host;
  select count(*) into submitted_count
  from squadquest.identity_submissions where room_id = target_room_id;
  select exists (
    select 1 from squadquest.identity_submissions where room_id = target_room_id and player_id = actor_player_id
  ) into has_submitted;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'name', p.name, 'avatar_id', p.avatar_id
  ) order by p.created_at), '[]'::jsonb) into participants
  from squadquest.players p where p.room_id = target_room_id and not p.is_host;

  select exists (
    select 1 from squadquest.identity_votes v
    join squadquest.identity_rounds ir on ir.id = v.round_id
    where ir.room_id = target_room_id and ir.round_number = (
      select max(round_number) from squadquest.identity_rounds where room_id = target_room_id
    ) and v.voter_player_id = actor_player_id
  ) into has_voted;

  select jsonb_build_object(
    'number', ir.round_number,
    'prompt_key', ir.prompt_key,
    'answer', ir.answer_text,
    'votes_count', (select count(*) from squadquest.identity_votes v where v.round_id = ir.id),
    'has_voted', has_voted,
    'author', case when current_step in ('reveal', 'complete') then (
      select jsonb_build_object('id', p.id, 'name', p.name, 'avatar_id', p.avatar_id)
      from squadquest.players p where p.id = ir.author_player_id
    ) else null end
  ) into current_round
  from squadquest.identity_rounds ir
  where ir.room_id = target_room_id
  order by ir.round_number desc limit 1;

  return jsonb_build_object(
    'step', current_step,
    'is_host', actor_is_host,
    'self_submitted', has_submitted,
    'submitted_count', submitted_count,
    'participant_count', participant_count,
    'players', participants,
    'current_round', current_round
  );
end;
$$;

revoke all on function squadquest.start_squadquest_identity(uuid) from public, anon;
revoke all on function squadquest.submit_squadquest_identity_answers(uuid, text, text, text) from public, anon;
revoke all on function squadquest.start_squadquest_identity_round(uuid) from public, anon;
revoke all on function squadquest.submit_squadquest_identity_vote(uuid, uuid) from public, anon;
revoke all on function squadquest.reveal_squadquest_identity_round(uuid) from public, anon;
revoke all on function squadquest.get_squadquest_identity_state(uuid) from public, anon;

grant execute on function squadquest.start_squadquest_identity(uuid) to authenticated;
grant execute on function squadquest.submit_squadquest_identity_answers(uuid, text, text, text) to authenticated;
grant execute on function squadquest.start_squadquest_identity_round(uuid) to authenticated;
grant execute on function squadquest.submit_squadquest_identity_vote(uuid, uuid) to authenticated;
grant execute on function squadquest.reveal_squadquest_identity_round(uuid) to authenticated;
grant execute on function squadquest.get_squadquest_identity_state(uuid) to authenticated;

comment on table squadquest.identity_submissions is 'Private participant answers for the Who Is? phase; accessed only through membership-checked functions.';
comment on table squadquest.identity_rounds is 'Randomly selected anonymous story cards; author is hidden until host reveal.';
comment on table squadquest.identity_votes is 'Private guesses; no score or individual performance metric is exposed.';

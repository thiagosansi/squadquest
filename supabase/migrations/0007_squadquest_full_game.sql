-- SquadQuest · remaining game phases.
-- Secret roles, team workspaces, ballots and reflections are accessible only
-- through membership-checked SECURITY DEFINER RPCs.

drop policy if exists "the host advances the room" on squadquest.rooms;
-- This INSERT policy reads rooms.phase through an EXISTS subquery. PostgreSQL
-- tracks that dependency and will reject changing the column type until it is
-- dropped; it is recreated below with the same waiting-room rule.
drop policy if exists "sessions join as themselves" on squadquest.players;
alter table squadquest.rooms alter column phase drop default;
alter table squadquest.rooms alter column phase type text using phase::text;
alter table squadquest.rooms alter column phase set default 'waiting';
alter table squadquest.rooms drop constraint if exists rooms_phase_check;
alter table squadquest.rooms
  add constraint rooms_phase_check check (phase in (
    'waiting', 'identity', 'teams', 'roles', 'mission', 'pitch',
    'vote', 'reveal', 'results', 'reflection', 'complete'
  ));
create policy "sessions join as themselves"
  on squadquest.players for insert to authenticated
  with check (
    session_id = auth.uid()
    and (
      (is_host and exists (
        select 1 from squadquest.rooms
        where id = room_id and phase = 'waiting' and created_by = auth.uid()
      ))
      or (not is_host and exists (
        select 1 from squadquest.rooms where id = room_id and phase = 'waiting'
      ))
    )
  );
alter table squadquest.rooms
  add column if not exists state_version bigint not null default 0,
  add column if not exists pitch_index smallint not null default 0,
  add column if not exists chaos_released_at timestamptz,
  add column if not exists phase_started_at timestamptz not null default now();

create table if not exists squadquest.gameplay_teams (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  name text not null,
  team_number smallint not null check (team_number in (1, 2)),
  persona text not null,
  problem text not null,
  restriction text not null,
  mission_step text not null default 'understand'
    check (mission_step in ('understand', 'diverge', 'decide', 'build', 'adapt', 'complete')),
  step_started_at timestamptz not null default now(),
  selected_idea_id uuid,
  solution jsonb not null default '{}'::jsonb,
  chaos jsonb,
  pitch_order smallint,
  created_at timestamptz not null default now(),
  unique (room_id, team_number),
  unique (id, room_id)
);

create table if not exists squadquest.gameplay_assignments (
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  player_id uuid not null references squadquest.players(id) on delete cascade,
  team_id uuid not null references squadquest.gameplay_teams(id) on delete cascade,
  role_key text not null check (role_key in ('devils_advocate', 'visionary', 'customer_voice')),
  role_used boolean not null default false,
  primary key (room_id, player_id),
  unique (player_id)
);

create table if not exists squadquest.gameplay_entries (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  team_id uuid not null references squadquest.gameplay_teams(id) on delete cascade,
  player_id uuid not null references squadquest.players(id) on delete cascade,
  kind text not null check (kind in ('hypothesis', 'idea')),
  content text not null check (char_length(btrim(content)) between 3 and 500),
  created_at timestamptz not null default now(),
  unique (id, team_id)
);

create table if not exists squadquest.gameplay_idea_votes (
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  team_id uuid not null references squadquest.gameplay_teams(id) on delete cascade,
  player_id uuid not null references squadquest.players(id) on delete cascade,
  idea_id uuid not null,
  slot smallint not null check (slot in (1, 2)),
  created_at timestamptz not null default now(),
  primary key (team_id, player_id, slot),
  unique (team_id, player_id, idea_id),
  foreign key (idea_id, team_id) references squadquest.gameplay_entries(id, team_id) on delete cascade
);

create table if not exists squadquest.gameplay_decision_votes (
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  team_id uuid not null references squadquest.gameplay_teams(id) on delete cascade,
  player_id uuid not null references squadquest.players(id) on delete cascade,
  idea_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (team_id, player_id),
  foreign key (idea_id, team_id) references squadquest.gameplay_entries(id, team_id) on delete cascade
);

create table if not exists squadquest.gameplay_power_actions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  team_id uuid not null references squadquest.gameplay_teams(id) on delete cascade,
  player_id uuid not null references squadquest.players(id) on delete cascade,
  content text not null check (char_length(btrim(content)) between 8 and 400),
  created_at timestamptz not null default now()
);

create table if not exists squadquest.gameplay_final_votes (
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  voter_player_id uuid not null references squadquest.players(id) on delete cascade,
  category text not null check (category in ('buy', 'absurd', 'solution')),
  team_id uuid not null references squadquest.gameplay_teams(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (room_id, voter_player_id, category)
);

create table if not exists squadquest.gameplay_reflections (
  room_id uuid not null references squadquest.rooms(id) on delete cascade,
  author_player_id uuid not null references squadquest.players(id) on delete cascade,
  recipient_player_id uuid not null references squadquest.players(id) on delete cascade,
  content text not null check (char_length(btrim(content)) between 8 and 400),
  created_at timestamptz not null default now(),
  primary key (room_id, author_player_id),
  check (author_player_id <> recipient_player_id)
);

create index if not exists gameplay_teams_room_idx on squadquest.gameplay_teams(room_id);
create index if not exists gameplay_entries_team_idx on squadquest.gameplay_entries(team_id, kind, created_at);

alter table squadquest.gameplay_teams enable row level security;
alter table squadquest.gameplay_assignments enable row level security;
alter table squadquest.gameplay_entries enable row level security;
alter table squadquest.gameplay_idea_votes enable row level security;
alter table squadquest.gameplay_decision_votes enable row level security;
alter table squadquest.gameplay_power_actions enable row level security;
alter table squadquest.gameplay_final_votes enable row level security;
alter table squadquest.gameplay_reflections enable row level security;

revoke all on table squadquest.gameplay_teams, squadquest.gameplay_assignments,
  squadquest.gameplay_entries, squadquest.gameplay_idea_votes,
  squadquest.gameplay_decision_votes, squadquest.gameplay_power_actions,
  squadquest.gameplay_final_votes, squadquest.gameplay_reflections
  from public, anon, authenticated;

create or replace function squadquest.draw_squadquest_teams(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  actor_id uuid;
  player_count integer;
  team_ids uuid[];
  team_names text[] := array['Orbit', 'Nova'];
  personas text[] := array['Astronauta', 'Avó de 80 anos', 'Influenciador com medo de câmera', 'Cachorro', 'CEO paranoico', 'Criança de 8 anos', 'Robô recém-chegado à Terra'];
  problems text[] := array['não consegue acordar cedo', 'gasta dinheiro demais', 'sempre chega atrasado', 'tem reuniões demais', 'não consegue decidir o que comer', 'esquece aniversários', 'vive perdendo objetos'];
  restrictions text[] := array['não pode usar telas', 'precisa funcionar no espaço', 'só pode custar R$10', 'precisa usar IA', 'tem que funcionar por WhatsApp', 'precisa gerar receita no primeiro dia', 'tem que funcionar sem internet'];
begin
  select p.id into actor_id from squadquest.players p
  where p.room_id = target_room_id and p.session_id = auth.uid() and p.is_host;
  if actor_id is null then raise exception 'Only this room’s Game Master can draw the teams'; end if;
  perform 1 from squadquest.rooms where id = target_room_id and phase = 'identity' and identity_step = 'complete' for update;
  if not found then raise exception 'Finish Who Is? before drawing the teams'; end if;
  select count(*) into player_count from squadquest.players where room_id = target_room_id and not is_host;
  if player_count < 4 then raise exception 'At least four players are needed to make two playable teams'; end if;
  if exists (select 1 from squadquest.gameplay_teams where room_id = target_room_id) then
    raise exception 'Teams have already been drawn';
  end if;

  insert into squadquest.gameplay_teams(room_id, name, team_number, persona, problem, restriction)
  values
    (target_room_id, team_names[1], 1,
      personas[1 + floor(random() * array_length(personas, 1))::int],
      problems[1 + floor(random() * array_length(problems, 1))::int],
      restrictions[1 + floor(random() * array_length(restrictions, 1))::int]),
    (target_room_id, team_names[2], 2,
      personas[1 + floor(random() * array_length(personas, 1))::int],
      problems[1 + floor(random() * array_length(problems, 1))::int],
      restrictions[1 + floor(random() * array_length(restrictions, 1))::int]);

  select array_agg(id order by team_number) into team_ids
  from squadquest.gameplay_teams where room_id = target_room_id;

  with shuffled as (
    select p.id as player_id,
      row_number() over (order by random()) as rn
    from squadquest.players p where p.room_id = target_room_id and not p.is_host
  ), balanced as (
    select player_id,
      case when rn <= ceil(player_count::numeric / 2) then team_ids[1] else team_ids[2] end as team_id,
      rn
    from shuffled
  ), with_roles as (
    select player_id, team_id,
      row_number() over (partition by team_id order by random()) as role_number
    from balanced
  )
  insert into squadquest.gameplay_assignments(room_id, player_id, team_id, role_key)
  select target_room_id, player_id, team_id,
    case ((role_number - 1)::int % 3)
      when 0 then 'devils_advocate'
      when 1 then 'visionary'
      else 'customer_voice'
    end
  from with_roles;

  update squadquest.rooms set phase = 'teams', phase_started_at = now(), state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.start_squadquest_roles(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can reveal the secret roles';
  end if;
  update squadquest.rooms set phase = 'roles', phase_started_at = now(), state_version = state_version + 1
  where id = target_room_id and phase = 'teams';
  if not found then raise exception 'The team draw is not ready'; end if;
  return true;
end;
$$;

create or replace function squadquest.start_squadquest_mission(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can start the mission';
  end if;
  update squadquest.gameplay_teams set mission_step = 'understand', step_started_at = now()
  where room_id = target_room_id;
  update squadquest.rooms set phase = 'mission', phase_started_at = now(), state_version = state_version + 1
  where id = target_room_id and phase = 'roles';
  if not found then raise exception 'The secret roles have not been revealed'; end if;
  return true;
end;
$$;

create or replace function squadquest.add_squadquest_mission_entry(
  target_room_id uuid, entry_kind text, entry_content text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_player_id uuid; actor_team_id uuid; current_step text; started_at timestamptz; entry_id uuid;
begin
  select p.id, a.team_id, t.mission_step, t.step_started_at
    into actor_player_id, actor_team_id, current_step, started_at
  from squadquest.players p
  join squadquest.gameplay_assignments a on a.player_id = p.id and a.room_id = p.room_id
  join squadquest.gameplay_teams t on t.id = a.team_id
  join squadquest.rooms r on r.id = p.room_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host and r.phase = 'mission';
  if actor_player_id is null then raise exception 'You are not an active player in this mission'; end if;
  if char_length(btrim(entry_content)) not between 3 and 500 then raise exception 'Write between 3 and 500 characters'; end if;
  if current_step = 'understand' and entry_kind = 'hypothesis' then null;
  elsif current_step = 'understand' and entry_kind = 'idea' and now() >= started_at + interval '3 minutes' then null;
  elsif current_step = 'diverge' and entry_kind = 'idea' then null;
  else raise exception 'This kind of note is not available in the current mission step'; end if;
  insert into squadquest.gameplay_entries(room_id, team_id, player_id, kind, content)
  values (target_room_id, actor_team_id, actor_player_id, entry_kind, btrim(entry_content)) returning id into entry_id;
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return entry_id;
end;
$$;

create or replace function squadquest.vote_squadquest_ideas(target_room_id uuid, idea_ids uuid[])
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_player_id uuid; actor_team_id uuid; idea_id uuid; slot_number smallint := 0; voting_started timestamptz;
begin
  select p.id, a.team_id, t.step_started_at into actor_player_id, actor_team_id, voting_started
  from squadquest.players p join squadquest.gameplay_assignments a on a.player_id = p.id
  join squadquest.rooms r on r.id = p.room_id
  join squadquest.gameplay_teams t on t.id = a.team_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host
    and r.phase = 'mission' and t.mission_step = 'diverge';
  if actor_player_id is null then raise exception 'Idea voting is not open for you'; end if;
  if now() < voting_started + interval '2 minutes' then raise exception 'Use the first two minutes for silent writing before voting'; end if;
  if coalesce(array_length(idea_ids, 1), 0) <> 2 or idea_ids[1] = idea_ids[2] then
    raise exception 'Choose two different ideas';
  end if;
  if exists (select 1 from squadquest.gameplay_idea_votes where team_id = actor_team_id and player_id = actor_player_id) then
    raise exception 'Your two votes have already been submitted';
  end if;
  foreach idea_id in array idea_ids loop
    slot_number := slot_number + 1;
    if not exists (select 1 from squadquest.gameplay_entries where id = idea_id and team_id = actor_team_id and kind = 'idea' and player_id <> actor_player_id) then
      raise exception 'You cannot vote for your own idea or another team’s idea';
    end if;
    insert into squadquest.gameplay_idea_votes(room_id, team_id, player_id, idea_id, slot)
    values (target_room_id, actor_team_id, actor_player_id, idea_id, slot_number);
  end loop;
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.vote_squadquest_finalist(target_room_id uuid, idea_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_player_id uuid; actor_team_id uuid; member_count integer; finalist_ids uuid[]; winner_id uuid;
begin
  select p.id, a.team_id into actor_player_id, actor_team_id
  from squadquest.players p join squadquest.gameplay_assignments a on a.player_id = p.id
  join squadquest.rooms r on r.id = p.room_id
  join squadquest.gameplay_teams t on t.id = a.team_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host
    and r.phase = 'mission' and t.mission_step = 'decide';
  if actor_player_id is null then raise exception 'Finalist voting is not open for you'; end if;
  select array_agg(ranked.id) into finalist_ids from (
    select e.id from squadquest.gameplay_entries e
    left join squadquest.gameplay_idea_votes v on v.idea_id = e.id and v.team_id = e.team_id
    where e.team_id = actor_team_id and e.kind = 'idea'
    group by e.id,e.content,e.player_id,e.created_at order by count(v.player_id) desc,e.created_at limit 2
  ) ranked;
  if not (idea_id = any(coalesce(finalist_ids, array[]::uuid[]))) then raise exception 'Choose one of the two finalist ideas'; end if;
  insert into squadquest.gameplay_decision_votes(room_id, team_id, player_id, idea_id)
  values (target_room_id, actor_team_id, actor_player_id, idea_id);
  select count(*) into member_count from squadquest.gameplay_assignments where team_id = actor_team_id;
  select d.idea_id into winner_id
  from squadquest.gameplay_decision_votes d
  where d.team_id = actor_team_id
  group by d.idea_id
  having count(*) > member_count / 2.0
  limit 1;
  if winner_id is not null then
    update squadquest.gameplay_teams set selected_idea_id = winner_id where id = actor_team_id;
  elsif (select count(*) from squadquest.gameplay_decision_votes where team_id = actor_team_id) >= member_count then
    select d.idea_id into winner_id from squadquest.gameplay_decision_votes d
    where d.team_id = actor_team_id group by d.idea_id
    order by count(*) desc, random() limit 1;
    update squadquest.gameplay_teams set selected_idea_id = winner_id where id = actor_team_id;
  end if;
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.update_squadquest_solution(target_room_id uuid, solution_data jsonb)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_team_id uuid; current_step text; clean_solution jsonb;
begin
  select a.team_id, t.mission_step into actor_team_id, current_step
  from squadquest.players p join squadquest.gameplay_assignments a on a.player_id = p.id
  join squadquest.gameplay_teams t on t.id = a.team_id
  join squadquest.rooms r on r.id = p.room_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host
    and r.phase = 'mission' and t.mission_step in ('build', 'adapt');
  if actor_team_id is null then raise exception 'The shared canvas is not open'; end if;
  clean_solution := jsonb_build_object(
    'name', left(coalesce(solution_data->>'name', ''), 80),
    'for_user', left(coalesce(solution_data->>'for_user', ''), 160),
    'problem', left(coalesce(solution_data->>'problem', ''), 240),
    'value', left(coalesce(solution_data->>'value', ''), 400),
    'how_works', jsonb_build_array(
      left(coalesce(solution_data->'how_works'->>0, ''), 180),
      left(coalesce(solution_data->'how_works'->>1, ''), 180),
      left(coalesce(solution_data->'how_works'->>2, ''), 180)
    ),
    'why_use', left(coalesce(solution_data->>'why_use', ''), 300),
    'adaptation', left(coalesce(solution_data->>'adaptation', ''), 300)
  );
  update squadquest.gameplay_teams set solution = clean_solution where id = actor_team_id;
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.advance_squadquest_mission(target_room_id uuid, target_team_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare current_step text; next_step text; member_count integer; distinct_writers integer; missing_count integer;
  winner_id uuid; finalist_ids uuid[]; chaos_released timestamptz;
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can advance the mission';
  end if;
  select t.mission_step, r.chaos_released_at into current_step, chaos_released from squadquest.gameplay_teams t
  join squadquest.rooms r on r.id = t.room_id
  where t.id = target_team_id and t.room_id = target_room_id and r.phase = 'mission' for update;
  if current_step is null then raise exception 'Team not found in the active mission'; end if;
  select count(*) into member_count from squadquest.gameplay_assignments where team_id = target_team_id;

  if current_step = 'understand' then
    select count(distinct e.player_id) into distinct_writers from squadquest.gameplay_entries e
    where e.team_id = target_team_id and e.kind = 'hypothesis';
    if distinct_writers < member_count then raise exception 'Every teammate must add at least one hypothesis'; end if;
    next_step := 'diverge';
  elsif current_step = 'diverge' then
    select count(*) into missing_count from squadquest.gameplay_assignments a
    where a.team_id = target_team_id and (
      (select count(*) from squadquest.gameplay_entries e where e.team_id = target_team_id and e.kind = 'idea' and e.player_id = a.player_id) < 2
      or (select count(*) from squadquest.gameplay_idea_votes v where v.team_id = target_team_id and v.player_id = a.player_id) <> 2
    );
    if missing_count > 0 then raise exception 'Everyone must add two ideas and submit two anonymous votes'; end if;
    next_step := 'decide';
  elsif current_step = 'decide' then
    select t.selected_idea_id into winner_id from squadquest.gameplay_teams t where t.id = target_team_id;
    if winner_id is null then
      if now() < (select step_started_at + interval '3 minutes' from squadquest.gameplay_teams where id = target_team_id) then
        raise exception 'Give the team three minutes to decide between the finalists';
      end if;
      select array_agg(ranked.id) into finalist_ids from (
        select e.id from squadquest.gameplay_entries e
        left join squadquest.gameplay_idea_votes v on v.idea_id = e.id and v.team_id = e.team_id
        where e.team_id = target_team_id and e.kind = 'idea'
        group by e.id,e.content,e.player_id,e.created_at order by count(v.player_id) desc,e.created_at limit 2
      ) ranked;
      if coalesce(array_length(finalist_ids, 1), 0) = 0 then raise exception 'There are no finalist ideas to select'; end if;
      winner_id := finalist_ids[1 + floor(random() * array_length(finalist_ids, 1))::int];
      update squadquest.gameplay_teams set selected_idea_id = winner_id where id = target_team_id;
    end if;
    next_step := 'build';
  elsif current_step = 'build' or current_step = 'adapt' then
    if current_step = 'build' and chaos_released is null then raise exception 'Launch the chaos card before a team can finish building'; end if;
    if current_step = 'build' and exists(select 1 from squadquest.gameplay_teams where id = target_team_id and chaos is not null) then
      raise exception 'This team must adapt its solution to the chaos card';
    end if;
    if coalesce((select solution->>'name' from squadquest.gameplay_teams where id = target_team_id), '') = ''
      or coalesce((select solution->>'value' from squadquest.gameplay_teams where id = target_team_id), '') = ''
      or coalesce((select solution->>'why_use' from squadquest.gameplay_teams where id = target_team_id), '') = '' then
      raise exception 'Complete the product name, value proposition, and reason to use it first';
    end if;
    if current_step = 'adapt' and coalesce((select solution->>'adaptation' from squadquest.gameplay_teams where id = target_team_id), '') = '' then
      raise exception 'Describe how the product adapts to the chaos card';
    end if;
    next_step := 'complete';
  else
    raise exception 'This team has already completed the mission';
  end if;

  update squadquest.gameplay_teams set mission_step = next_step, step_started_at = now() where id = target_team_id;
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.release_squadquest_chaos(target_room_id uuid, target_team_id uuid default null)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare card jsonb; target_count integer;
  cards jsonb[] := array[
    '{"title":"Budget Cut","text":"O produto só pode custar R$5 por usuário."}'::jsonb,
    '{"title":"Modo offline","text":"A internet deixou de existir. Como a solução continua funcionando?"}'::jsonb,
    '{"title":"Plot twist","text":"A persona agora tem mais de 70 anos."}'::jsonb,
    '{"title":"Monetização","text":"Um investidor apareceu. Como isso gera receita desde o primeiro dia?"}'::jsonb,
    '{"title":"Concorrente","text":"Um concorrente lançou exatamente a mesma solução."}'::jsonb
  ];
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can launch chaos';
  end if;
  perform 1 from squadquest.rooms where id = target_room_id and phase = 'mission' and chaos_released_at is null for update;
  if not found then raise exception 'Chaos has already been launched or the mission is not active'; end if;
  if exists (
    select 1 from squadquest.gameplay_teams t
    where t.room_id=target_room_id and t.mission_step='build'
      and (target_team_id is null or t.id=target_team_id)
      and now() < t.step_started_at + interval '4 minutes'
  ) then raise exception 'The chaos card unlocks when about eight minutes remain in Build'; end if;
  card := cards[1 + floor(random() * array_length(cards, 1))::int];
  update squadquest.gameplay_teams set chaos = card, mission_step = 'adapt', step_started_at = now()
  where room_id = target_room_id and mission_step = 'build'
    and (target_team_id is null or id = target_team_id);
  get diagnostics target_count = row_count;
  if target_count = 0 then raise exception 'Choose one or more teams currently building'; end if;
  update squadquest.rooms set chaos_released_at = now(), state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.use_squadquest_role_power(target_room_id uuid, action_text text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_player_id uuid; actor_team_id uuid; actor_role text; current_step text;
begin
  select p.id, a.team_id, a.role_key, t.mission_step into actor_player_id, actor_team_id, actor_role, current_step
  from squadquest.players p join squadquest.gameplay_assignments a on a.player_id = p.id
  join squadquest.gameplay_teams t on t.id = a.team_id join squadquest.rooms r on r.id = p.room_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host and r.phase = 'mission' and not a.role_used;
  if actor_player_id is null then raise exception 'Your power is unavailable or already used'; end if;
  if char_length(btrim(action_text)) not between 8 and 400 then raise exception 'Add a short explanation to use your power'; end if;
  if current_step = 'complete'
    or (actor_role = 'customer_voice' and current_step not in ('build','adapt','decide'))
    or (actor_role = 'devils_advocate' and current_step not in ('decide','build','adapt')) then
    raise exception 'This power can be used later in the mission';
  end if;
  insert into squadquest.gameplay_power_actions(room_id, team_id, player_id, content)
  values (target_room_id, actor_team_id, actor_player_id, btrim(action_text));
  update squadquest.gameplay_assignments set role_used = true where player_id = actor_player_id;
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.start_squadquest_pitches(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can start the pitches';
  end if;
  if exists (select 1 from squadquest.gameplay_teams where room_id = target_room_id and mission_step <> 'complete') then
    raise exception 'Both teams need to complete the mission first';
  end if;
  with order_draw as (
    select id, row_number() over(order by random())::smallint as position
    from squadquest.gameplay_teams where room_id = target_room_id
  ) update squadquest.gameplay_teams t set pitch_order = o.position from order_draw o where t.id = o.id;
  update squadquest.rooms set phase = 'pitch', pitch_index = 1, phase_started_at = now(), state_version = state_version + 1
  where id = target_room_id and phase = 'mission';
  if not found then raise exception 'The mission is not active'; end if;
  return true;
end;
$$;

create or replace function squadquest.advance_squadquest_pitch(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare current_index smallint; pitch_count integer;
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can advance the pitches';
  end if;
  select pitch_index into current_index from squadquest.rooms where id = target_room_id and phase = 'pitch' for update;
  if current_index is null then raise exception 'Pitches are not in progress'; end if;
  select count(*) into pitch_count from squadquest.gameplay_teams where room_id = target_room_id;
  update squadquest.rooms set phase = case when current_index >= pitch_count then 'vote' else 'pitch' end,
    pitch_index = least(current_index + 1, pitch_count), phase_started_at = now(), state_version = state_version + 1
  where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.submit_squadquest_final_vote(target_room_id uuid, vote_category text, target_team_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_player_id uuid;
begin
  select p.id into actor_player_id from squadquest.players p join squadquest.rooms r on r.id = p.room_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host and r.phase = 'vote';
  if actor_player_id is null then raise exception 'Final voting is not open for you'; end if;
  if vote_category not in ('buy', 'absurd', 'solution') then raise exception 'Unknown voting category'; end if;
  if not exists(select 1 from squadquest.gameplay_teams where id = target_team_id and room_id = target_room_id) then
    raise exception 'Choose one of the teams';
  end if;
  insert into squadquest.gameplay_final_votes(room_id, voter_player_id, category, team_id)
  values (target_room_id, actor_player_id, vote_category, target_team_id);
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.start_squadquest_reveal(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare participant_count integer; ballot_count integer;
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can close the vote';
  end if;
  select count(*) into participant_count from squadquest.players where room_id = target_room_id and not is_host;
  select count(*) into ballot_count from squadquest.gameplay_final_votes where room_id = target_room_id;
  if ballot_count <> participant_count * 3 then raise exception 'Wait until everyone has voted in all three categories'; end if;
  update squadquest.rooms set phase = 'reveal', phase_started_at = now(), state_version = state_version + 1
  where id = target_room_id and phase = 'vote';
  if not found then raise exception 'Final voting is not open'; end if;
  return true;
end;
$$;

create or replace function squadquest.start_squadquest_results(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can reveal the results';
  end if;
  update squadquest.rooms set phase = 'results', phase_started_at = now(), state_version = state_version + 1
  where id = target_room_id and phase = 'reveal';
  if not found then raise exception 'The secret-role reveal is not active'; end if;
  return true;
end;
$$;

create or replace function squadquest.start_squadquest_reflection(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can start the closing reflection';
  end if;
  update squadquest.rooms set phase = 'reflection', phase_started_at = now(), state_version = state_version + 1
  where id = target_room_id and phase = 'results';
  if not found then raise exception 'Results are not on screen'; end if;
  return true;
end;
$$;

create or replace function squadquest.submit_squadquest_reflection(target_room_id uuid, target_player_id uuid, reflection_text text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_player_id uuid;
begin
  select p.id into actor_player_id from squadquest.players p join squadquest.rooms r on r.id = p.room_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host and r.phase = 'reflection';
  if actor_player_id is null then raise exception 'Closing reflections are not open for you'; end if;
  if target_player_id = actor_player_id or not exists (
    select 1 from squadquest.players where id = target_player_id and room_id = target_room_id and not is_host
  ) then raise exception 'Choose another player from this room'; end if;
  if char_length(btrim(reflection_text)) not between 8 and 400 then raise exception 'Write between 8 and 400 characters'; end if;
  insert into squadquest.gameplay_reflections(room_id, author_player_id, recipient_player_id, content)
  values (target_room_id, actor_player_id, target_player_id, btrim(reflection_text));
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.finish_squadquest_game(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare participant_count integer; reflection_count integer;
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can finish the game';
  end if;
  select count(*) into participant_count from squadquest.players where room_id = target_room_id and not is_host;
  select count(*) into reflection_count from squadquest.gameplay_reflections where room_id = target_room_id;
  if reflection_count <> participant_count then raise exception 'Wait for everyone to submit a reflection'; end if;
  update squadquest.rooms set phase = 'complete', phase_started_at = now(), state_version = state_version + 1
  where id = target_room_id and phase = 'reflection';
  if not found then raise exception 'The reflection is not active'; end if;
  return true;
end;
$$;

create or replace function squadquest.get_squadquest_game_state(target_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  actor_id uuid; actor_is_host boolean; actor_team_id uuid; actor_role text; actor_role_used boolean;
  current_phase text; identity_step_value text; room_version bigint; pitch_position smallint; phase_started timestamptz; chaos_started timestamptz;
  teams_json jsonb; roles_json jsonb; results_json jsonb; reflections_json jsonb;
  final_ballot_count integer; reflection_total integer;
begin
  select p.id, p.is_host, a.team_id, a.role_key, a.role_used,
    r.phase, r.identity_step, r.state_version, r.pitch_index, r.phase_started_at, r.chaos_released_at
  into actor_id, actor_is_host, actor_team_id, actor_role, actor_role_used,
    current_phase, identity_step_value, room_version, pitch_position, phase_started, chaos_started
  from squadquest.players p join squadquest.rooms r on r.id = p.room_id
  left join squadquest.gameplay_assignments a on a.player_id = p.id and a.room_id = p.room_id
  where p.room_id = target_room_id and p.session_id = auth.uid();
  if actor_id is null then raise exception 'You are not a member of this room'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'name', t.name,
    'team_number', t.team_number,
    'mission', case when current_phase in ('teams','roles','pitch','vote','reveal','results','reflection','complete')
      or actor_is_host or t.id=actor_team_id then jsonb_build_object('persona', t.persona, 'problem', t.problem, 'restriction', t.restriction)
      else null end,
    'step', case when current_phase <> 'mission' or actor_is_host or t.id=actor_team_id then t.mission_step else null end,
    'step_started_at', t.step_started_at,
    'chaos', case when actor_is_host or t.id=actor_team_id or current_phase in ('pitch','vote','reveal','results','reflection','complete') then t.chaos else null end,
    'pitch_order', case when actor_is_host or current_phase in ('pitch','vote','reveal','results','reflection','complete') then t.pitch_order else null end,
    'selected_idea_id', case when actor_is_host or t.id=actor_team_id then t.selected_idea_id else null end,
    'members', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'avatar_id', p.avatar_id,
      'role_key', case
        when current_phase in ('reveal','results','reflection','complete') then a.role_key
        when p.id = actor_id and current_phase in ('roles','mission','pitch','vote') then a.role_key
        else null end
    ) order by p.created_at), '[]'::jsonb)
      from squadquest.gameplay_assignments a
      join squadquest.players p on p.id = a.player_id
      where a.team_id = t.id),
    'hypotheses', case when not actor_is_host and t.id = actor_team_id and current_phase = 'mission' then (
      select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'player_id',e.player_id,'content',e.content,'created_at',e.created_at) order by e.created_at),'[]'::jsonb)
      from squadquest.gameplay_entries e where e.team_id = t.id and e.kind = 'hypothesis') else null end,
    'ideas', case when not actor_is_host and t.id = actor_team_id and current_phase = 'mission' then (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',e.id,'player_id',e.player_id,'content',e.content,'created_at',e.created_at,
        'votes_count',(select count(*) from squadquest.gameplay_idea_votes v where v.idea_id = e.id),
        'is_own',(e.player_id = actor_id)
      ) order by e.created_at),'[]'::jsonb)
      from squadquest.gameplay_entries e where e.team_id = t.id and e.kind = 'idea') else null end,
    'my_idea_votes', case when not actor_is_host and t.id = actor_team_id then (
      select coalesce(jsonb_agg(v.idea_id order by v.slot),'[]'::jsonb)
      from squadquest.gameplay_idea_votes v where v.team_id = t.id and v.player_id = actor_id) else null end,
    'finalists', case when not actor_is_host and t.id = actor_team_id and current_phase = 'mission' then (
      select coalesce(jsonb_agg(jsonb_build_object('id',ranked.id,'content',ranked.content,'votes_count',ranked.votes_count,'is_own',ranked.player_id=actor_id) order by ranked.votes_count desc, ranked.created_at),'[]'::jsonb)
      from (
        select e.id,e.content,e.player_id,e.created_at,count(v.player_id)::int as votes_count
        from squadquest.gameplay_entries e left join squadquest.gameplay_idea_votes v on v.idea_id=e.id
        where e.team_id=t.id and e.kind='idea'
        group by e.id,e.content,e.player_id,e.created_at order by count(v.player_id) desc,e.created_at limit 2
      ) ranked) else null end,
    'my_decision_vote', case when not actor_is_host and t.id = actor_team_id then (
      select d.idea_id from squadquest.gameplay_decision_votes d where d.team_id=t.id and d.player_id=actor_id) else null end,
    'decision_votes', case when not actor_is_host and t.id = actor_team_id and current_phase='mission' then (
      select coalesce(jsonb_agg(jsonb_build_object('idea_id',d.idea_id,'votes_count',d.vote_count)),'[]'::jsonb)
      from (select idea_id,count(*)::int as vote_count from squadquest.gameplay_decision_votes where team_id=t.id group by idea_id) d) else null end,
    'solution', case when (t.id=actor_team_id and not actor_is_host and current_phase='mission') or current_phase in ('pitch','vote','reveal','results','reflection','complete') then t.solution else null end,
    'power_used', case when not actor_is_host and t.id=actor_team_id then actor_role_used else null end,
    'power_actions', case when not actor_is_host and t.id=actor_team_id and current_phase='mission' then (
      select coalesce(jsonb_agg(jsonb_build_object('name',p.name,'avatar_id',p.avatar_id,'content',x.content,'created_at',x.created_at) order by x.created_at),'[]'::jsonb)
      from squadquest.gameplay_power_actions x join squadquest.players p on p.id=x.player_id where x.team_id=t.id) else null end,
    'hypothesis_count', case when current_phase='mission' and (actor_is_host or t.id=actor_team_id) then (select count(*) from squadquest.gameplay_entries e where e.team_id=t.id and e.kind='hypothesis') else 0 end,
    'idea_count', case when current_phase='mission' and (actor_is_host or t.id=actor_team_id) then (select count(*) from squadquest.gameplay_entries e where e.team_id=t.id and e.kind='idea') else 0 end,
    'idea_ballots', case when current_phase='mission' and (actor_is_host or t.id=actor_team_id) then (select count(distinct v.player_id) from squadquest.gameplay_idea_votes v where v.team_id=t.id) else 0 end,
    'member_count', (select count(*) from squadquest.gameplay_assignments a where a.team_id=t.id),
    'solution_ballots', case when current_phase='mission' and (actor_is_host or t.id=actor_team_id) then (select count(*) from squadquest.gameplay_decision_votes d where d.team_id=t.id) else 0 end,
    'hypotheses_ready', current_phase='mission' and (actor_is_host or t.id=actor_team_id) and not exists (
      select 1 from squadquest.gameplay_assignments a
      where a.team_id=t.id and not exists (
        select 1 from squadquest.gameplay_entries e where e.team_id=t.id and e.player_id=a.player_id and e.kind='hypothesis'
      )
    ),
    'ideas_ready', current_phase='mission' and (actor_is_host or t.id=actor_team_id) and not exists (
      select 1 from squadquest.gameplay_assignments a where a.team_id=t.id and (
        (select count(*) from squadquest.gameplay_entries e where e.team_id=t.id and e.player_id=a.player_id and e.kind='idea') < 2
        or (select count(*) from squadquest.gameplay_idea_votes v where v.team_id=t.id and v.player_id=a.player_id) <> 2
      )
    ),
    'decision_ready', current_phase='mission' and (actor_is_host or t.id=actor_team_id)
      and (t.selected_idea_id is not null or now() >= t.step_started_at + interval '3 minutes'),
    'solution_ready', current_phase='mission' and (actor_is_host or t.id=actor_team_id)
      and coalesce(t.solution->>'name','') <> '' and coalesce(t.solution->>'value','') <> ''
      and coalesce(t.solution->>'why_use','') <> ''
      and (t.mission_step <> 'adapt' or coalesce(t.solution->>'adaptation','') <> '')
  ) order by t.team_number), '[]'::jsonb) into teams_json
  from squadquest.gameplay_teams t where t.room_id = target_room_id;

  if current_phase in ('reveal','results','reflection','complete') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.name,'avatar_id',p.avatar_id,'team_id',a.team_id,'role_key',a.role_key
    ) order by p.created_at),'[]'::jsonb) into roles_json
    from squadquest.players p join squadquest.gameplay_assignments a on a.player_id=p.id
    where p.room_id=target_room_id;
  else roles_json := '[]'::jsonb; end if;

  if current_phase in ('results','reflection','complete') then
    select coalesce(jsonb_agg(jsonb_build_object('category',cats.category,'team_id',cats.team_id,'votes',cats.vote_count)), '[]'::jsonb)
    into results_json from (
      select c.category,t.id as team_id,count(v.voter_player_id)::int as vote_count
      from (values ('buy'::text),('absurd'::text),('solution'::text)) c(category)
      cross join squadquest.gameplay_teams t
      left join squadquest.gameplay_final_votes v on v.team_id=t.id and v.category=c.category
      where t.room_id=target_room_id group by c.category,t.id
    ) cats;
  else results_json := '[]'::jsonb; end if;

  select count(*) into final_ballot_count from squadquest.gameplay_final_votes where room_id=target_room_id;
  select count(*) into reflection_total from squadquest.gameplay_reflections where room_id=target_room_id;
  if current_phase='complete' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'author',a.name,'recipient',b.name,'content',f.content
    ) order by f.created_at),'[]'::jsonb) into reflections_json
    from squadquest.gameplay_reflections f
    join squadquest.players a on a.id=f.author_player_id
    join squadquest.players b on b.id=f.recipient_player_id
    where f.room_id=target_room_id;
  else reflections_json := '[]'::jsonb; end if;

  return jsonb_build_object(
    'phase',current_phase,'identity_step',identity_step_value,'is_host',actor_is_host,
    'state_version',room_version,'phase_started_at',phase_started,'chaos_released_at',chaos_started,'pitch_index',pitch_position,'my_team_id',actor_team_id,
    'my_role',case when not actor_is_host and current_phase in ('roles','mission','pitch','vote') then actor_role else null end,
    'my_power_used',actor_role_used,'teams',teams_json,'revealed_roles',roles_json,
    'final_ballot_count',final_ballot_count,'reflection_count',reflection_total,
    'my_final_votes',(select coalesce(jsonb_agg(jsonb_build_object('category',category,'team_id',team_id)),'[]'::jsonb)
      from squadquest.gameplay_final_votes where room_id=target_room_id and voter_player_id=actor_id),
    'my_reflection_sent',exists(select 1 from squadquest.gameplay_reflections where room_id=target_room_id and author_player_id=actor_id),
    'results',results_json,'reflections',reflections_json
  );
end;
$$;

revoke all on function squadquest.draw_squadquest_teams(uuid) from public, anon;
revoke all on function squadquest.start_squadquest_roles(uuid) from public, anon;
revoke all on function squadquest.start_squadquest_mission(uuid) from public, anon;
revoke all on function squadquest.add_squadquest_mission_entry(uuid,text,text) from public, anon;
revoke all on function squadquest.vote_squadquest_ideas(uuid,uuid[]) from public, anon;
revoke all on function squadquest.vote_squadquest_finalist(uuid,uuid) from public, anon;
revoke all on function squadquest.update_squadquest_solution(uuid,jsonb) from public, anon;
revoke all on function squadquest.advance_squadquest_mission(uuid,uuid) from public, anon;
revoke all on function squadquest.release_squadquest_chaos(uuid,uuid) from public, anon;
revoke all on function squadquest.use_squadquest_role_power(uuid,text) from public, anon;
revoke all on function squadquest.start_squadquest_pitches(uuid) from public, anon;
revoke all on function squadquest.advance_squadquest_pitch(uuid) from public, anon;
revoke all on function squadquest.submit_squadquest_final_vote(uuid,text,uuid) from public, anon;
revoke all on function squadquest.start_squadquest_reveal(uuid) from public, anon;
revoke all on function squadquest.start_squadquest_results(uuid) from public, anon;
revoke all on function squadquest.start_squadquest_reflection(uuid) from public, anon;
revoke all on function squadquest.submit_squadquest_reflection(uuid,uuid,text) from public, anon;
revoke all on function squadquest.finish_squadquest_game(uuid) from public, anon;
revoke all on function squadquest.get_squadquest_game_state(uuid) from public, anon;

grant execute on function squadquest.draw_squadquest_teams(uuid) to authenticated;
grant execute on function squadquest.start_squadquest_roles(uuid) to authenticated;
grant execute on function squadquest.start_squadquest_mission(uuid) to authenticated;
grant execute on function squadquest.add_squadquest_mission_entry(uuid,text,text) to authenticated;
grant execute on function squadquest.vote_squadquest_ideas(uuid,uuid[]) to authenticated;
grant execute on function squadquest.vote_squadquest_finalist(uuid,uuid) to authenticated;
grant execute on function squadquest.update_squadquest_solution(uuid,jsonb) to authenticated;
grant execute on function squadquest.advance_squadquest_mission(uuid,uuid) to authenticated;
grant execute on function squadquest.release_squadquest_chaos(uuid,uuid) to authenticated;
grant execute on function squadquest.use_squadquest_role_power(uuid,text) to authenticated;
grant execute on function squadquest.start_squadquest_pitches(uuid) to authenticated;
grant execute on function squadquest.advance_squadquest_pitch(uuid) to authenticated;
grant execute on function squadquest.submit_squadquest_final_vote(uuid,text,uuid) to authenticated;
grant execute on function squadquest.start_squadquest_reveal(uuid) to authenticated;
grant execute on function squadquest.start_squadquest_results(uuid) to authenticated;
grant execute on function squadquest.start_squadquest_reflection(uuid) to authenticated;
grant execute on function squadquest.submit_squadquest_reflection(uuid,uuid,text) to authenticated;
grant execute on function squadquest.finish_squadquest_game(uuid) to authenticated;
grant execute on function squadquest.get_squadquest_game_state(uuid) to authenticated;

comment on table squadquest.gameplay_assignments is 'Private team and secret-role assignments; readable only through the privacy-filtered gameplay state RPC.';
comment on table squadquest.gameplay_final_votes is 'Private, anonymous category ballots; results are exposed only after the host opens results.';
comment on table squadquest.gameplay_reflections is 'Private closing notes, exposed collectively only after all players submit.';

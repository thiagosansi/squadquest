-- SquadQuest · secret powers have a moment, add time, and gate completion.
-- Three functions from 0007 are recreated with the same bodies plus the
-- changes below; every other rule stays untouched.
--
-- use_squadquest_role_power: each role can only fire in its own window.
--   visionary       -> Diverge, after the 2-minute silent writing.
--   devils_advocate -> Decide.
--   customer_voice  -> Build or Adapt, once solution.value is written.
-- advance_squadquest_mission: bonus = 1 minute per power used by the team
--   during its current step (power_actions.created_at >= step_started_at).
--   The Decide tie-break waits 3 minutes + bonus. Build/Adapt only complete
--   when every teammate has used their power or after the step time
--   (12 min Build, 4 min Adapt) + bonus has run out.
-- get_squadquest_game_state: each team object gains two integers, visible to
--   the host and to that team's members during the mission (0 otherwise):
--   step_power_count (powers used in the current step) and powers_used_count
--   (assignments with role_used). No role or content is exposed.
--   decision_ready also adds the same bonus (3 min + 1 min per power used in
--   the step), so the host button unlocks exactly when advance allows it.

create or replace function squadquest.use_squadquest_role_power(target_room_id uuid, action_text text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_player_id uuid; actor_team_id uuid; actor_role text; current_step text; step_started timestamptz; solution_data jsonb;
begin
  select p.id, a.team_id, a.role_key, t.mission_step, t.step_started_at, t.solution
  into actor_player_id, actor_team_id, actor_role, current_step, step_started, solution_data
  from squadquest.players p join squadquest.gameplay_assignments a on a.player_id = p.id
  join squadquest.gameplay_teams t on t.id = a.team_id join squadquest.rooms r on r.id = p.room_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host and r.phase = 'mission' and not a.role_used;
  if actor_player_id is null then raise exception 'Your power is unavailable or already used'; end if;
  if char_length(btrim(action_text)) not between 8 and 400 then raise exception 'Add a short explanation to use your power'; end if;
  if actor_role = 'visionary' then
    if current_step <> 'diverge' or now() < step_started + interval '2 minutes' then
      raise exception 'Leve a ideia dez vezes mais longe só vale em Divergir, depois da escrita silenciosa';
    end if;
  elsif actor_role = 'devils_advocate' then
    if current_step <> 'decide' then
      raise exception 'E se estivermos errados? só vale em Decidir';
    end if;
  elsif actor_role = 'customer_voice' then
    if current_step not in ('build','adapt') or coalesce(solution_data->>'value','') = '' then
      raise exception 'Eu não compraria só vale em Construir, depois de escrever a proposta de valor';
    end if;
  else
    raise exception 'This power can be used later in the mission';
  end if;
  insert into squadquest.gameplay_power_actions(room_id, team_id, player_id, content)
  values (target_room_id, actor_team_id, actor_player_id, btrim(action_text));
  update squadquest.gameplay_assignments set role_used = true where player_id = actor_player_id;
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
  winner_id uuid; finalist_ids uuid[]; chaos_released timestamptz; bonus interval;
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can advance the mission';
  end if;
  select t.mission_step, r.chaos_released_at into current_step, chaos_released from squadquest.gameplay_teams t
  join squadquest.rooms r on r.id = t.room_id
  where t.id = target_team_id and t.room_id = target_room_id and r.phase = 'mission' for update;
  if current_step is null then raise exception 'Team not found in the active mission'; end if;
  select count(*) into member_count from squadquest.gameplay_assignments where team_id = target_team_id;
  select coalesce(interval '1 minute' * count(*), interval '0') into bonus
  from squadquest.gameplay_power_actions x join squadquest.gameplay_teams t on t.id = x.team_id
  where x.team_id = target_team_id and x.created_at >= t.step_started_at;

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
      if now() < (select step_started_at + interval '3 minutes' + bonus from squadquest.gameplay_teams where id = target_team_id) then
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
    if exists (select 1 from squadquest.gameplay_assignments a where a.team_id = target_team_id and not a.role_used)
      and now() < (select step_started_at from squadquest.gameplay_teams where id = target_team_id)
        + (case when current_step = 'build' then interval '12 minutes' else interval '4 minutes' end) + bonus then
      raise exception 'Every teammate must use their secret power before finishing, or wait for the step time to run out';
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
    'step_power_count', case when current_phase='mission' and (actor_is_host or t.id=actor_team_id) then (select count(*)::int from squadquest.gameplay_power_actions x where x.team_id=t.id and x.created_at>=t.step_started_at) else 0 end,
    'powers_used_count', case when current_phase='mission' and (actor_is_host or t.id=actor_team_id) then (select count(*)::int from squadquest.gameplay_assignments a where a.team_id=t.id and a.role_used) else 0 end,
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
      and (t.selected_idea_id is not null or now() >= t.step_started_at + interval '3 minutes' + interval '1 minute' * (select count(*) from squadquest.gameplay_power_actions x where x.team_id=t.id and x.created_at>=t.step_started_at)),
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

-- Same privileges as 0007: create or replace keeps existing grants, but they are
-- restated so the functions never end up without the expected access.
revoke all on function squadquest.advance_squadquest_mission(uuid,uuid) from public, anon;
revoke all on function squadquest.use_squadquest_role_power(uuid,text) from public, anon;
revoke all on function squadquest.get_squadquest_game_state(uuid) from public, anon;

grant execute on function squadquest.advance_squadquest_mission(uuid,uuid) to authenticated;
grant execute on function squadquest.use_squadquest_role_power(uuid,text) to authenticated;
grant execute on function squadquest.get_squadquest_game_state(uuid) to authenticated;

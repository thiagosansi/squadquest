-- SquadQuest · the power holder stays anonymous until the reveal.
--
-- get_squadquest_game_state (0011 body), four changes and nothing else:
--   power_challenge.holder_name  only the holder receives their own name
--                                (i_am_holder); every other team member gets
--                                null.
--   power_challenge.holder_player_id  same rule: the holder's own id for the
--                                holder, null for everyone else (the client
--                                does not read it). i_am_holder, replies and
--                                the rest of the block are unchanged.
--   power_outcomes.holder_name   null while the room is in mission, pitch or
--                                vote; the name comes back in reveal, results,
--                                reflection and complete, for everyone who
--                                sees outcomes (team, host and the other team).
--   power_actions[]              the team feed during the mission now carries
--                                name and avatar_id as null; content and
--                                created_at are kept, so the team still sees
--                                that a power was used and what was written,
--                                not by whom.
-- power_challenge_status already has no names, so it is untouched. The
-- function is recreated whole (create or replace keeps the signature), and the
-- 0011 privileges are restated below.

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
      select coalesce(jsonb_agg(jsonb_build_object('name', null::text, 'avatar_id', null::text, 'content',x.content,'created_at',x.created_at) order by x.created_at),'[]'::jsonb)
      from squadquest.gameplay_power_actions x join squadquest.players p on p.id=x.player_id where x.team_id=t.id) else null end,
    'power_challenge', case when not actor_is_host and t.id=actor_team_id and current_phase='mission' then (
      select jsonb_build_object(
        'id',c.id,'role_key',c.role_key,'holder_player_id', case when c.holder_player_id = actor_id then c.holder_player_id else null end,
        'holder_name', case when c.holder_player_id = actor_id then (select h.name from squadquest.players h where h.id=c.holder_player_id) else null end,
        'prompt',c.prompt,'round',c.round,'opened_at',c.opened_at,'deadline_at',c.deadline_at,'status','open',
        'replies',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'player_id',r.player_id,'name',p.name,'avatar_id',p.avatar_id,'content',r.content,'round',r.round,'created_at',r.created_at) order by r.created_at),'[]'::jsonb)
          from squadquest.gameplay_power_replies r join squadquest.players p on p.id=r.player_id where r.challenge_id=c.id),
        'my_reply_submitted',exists(select 1 from squadquest.gameplay_power_replies r where r.challenge_id=c.id and r.player_id=actor_id and r.round=c.round),
        'i_am_holder',c.holder_player_id=actor_id,
        'expected_replies',(select count(*)::int - 1 from squadquest.gameplay_assignments a where a.team_id=t.id)
      ) from squadquest.gameplay_power_challenges c
      where c.team_id=t.id and c.status='open' and now()<=c.deadline_at
      order by c.opened_at desc limit 1) else null end,
    'power_challenge_status', case when current_phase='mission' and (actor_is_host or t.id=actor_team_id) then (
      select jsonb_build_object(
        'role_key',c.role_key,'round',c.round,'deadline_at',c.deadline_at,
        'replies_count',(select count(*)::int from squadquest.gameplay_power_replies r where r.challenge_id=c.id and r.round=c.round),
        'expected_replies',(select count(*)::int - 1 from squadquest.gameplay_assignments a where a.team_id=t.id)
      ) from squadquest.gameplay_power_challenges c
      where c.team_id=t.id and c.status='open' and now()<=c.deadline_at
      order by c.opened_at desc limit 1) else null end,
    'power_outcomes', case when (t.id=actor_team_id and not actor_is_host and current_phase='mission') or current_phase in ('pitch','vote','reveal','results','reflection','complete') then (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',o.id,'role_key',o.role_key,'prompt',o.prompt,'status',o.effective_status,
        'holder_name', case when current_phase in ('reveal','results','reflection','complete') then (select h.name from squadquest.players h where h.id=o.holder_player_id) else null end,
        'round',o.round,
        'replies',(select coalesce(jsonb_agg(jsonb_build_object('name',p.name,'content',r.content) order by r.created_at),'[]'::jsonb)
          from squadquest.gameplay_power_replies r join squadquest.players p on p.id=r.player_id where r.challenge_id=o.id and r.round=o.round),
        'chosen_reply',(select jsonb_build_object('name',p.name,'content',r.content)
          from squadquest.gameplay_power_replies r join squadquest.players p on p.id=r.player_id where r.id=o.chosen_reply_id)
      ) order by o.opened_at),'[]'::jsonb)
      from (
        select c.id,c.role_key,c.prompt,c.holder_player_id,c.round,c.opened_at,c.chosen_reply_id,
        case when c.status = 'open' and now() > c.deadline_at then (
          case when exists (select 1 from squadquest.gameplay_power_replies r where r.challenge_id = c.id and r.round = c.round)
            then 'approved' else 'unanswered' end
        ) else c.status end as effective_status
        from squadquest.gameplay_power_challenges c where c.team_id=t.id
      ) o where o.effective_status in ('approved','unanswered')) else '[]'::jsonb end,
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

-- Same privileges as 0011, restated for the recreated function.
revoke all on function squadquest.get_squadquest_game_state(uuid) from public, anon;

grant execute on function squadquest.get_squadquest_game_state(uuid) to authenticated;

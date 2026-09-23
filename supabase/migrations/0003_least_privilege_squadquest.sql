-- Remove legacy ACLs carried over when the empty SquadQuest tables moved out of public.
revoke all on schema squadquest from public, anon;
revoke all on all tables in schema squadquest from public, anon;
revoke all on all sequences in schema squadquest from public, anon;
revoke all on all routines in schema squadquest from public, anon;
revoke all on type squadquest.game_phase from public, anon;

grant usage on schema squadquest to authenticated, service_role;
grant usage on type squadquest.game_phase to authenticated, service_role;
grant select, insert, update on squadquest.rooms to authenticated;
grant select, insert, update, delete on squadquest.players to authenticated;
grant all on all tables in schema squadquest to service_role;
grant all on all sequences in schema squadquest to service_role;
grant execute on all routines in schema squadquest to service_role;
grant execute on function squadquest.is_squadquest_room_member(uuid) to authenticated, service_role;

alter default privileges for role postgres in schema squadquest
  revoke all on tables from public, anon;
alter default privileges for role postgres in schema squadquest
  revoke all on sequences from public, anon;
alter default privileges for role postgres in schema squadquest
  revoke execute on routines from public, anon;

alter default privileges for role postgres in schema squadquest
  grant select, insert, update, delete on tables to authenticated;
alter default privileges for role postgres in schema squadquest
  grant execute on routines to authenticated;
alter default privileges for role postgres in schema squadquest
  grant all on tables to service_role;
alter default privileges for role postgres in schema squadquest
  grant all on sequences to service_role;
alter default privileges for role postgres in schema squadquest
  grant execute on routines to service_role;

export type GamePhase = "waiting" | "identity" | "teams" | "roles" | "mission" | "pitch" | "vote" | "reveal" | "results" | "reflection" | "complete";
export type IdentityStep = "collecting" | "voting" | "reveal" | "complete";
export type PlayerKind = "host" | "player";
export type MissionStep = "understand" | "diverge" | "decide" | "build" | "adapt" | "complete";

export type SecretRoleKey = "devils_advocate" | "visionary" | "customer_voice";

export type MissionNote = {
  id: string;
  player_id: string;
  content: string;
  created_at: string;
  votes_count?: number;
  is_own?: boolean;
};

export type MissionSolution = {
  name?: string;
  for_user?: string;
  problem?: string;
  value?: string;
  how_works?: string[];
  why_use?: string;
  adaptation?: string;
  sketches?: string[];
};

export type GameplayTeamView = {
  id: string;
  name: string;
  team_number: number;
  mission: { persona: string; problem: string; restriction: string } | null;
  step: MissionStep | null;
  step_started_at: string;
  chaos: { title: string; text: string } | null;
  pitch_order: number | null;
  selected_idea_id: string | null;
  members: Array<{ id: string; name: string; avatar_id: string; role_key: SecretRoleKey | null }>;
  hypotheses: MissionNote[] | null;
  ideas: MissionNote[] | null;
  my_idea_votes: string[] | null;
  finalists: MissionNote[] | null;
  my_decision_vote: string | null;
  decision_votes: Array<{ idea_id: string; votes_count: number }> | null;
  solution: MissionSolution | null;
  power_used: boolean | null;
  power_actions: Array<{ name: string; avatar_id: string; content: string; created_at: string }> | null;
  hypothesis_count: number;
  idea_count: number;
  idea_ballots: number;
  member_count: number;
  solution_ballots: number;
  hypotheses_ready: boolean;
  ideas_ready: boolean;
  decision_ready: boolean;
  solution_ready: boolean;
};

export type GameplayState = {
  phase: GamePhase;
  identity_step: IdentityStep;
  is_host: boolean;
  state_version: number;
  phase_started_at: string;
  chaos_released_at: string | null;
  pitch_index: number;
  my_team_id: string | null;
  my_role: SecretRoleKey | null;
  my_power_used: boolean | null;
  teams: GameplayTeamView[];
  revealed_roles: Array<{ id: string; name: string; avatar_id: string; team_id: string; role_key: SecretRoleKey }>;
  final_ballot_count: number;
  reflection_count: number;
  my_final_votes: Array<{ category: "buy" | "absurd" | "solution"; team_id: string }>;
  my_reflection_sent: boolean;
  results: Array<{ category: "buy" | "absurd" | "solution"; team_id: string; votes: number }>;
  reflections: Array<{ author: string; recipient: string; content: string }>;
};

export type IdentityPromptKey = "hidden_story" | "dream" | "unexpected_story";

export type IdentityAnswers = Record<IdentityPromptKey, string>;

export type DemoIdentityRound = {
  number: number;
  promptKey: IdentityPromptKey;
  answer: string;
  authorPlayerId: string;
  votes: Record<string, string>;
  revealed?: boolean;
};

export type DemoIdentityGame = {
  submissions: Record<string, IdentityAnswers>;
  rounds: DemoIdentityRound[];
};

export type IdentityPlayerOption = Pick<Player, "id" | "name" | "avatar" | "kind">;

export type IdentityRoundView = {
  number: number;
  promptKey: IdentityPromptKey;
  answer: string;
  votesCount: number;
  hasVoted: boolean;
  author: IdentityPlayerOption | null;
};

export type IdentityViewState = {
  step: IdentityStep;
  isHost: boolean;
  selfSubmitted: boolean;
  submittedCount: number;
  participantCount: number;
  players: IdentityPlayerOption[];
  currentRound: IdentityRoundView | null;
};

export type Avatar = {
  id: string;
  emoji: string;
  color: string;
};

export type Player = {
  id: string;
  sessionId: string;
  name: string;
  avatar: Avatar;
  kind: PlayerKind;
  online: boolean;
  lastSeenAt: number;
};

export type Room = {
  id: string;
  code: string;
  phase: GamePhase;
  players: Player[];
  transport: "local" | "supabase";
  identityStep?: IdentityStep;
  demoIdentity?: DemoIdentityGame;
};

export type PersistedRoom = Omit<Room, "transport"> & { transport?: "local" };

export const AVATARS: Avatar[] = [
  { id: "comet", emoji: "☄️", color: "#f8a4b8" },
  { id: "rocket", emoji: "🚀", color: "#9b8cff" },
  { id: "fox", emoji: "🦊", color: "#ffbd7a" },
  { id: "owl", emoji: "🦉", color: "#81d4c8" },
  { id: "robot", emoji: "🤖", color: "#9ac8ff" },
  { id: "spark", emoji: "✨", color: "#f7da76" },
  { id: "alien", emoji: "👽", color: "#b8e986" },
  { id: "unicorn", emoji: "🦄", color: "#dba5ff" },
];

export const MAX_PLAYERS = 6;

export function avatarById(id: string): Avatar {
  return AVATARS.find((avatar) => avatar.id === id) ?? AVATARS[0];
}

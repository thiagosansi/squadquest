"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { FINAL_VOTE_CATEGORIES, MISSION_STEPS, POWER_BONUS_SECONDS, POWER_WINDOWS, SECRET_ROLES, formatClock, secondsUntil } from "@/lib/gameplay";
import type { GameplayState, GameplayTeamView, GamePhase, MissionSolution, MissionStep, Player, SecretRoleKey } from "@/lib/types";
import type { SquadQuestSupabaseClient } from "@/lib/supabase";
import { SketchPad } from "@/components/SketchPad";
import { GameTrail } from "@/components/GameTrail";
import { PowerChallenge, PowerOutcomes } from "@/components/PowerChallenge";

type GameplayRpcName =
  | "draw_squadquest_teams" | "start_squadquest_roles" | "start_squadquest_mission"
  | "add_squadquest_mission_entry" | "vote_squadquest_ideas" | "vote_squadquest_finalist"
  | "update_squadquest_solution" | "advance_squadquest_mission" | "release_squadquest_chaos"
  | "use_squadquest_role_power" | "start_squadquest_pitches" | "advance_squadquest_pitch"
  | "submit_squadquest_final_vote" | "start_squadquest_reveal" | "start_squadquest_results"
  | "start_squadquest_reflection" | "submit_squadquest_reflection" | "finish_squadquest_game"
  | "reply_squadquest_power_challenge" | "resolve_squadquest_power_challenge";

type Props = {
  roomId: string;
  roomCode: string;
  phase: GamePhase;
  self: Player;
  supabase: SquadQuestSupabaseClient | null;
  onExit: () => void;
};

type SolutionDraft = Required<MissionSolution>;

const EMPTY_SOLUTION: SolutionDraft = {
  name: "", for_user: "", problem: "", value: "", how_works: ["", "", ""], why_use: "", adaptation: "", sketches: ["", "", ""],
};
const EMPTY_TEAMS: GameplayTeamView[] = [];

const PHASE_LABELS: Record<GamePhase, string> = {
  waiting: "Sala de espera", identity: "Quem é?", teams: "Times sorteados", roles: "Papel secreto",
  mission: "Missão", pitch: "Pitch", vote: "Votação", reveal: "Reveal", results: "Resultado",
  reflection: "Fechamento", complete: "Fim da missão",
};

const POWER_PLACEHOLDERS: Record<SecretRoleKey, string> = {
  devils_advocate: "Qual falha importante seu time precisa enfrentar?",
  visionary: "Como seria uma alternativa 10x mais ousada?",
  customer_voice: "Eu não usaria essa solução porque…",
};

function readState(value: unknown): GameplayState | null {
  if (!value || typeof value !== "object" || !Array.isArray((value as { teams?: unknown }).teams)) return null;
  return value as GameplayState;
}

function teamMembers(teams: GameplayTeamView[]): GameplayTeamView["members"] {
  return teams.flatMap((team) => team.members);
}

function powerBonusSeconds(team: GameplayTeamView): number {
  return Math.max(0, team.step_power_count ?? 0) * POWER_BONUS_SECONDS;
}

function durationForStep(step: MissionStep): number {
  return MISSION_STEPS[step].minutes * 60;
}

function durationWithBonus(team: GameplayTeamView): number {
  if (!team.step) return 0;
  return durationForStep(team.step) + powerBonusSeconds(team);
}

function elapsedForStep(team: GameplayTeamView, now: number): number {
  const startedAt = new Date(team.step_started_at).getTime();
  if (!Number.isFinite(startedAt)) return 0;
  return Math.max(0, Math.floor((now - startedAt) / 1000));
}

function remainingForStep(team: GameplayTeamView, now: number): number {
  if (!team.step) return 0;
  return Math.max(0, durationWithBonus(team) - elapsedForStep(team, now));
}

type PowerWindowState = { status: "closed" | "upcoming" | "open" | "last_call"; opensIn?: number; needsValue?: boolean };

function powerWindow(team: GameplayTeamView, role: SecretRoleKey, now: number, solutionValue: string): PowerWindowState {
  const spec = POWER_WINDOWS[role];
  if (!team.step || !spec.steps.includes(team.step)) return { status: "closed" };
  const elapsed = elapsedForStep(team, now);
  if (elapsed < spec.opensAfterSeconds) return { status: "upcoming", opensIn: spec.opensAfterSeconds - elapsed };
  if (spec.requiresValue && !solutionValue.trim()) return { status: "upcoming", needsValue: true };
  return { status: remainingForStep(team, now) <= 60 ? "last_call" : "open" };
}

function stepMilestone(team: GameplayTeamView, now: number): { label: string; seconds: number } | null {
  const elapsed = elapsedForStep(team, now);
  const milestone = team.step === "understand" ? { label: "Ideias liberam em", seconds: 180 - elapsed }
    : team.step === "diverge" ? { label: "Votação abre em", seconds: 120 - elapsed }
    : team.step === "decide" ? { label: "Desempate libera em", seconds: 180 - elapsed }
    : null;
  return milestone && milestone.seconds > 0 ? milestone : null;
}

function GmStepTimer({ team, now }: { team: GameplayTeamView; now: number }) {
  if (!team.step || team.step === "complete") return null;
  const elapsed = elapsedForStep(team, now);
  const duration = durationWithBonus(team);
  const bonus = powerBonusSeconds(team);
  const remaining = remainingForStep(team, now);
  const over = duration > 0 && elapsed >= duration;
  const progress = duration > 0 ? Math.min(100, Math.round((elapsed / duration) * 100)) : 0;
  const milestone = stepMilestone(team, now);
  const challenge = team.power_challenge_status;
  return <div className={`quest-gm-timer ${over ? "over" : ""}`}>
    <div><span>⏱</span><strong>{over ? `+${formatClock(elapsed - duration)}` : formatClock(remaining)}</strong><small>{over ? "além do tempo sugerido" : "restantes na etapa"}</small></div>
    {milestone && <em>{milestone.label} {formatClock(milestone.seconds)}</em>}
    <em>Poderes {team.powers_used_count ?? 0}/{team.member_count}{bonus > 0 ? ` · +${formatClock(bonus)} poder` : ""}</em>
    {challenge && <em className="quest-gm-challenge">⚡ Desafio · {SECRET_ROLES[challenge.role_key].name} · {formatClock(secondsUntil(challenge.deadline_at, now))} · {challenge.replies_count}/{challenge.expected_replies} responderam</em>}
    <div className="quest-gm-timer-bar"><i style={{ width: `${progress}%` }} /></div>
  </div>;
}

function TextArea({ label, value, onChange, placeholder, maxLength = 300, rows = 3 }: {
  label: string;
  value: string;
  onChange: (next: string) => void;
  placeholder?: string;
  maxLength?: number;
  rows?: number;
}) {
  return <label className="quest-field"><span>{label}</span><textarea value={value} onChange={(event) => onChange(event.target.value)} placeholder={placeholder} maxLength={maxLength} rows={rows} /></label>;
}

function QuestHeader({ roomCode, phase, onExit }: { roomCode: string; phase: GamePhase; onExit: () => void }) {
  return <header className="topbar quest-topbar">
    <div className="brand"><span className="brand-mark">✦</span><span>SquadQuest</span></div>
    <div className="quest-top-meta"><span>{PHASE_LABELS[phase]}</span><strong>{roomCode}</strong></div>
    <button className="text-button" onClick={onExit} type="button">Sair</button>
  </header>;
}

function TeamMissionCard({ team }: { team: GameplayTeamView }) {
  if (!team.mission) return null;
  return <div className="quest-mission-card">
    <div className="quest-section-kicker">MISSÃO DO TIME {team.name.toUpperCase()}</div>
    <div className="quest-prompt-grid">
      <div><small>👤 PERSONA</small><strong>{team.mission.persona}</strong></div>
      <div><small>💥 PROBLEMA</small><strong>{team.mission.problem}</strong></div>
      <div><small>🔒 RESTRIÇÃO</small><strong>{team.mission.restriction}</strong></div>
    </div>
  </div>;
}

function TeamRoster({ team, revealRoles = false }: { team: GameplayTeamView; revealRoles?: boolean }) {
  return <div className="quest-roster">{team.members.map((member) => {
    const role = (revealRoles || member.role_key) ? member.role_key : null;
    return <div className="quest-roster-person" key={member.id}>
      <span className="mini-avatar" style={{ background: "#302b50" }}>{({ comet: "☄️", rocket: "🚀", fox: "🦊", owl: "🦉", robot: "🤖", spark: "✨", alien: "👽", unicorn: "🦄" } as Record<string, string>)[member.avatar_id] ?? "✦"}</span>
      <span>{member.name}</span>
      {role ? <small>{SECRET_ROLES[role].icon} {SECRET_ROLES[role].name}</small> : <small>jogador</small>}
    </div>;
  })}</div>;
}

export function QuestStages({ roomId, roomCode, phase: roomPhase, self, supabase, onExit }: Props) {
  const [state, setState] = useState<GameplayState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [now, setNow] = useState(Date.now());
  const [hypothesisText, setHypothesisText] = useState("");
  const [ideaText, setIdeaText] = useState("");
  const [selectedIdeas, setSelectedIdeas] = useState<string[]>([]);
  const [solutionDrafts, setSolutionDrafts] = useState<Record<string, SolutionDraft>>({});
  const [solutionDirty, setSolutionDirty] = useState<Record<string, boolean>>({});
  const [powerOpen, setPowerOpen] = useState(false);
  const [powerText, setPowerText] = useState("");
  const [recipientId, setRecipientId] = useState("");
  const [reflectionText, setReflectionText] = useState("");
  const [chaosBurst, setChaosBurst] = useState(false);
  const chaosSeenRef = useRef<boolean | null>(null);

  const refresh = useCallback(async () => {
    if (!supabase) return;
    const { data, error: stateError } = await supabase.rpc("get_squadquest_game_state", { target_room_id: roomId });
    if (stateError) {
      setError(stateError.message);
      return;
    }
    const next = readState(data);
    if (next) setState(next);
  }, [roomId, supabase]);

  useEffect(() => {
    void refresh();
    if (!supabase) return;
    const channel = supabase.channel(`quest-state:${roomId}`)
      .on("postgres_changes", { event: "UPDATE", schema: "squadquest", table: "rooms", filter: `id=eq.${roomId}` }, () => void refresh())
      .subscribe();
    const fallback = window.setInterval(() => void refresh(), 5000);
    return () => {
      window.clearInterval(fallback);
      void supabase.removeChannel(channel);
    };
  }, [refresh, roomId, supabase]);

  useEffect(() => {
    const clock = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(clock);
  }, []);

  const execute = useCallback(async (name: GameplayRpcName, args: Record<string, unknown> = {}) => {
    if (!supabase) {
      setError("Conecte o Supabase para continuar a missão multiplayer.");
      return false;
    }
    setBusy(true);
    setError("");
    try {
      const { error: actionError } = await supabase.rpc(name as never, args as never);
      if (actionError) throw actionError;
      await refresh();
      return true;
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : "Não foi possível concluir esta ação.");
      return false;
    } finally {
      setBusy(false);
    }
  }, [refresh, supabase]);

  const teams = state?.teams ?? EMPTY_TEAMS;
  const myTeam = teams.find((team) => team.id === state?.my_team_id) ?? null;
  const selectedIdea = myTeam?.selected_idea_id ? (myTeam.ideas?.find((idea) => idea.id === myTeam.selected_idea_id) ?? myTeam.finalists?.find((idea) => idea.id === myTeam.selected_idea_id) ?? null) : null;
  const participants = useMemo(() => teamMembers(teams), [teams]);
  const myRole = state?.my_role ? SECRET_ROLES[state.my_role] : null;
  const myPowerWindow = myTeam && state?.my_role ? powerWindow(myTeam, state.my_role, now, (solutionDrafts[myTeam.id] ?? myTeam.solution)?.value ?? "") : null;
  const currentPitch = teams.find((team) => team.pitch_order === state?.pitch_index) ?? null;
  const isHost = self.kind === "host";

  useEffect(() => {
    if (!myTeam?.solution || !myTeam.id || solutionDirty[myTeam.id]) return;
    setSolutionDrafts((current) => ({
      ...current,
      [myTeam.id]: { ...EMPTY_SOLUTION, ...myTeam.solution, how_works: [0, 1, 2].map((index) => myTeam.solution?.how_works?.[index] ?? ""), sketches: [0, 1, 2].map((index) => { const sketch = myTeam.solution?.sketches?.[index]; return typeof sketch === "string" ? sketch : ""; }) },
    }));
  }, [myTeam?.id, myTeam?.solution, solutionDirty]);

  const chaosPresent = isHost ? Boolean(state?.chaos_released_at) : Boolean(myTeam?.chaos);
  useEffect(() => {
    if (!state) return;
    const previous = chaosSeenRef.current;
    chaosSeenRef.current = chaosPresent;
    if (previous === false && chaosPresent) setChaosBurst(true);
  }, [state, chaosPresent]);

  useEffect(() => {
    if (!chaosBurst) return;
    const timer = window.setTimeout(() => setChaosBurst(false), 1200);
    return () => window.clearTimeout(timer);
  }, [chaosBurst]);

  useEffect(() => {
    if (recipientId || !self.id) return;
    const firstAvailable = participants.find((person) => person.id !== self.id);
    if (firstAvailable) setRecipientId(firstAvailable.id);
  }, [participants, recipientId, self.id]);

  function updateSolution<K extends keyof SolutionDraft>(key: K, value: SolutionDraft[K]) {
    if (!myTeam) return;
    setSolutionDrafts((current) => ({ ...current, [myTeam.id]: { ...(current[myTeam.id] ?? EMPTY_SOLUTION), [key]: value } }));
    setSolutionDirty((current) => ({ ...current, [myTeam.id]: true }));
  }

  function submitEntry(event: FormEvent<HTMLFormElement>, kind: "hypothesis" | "idea", content: string) {
    event.preventDefault();
    if (!content.trim()) return;
    void execute("add_squadquest_mission_entry", { target_room_id: roomId, entry_kind: kind, entry_content: content.trim() })
      .then((success) => {
        if (!success) return;
        if (kind === "hypothesis") setHypothesisText("");
        else setIdeaText("");
      });
  }

  function saveSolution(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!myTeam) return;
    const current = solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION;
    void execute("update_squadquest_solution", { target_room_id: roomId, solution_data: current })
      .then((success) => { if (success) setSolutionDirty((dirty) => ({ ...dirty, [myTeam.id]: false })); });
  }

  function submitPower(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void execute("use_squadquest_role_power", { target_room_id: roomId, action_text: powerText.trim() })
      .then((success) => { if (success) { setPowerText(""); setPowerOpen(false); } });
  }

  function submitReflection(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!recipientId || !reflectionText.trim()) return;
    void execute("submit_squadquest_reflection", { target_room_id: roomId, target_player_id: recipientId, reflection_text: reflectionText.trim() })
      .then((success) => { if (success) setReflectionText(""); });
  }

  function toggleIdea(id: string) {
    setSelectedIdeas((current) => current.includes(id) ? current.filter((item) => item !== id) : current.length < 2 ? [...current, id] : [current[1], id]);
  }

  const completedPlayers = teams.reduce((count, team) => count + team.member_count, 0);
  function powerGate(team: GameplayTeamView, now: number): { powersPending: number; timeOver: boolean; releaseIn: number } {
    const powersPending = Math.max(0, team.member_count - (team.powers_used_count ?? 0));
    const elapsed = elapsedForStep(team, now);
    const duration = durationWithBonus(team);
    return { powersPending, timeOver: elapsed >= duration, releaseIn: Math.max(0, duration - elapsed) };
  }

  /** Segundos restantes de um desafio de poder aberto no time; 0 quando não há desafio ou o prazo venceu. */
  function challengeRemaining(team: GameplayTeamView, now: number): number {
    return team.power_challenge_status ? secondsUntil(team.power_challenge_status.deadline_at, now) : 0;
  }

  function canAdvanceTeam(team: GameplayTeamView, now: number): boolean {
    if (!team.step) return false;
    if (challengeRemaining(team, now) > 0) return false;
    if (team.step === "understand") return team.hypotheses_ready;
    if (team.step === "diverge") return team.ideas_ready;
    if (team.step === "decide") return team.decision_ready;
    const gate = powerGate(team, now);
    const powersOk = gate.powersPending === 0 || gate.timeOver;
    if (team.step === "build") return powersOk && Boolean(state?.chaos_released_at) && !team.chaos && team.solution_ready;
    if (team.step === "adapt") return powersOk && team.solution_ready;
    return false;
  }

  function advanceHint(team: GameplayTeamView, now: number): string {
    if (!team.step) return "Etapa em andamento";
    const challengeSeconds = challengeRemaining(team, now);
    if (challengeSeconds > 0) return `Desafio de poder em andamento · ${formatClock(challengeSeconds)}`;
    if (team.step === "understand") return team.hypotheses_ready ? "Cada pessoa registrou uma hipótese" : `${team.hypothesis_count} hipóteses coletivas · falta cobrir o time todo`;
    if (team.step === "diverge") return `${team.idea_count}/${team.member_count * 2} ideias · ${team.idea_ballots}/${team.member_count} votos enviados`;
    if (team.step === "decide") return team.selected_idea_id ? "Finalista escolhido pelo time" : team.decision_ready ? "Tempo esgotado · o sistema vai desempatar" : "O time decide entre as duas finalistas";
    const gate = powerGate(team, now);
    if ((team.step === "build" || team.step === "adapt") && gate.powersPending > 0 && !gate.timeOver) return `Faltam ${gate.powersPending} ${gate.powersPending === 1 ? "poder" : "poderes"} · liberação em ${formatClock(gate.releaseIn)}`;
    if (team.step === "build") return team.chaos ? "A equipe precisa adaptar antes de concluir" : !state?.chaos_released_at ? "A carta de caos precisa ser lançada antes de concluir" : "Canvas compartilhado: nome, proposta e protótipo";
    if (team.step === "adapt") return "A adaptação à carta de caos precisa estar descrita";
    return "Concluído";
  }

  function renderRoleCard(roleKey: SecretRoleKey | null, large = false) {
    if (!roleKey) return null;
    const role = SECRET_ROLES[roleKey];
    return <div className={`quest-role-card ${large ? "large" : ""}`}>
      <div className="quest-role-icon">{role.icon}</div>
      <div><div className="quest-section-kicker">PAPEL SECRETO · SÓ VOCÊ VÊ</div><h2>{role.name}</h2><strong>{role.power}</strong><p>{role.prompt}</p></div>
    </div>;
  }

  if (!supabase) return <main className="page-shell quest-shell"><QuestHeader roomCode={roomCode} phase={roomPhase} onExit={onExit} /><div className="quest-content"><p>As fases seguintes precisam de conexão com Supabase. Volte ao lobby e configure o backend para continuar.</p></div></main>;

  return <>
    {chaosBurst && <div className="chaos-burst" aria-hidden="true" />}
    {myTeam?.power_challenge && !isHost && <PowerChallenge challenge={myTeam.power_challenge} roomId={roomId} now={now} busy={busy} error={error} execute={execute} />}
    <main className={`page-shell quest-shell ${chaosBurst ? "chaos-shake" : ""}`}>
    <div className="ambient-orb orb-one" /><div className="ambient-orb orb-two" />
    <QuestHeader roomCode={roomCode} phase={state?.phase ?? roomPhase} onExit={onExit} />
    {isHost && state && <GameTrail
      phase={state.phase}
      teams={teams}
      chaosReleased={Boolean(state.chaos_released_at)}
      pitchIndex={state.pitch_index}
      finalBallots={state.final_ballot_count}
      participants={participants.length}
      reflections={state.reflection_count}
      now={now}
    />}
    {!state ? <section className="quest-content"><div className="sync-message"><i /><span>Sincronizando a missão…</span></div>{error && <div className="error-message">{error}</div>}</section> : <>

      {state.phase === "teams" && <section className="quest-content">
        <div className="quest-heading"><div className="eyebrow"><span /> O SORTEIO FOI FEITO</div><h1>O acaso reuniu<br /><em>dois esquadrões.</em></h1><p>Missões diferentes, vozes diferentes. O Game Master fica de fora e conduz a aventura.</p></div>
        <div className="quest-team-grid">{teams.map((team) => <article className="quest-team-card panel-card" key={team.id}>
          <div className="quest-team-title"><span>✦</span><h2>Time {team.name}</h2><small>{team.member_count} {team.member_count === 1 ? "jogador" : "jogadores"}</small></div>
          <TeamRoster team={team} /><TeamMissionCard team={team} />
        </article>)}</div>
        {isHost ? <div className="quest-host-action panel-card"><p>Times equilibrados e missões sorteadas. O próximo passo revela um papel secreto para cada jogador.</p><button className="primary-button" disabled={busy} onClick={() => void execute("start_squadquest_roles", { target_room_id: roomId })} type="button">Revelar papéis secretos <span>→</span></button></div> : <p className="quest-wait-note">O Game Master vai revelar os papéis. Cada pessoa verá apenas o seu.</p>}
      </section>}

      {state.phase === "roles" && <section className="quest-content quest-centered">
        <div className="quest-heading"><div className="eyebrow centered"><span /> IDENTIDADE EM SEGREDO <span /></div><h1>Seu jeito de jogar<br /><em>é só seu.</em></h1><p>Seu time recebeu uma missão absurda. Seu papel secreto traz uma habilidade para mudar o rumo.</p></div>
        {isHost ? <div className="quest-host-action panel-card"><div className="quest-role-icon">🎮</div><h2>Os jogadores receberam seus papéis.</h2><p>Você não recebe um papel nem entra em nenhum time. Quando todos estiverem prontos, inicie a missão.</p><button className="primary-button" disabled={busy} onClick={() => void execute("start_squadquest_mission", { target_room_id: roomId })} type="button">Abrir salas de missão <span>→</span></button></div> : <>{renderRoleCard(state.my_role, true)}<p className="quest-secret-note">Guarde seu papel. Ele só será revelado depois da votação final.</p></>}
      </section>}

      {state.phase === "mission" && <section className={`quest-content ${isHost ? "quest-gm-content" : ""}`}>
        {isHost ? <>
          <div className="quest-heading"><div className="eyebrow"><span /> GAME MASTER · VISÃO DA MISSÃO</div><h1>As equipes estão<br /><em>construindo.</em></h1><p>Você vê o andamento e conduz as viradas, sem acompanhar textos privados nem avaliar ninguém.</p></div>
          <div className="quest-gm-grid">{teams.map((team) => <article className="quest-gm-team panel-card" key={team.id}>
            <div className="quest-team-title"><span>✦</span><h2>Time {team.name}</h2><small>{team.step ? `${MISSION_STEPS[team.step].icon} ${MISSION_STEPS[team.step].label}` : "Etapa em andamento"}</small></div>
            <GmStepTimer team={team} now={now} />
            <TeamRoster team={team} />
            <TeamMissionCard team={team} />
            <div className="quest-progress-copy">{advanceHint(team, now)}</div>
            <div className="quest-gm-buttons">
              {team.step === "build" && !state.chaos_released_at && <button className="secondary-button" disabled={busy || elapsedForStep(team, now) < 240} onClick={() => void execute("release_squadquest_chaos", { target_room_id: roomId, target_team_id: team.id })} type="button">{elapsedForStep(team, now) < 240 ? `🔥 Caos em ${formatClock(240 - elapsedForStep(team, now))}` : "🔥 Lançar caos aqui"}</button>}
              <button className="primary-button" disabled={busy || !canAdvanceTeam(team, now)} onClick={() => void execute("advance_squadquest_mission", { target_room_id: roomId, target_team_id: team.id })} type="button">{team.step === "complete" ? "Missão concluída" : `Avançar ${team.name}`} <span>→</span></button>
            </div>
          </article>)}</div>
          {!state.chaos_released_at && teams.some((team) => team.step === "build") && <div className="quest-host-action panel-card chaos-wide"><div><strong>🔥 Carta de caos</strong><p>Escolha um time acima ou lance a mesma carta para os dois. Cada equipe precisa adaptar a solução antes de apresentar.</p></div><button className="secondary-button" disabled={busy || !teams.every((team) => team.step === "build" && elapsedForStep(team, now) >= 240)} onClick={() => void execute("release_squadquest_chaos", { target_room_id: roomId, target_team_id: null })} type="button">Lançar para os dois times</button></div>}
          <div className="quest-host-action panel-card"><p>Quando os dois times concluírem, você sorteia quem apresenta primeiro.</p><button className="primary-button" disabled={busy || !teams.length || teams.some((team) => team.step !== "complete")} onClick={() => void execute("start_squadquest_pitches", { target_room_id: roomId })} type="button">Começar os pitches <span>→</span></button></div>
        </> : myTeam?.step ? <>
          <div className="quest-heading"><div className="eyebrow"><span /> MISSÃO EM EQUIPE · TIME {myTeam.name.toUpperCase()}</div><h1>{MISSION_STEPS[myTeam.step].icon} {MISSION_STEPS[myTeam.step].label}<br /><em>mão na massa.</em></h1><p>{MISSION_STEPS[myTeam.step].instruction}</p></div>
          <div className="quest-timer-row"><div><span>⏱</span><strong>{formatClock(remainingForStep(myTeam, now))}</strong>{powerBonusSeconds(myTeam) > 0 && <b className="quest-timer-bonus">+{formatClock(powerBonusSeconds(myTeam))} poder</b>}<small>tempo sugerido nesta etapa</small></div><span>O Game Master conduz as transições</span></div>
          <div className="quest-mission-layout">
            <section className="quest-workspace panel-card">
              <TeamMissionCard team={myTeam} />
              <div className="quest-team-members"><TeamRoster team={myTeam} /></div>

              {myTeam.chaos && <div className="quest-chaos-card"><span>🔥 CAOS · {myTeam.chaos.title}</span><p>{myTeam.chaos.text}</p></div>}
              {myRole && renderRoleCard(state.my_role)}

              {myTeam.step === "understand" && <>
                <div className="quest-instruction-note"><strong>Primeiros 3 minutos: só hipóteses.</strong><span>{formatClock(Math.max(0, 180 - Math.floor((now - new Date(myTeam.step_started_at).getTime()) / 1000)))} até liberar ideias.</span></div>
                <form className="quest-entry-form" onSubmit={(event) => submitEntry(event, "hypothesis", hypothesisText)}>
                  <TextArea label="Qual é realmente o problema desta pessoa?" value={hypothesisText} onChange={setHypothesisText} placeholder="Talvez não seja que ela esquece a data; talvez não saiba como se preparar…" maxLength={500} />
                  <button className="primary-button" disabled={busy || hypothesisText.trim().length < 3} type="submit">Adicionar hipótese <span>＋</span></button>
                </form>
                {Math.floor((now - new Date(myTeam.step_started_at).getTime()) / 1000) >= 180 && <form className="quest-entry-form compact" onSubmit={(event) => submitEntry(event, "idea", ideaText)}>
                  <TextArea label="Ideia inicial (opcional)" value={ideaText} onChange={setIdeaText} placeholder="Uma solução possível, agora que entendemos melhor…" maxLength={500} />
                  <button className="secondary-button" disabled={busy || ideaText.trim().length < 3} type="submit">Adicionar ideia <span>＋</span></button>
                </form>}
                <BoardNotes label="Hipóteses do time" notes={myTeam.hypotheses ?? []} team={myTeam} />
              </>}

              {myTeam.step === "diverge" && <>
                <div className="quest-instruction-note"><strong>Escrita silenciosa por 2 minutos.</strong><span>{formatClock(Math.max(0, 120 - Math.floor((now - new Date(myTeam.step_started_at).getTime()) / 1000)))} restantes</span><small>Depois, conversem e cada pessoa escolhe duas ideias que não sejam suas.</small></div>
                <form className="quest-entry-form" onSubmit={(event) => submitEntry(event, "idea", ideaText)}>
                  <TextArea label="Adicione uma ideia" value={ideaText} onChange={setIdeaText} placeholder="Uma proposta inesperada é bem-vinda…" maxLength={500} />
                  <button className="primary-button" disabled={busy || ideaText.trim().length < 3} type="submit">Adicionar ideia <span>＋</span></button>
                </form>
                <BoardNotes label={`Ideias · selecione 2 (${selectedIdeas.length}/2)`} notes={myTeam.ideas ?? []} team={myTeam} selectable selected={selectedIdeas} onToggle={toggleIdea} />
                {!myTeam.my_idea_votes?.length ? <button className="secondary-button full-button" disabled={busy || selectedIdeas.length !== 2 || Math.floor((now - new Date(myTeam.step_started_at).getTime()) / 1000) < 120} onClick={() => void execute("vote_squadquest_ideas", { target_room_id: roomId, idea_ids: selectedIdeas })} type="button">Enviar meus dois votos <span>✓</span></button> : <p className="quest-vote-done">✓ Seus dois votos foram registrados em segredo.</p>}
              </>}

              {myTeam.step === "decide" && <>
                <p className="quest-copy-center">As duas ideias finalistas. Unanimidade não é necessária.</p>
                <div className="quest-finalists">{(myTeam.finalists ?? []).map((idea) => <button className={`quest-finalist ${myTeam.my_decision_vote === idea.id ? "selected" : ""}`} key={idea.id} disabled={busy || Boolean(myTeam.my_decision_vote)} onClick={() => void execute("vote_squadquest_finalist", { target_room_id: roomId, idea_id: idea.id })} type="button"><strong>{idea.content}</strong><small>{idea.votes_count} votos na etapa anterior</small></button>)}</div>
                {myTeam.selected_idea_id && <div className="quest-selection">{selectedIdea ? <>✦ O time escolheu: «{selectedIdea.content}». O Game Master vai abrir o canvas.</> : "✦ O time escolheu uma ideia. O Game Master vai abrir o canvas."}</div>}
                {myTeam.my_decision_vote && !myTeam.selected_idea_id && <p className="quest-vote-done">Seu voto está registrado; esperando o time.</p>}
              </>}

              {(myTeam.step === "build" || myTeam.step === "adapt") && selectedIdea && <div className="quest-mission-card quest-chosen-idea"><div className="quest-section-kicker">IDEIA ESCOLHIDA PELO TIME</div><strong>{selectedIdea.content}</strong>{typeof selectedIdea.votes_count === "number" && <small>{selectedIdea.votes_count} votos</small>}</div>}
              {(myTeam.step === "build" || myTeam.step === "adapt") && <PowerOutcomes outcomes={myTeam.power_outcomes} />}
              {(myTeam.step === "build" || myTeam.step === "adapt") && <form className="quest-solution-form" onSubmit={saveSolution}>
                <div className="quest-section-kicker">CANVAS COLABORATIVO · O TIME EDITA JUNTO</div>
                <label className="quest-field"><span>Nome do produto</span><input value={(solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).name} onChange={(event) => updateSolution("name", event.target.value)} placeholder="Um nome que dê vontade de conhecer" maxLength={80} /></label>
                <label className="quest-field"><span>Para quem?</span><input value={(solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).for_user} onChange={(event) => updateSolution("for_user", event.target.value)} placeholder={myTeam.mission?.persona ?? "Sua persona"} maxLength={160} /></label>
                <label className="quest-field"><span>Qual problema resolve?</span><input value={(solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).problem} onChange={(event) => updateSolution("problem", event.target.value)} placeholder={myTeam.mission?.problem ?? "O problema central"} maxLength={240} /></label>
                <TextArea label="Nossa proposta de valor" value={(solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).value} onChange={(value) => updateSolution("value", value)} placeholder="Ajudamos [persona] a…" maxLength={400} />
                <div className="quest-section-kicker">PROTÓTIPO RÁPIDO · TRÊS MOMENTOS</div>
                <div className="quest-storyboard">{[0, 1, 2].map((index) => <div className="quest-storyboard-frame" key={index}><span>{index + 1}</span><TextArea label={`Passo ${index + 1}`} value={(solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).how_works[index] ?? ""} onChange={(value) => updateSolution("how_works", (solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).how_works.map((item, itemIndex) => itemIndex === index ? value : item))} placeholder={index === 0 ? "A pessoa começa por…" : "E então…"} maxLength={180} rows={2} /><SketchPad label={`Desenho do passo ${index + 1}`} value={(solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).sketches[index] ?? ""} onChange={(next) => updateSolution("sketches", (solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).sketches.map((item, itemIndex) => itemIndex === index ? next : item))} /></div>)}</div>
                <TextArea label="Por que alguém usaria isso?" value={(solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).why_use} onChange={(value) => updateSolution("why_use", value)} placeholder="O que torna isso útil ou irresistível?" maxLength={300} />
                {myTeam.step === "adapt" && <TextArea label="Como adaptamos o produto ao caos?" value={(solutionDrafts[myTeam.id] ?? EMPTY_SOLUTION).adaptation} onChange={(value) => updateSolution("adaptation", value)} placeholder="O que mudou sem destruir a solução?" maxLength={300} />}
                <button className="primary-button full-button" disabled={busy} type="submit">{solutionDirty[myTeam.id] ? "Salvar canvas compartilhado" : "Salvar alterações"}<span>↗</span></button>
              </form>}

              {myTeam.power_actions?.length ? <div className="quest-power-feed"><div className="quest-section-kicker">O TIME ACIONOU</div>{myTeam.power_actions.map((action, index) => <div className="quest-power-event" key={`${action.created_at}-${index}`}><span>{action.avatar_id}</span><p><strong>{action.name}</strong> · {action.content}</p></div>)}</div> : null}
              {myRole && state.my_role && myPowerWindow && !state.my_power_used && myTeam.step !== "complete" && <div className={`quest-power-box ${myPowerWindow.status}`}>
                <div className="quest-section-kicker">SEU PODER SECRETO</div>
                {myPowerWindow.status === "upcoming" && <><p>{myRole.power}</p><small>{myPowerWindow.needsValue ? "Escreva a proposta de valor para liberar" : `Abre em ${formatClock(myPowerWindow.opensIn ?? 0)}`} · {POWER_WINDOWS[state.my_role].moment}</small></>}
                {myPowerWindow.status === "closed" && <><p>{myRole.power}</p><small>Vale em: {POWER_WINDOWS[state.my_role].moment}</small></>}
                {(myPowerWindow.status === "open" || myPowerWindow.status === "last_call") && <>
                  <strong className="quest-power-moment">{myPowerWindow.status === "last_call" ? "⚠ Último momento" : "✦ Seu momento é agora"}</strong>
                  {!powerOpen ? <button className="secondary-button" onClick={() => setPowerOpen(true)} type="button">{myRole.power} <span>✦</span></button> : <form onSubmit={submitPower}><div className="quest-section-kicker">USAR PODER · UMA VEZ NA PARTIDA</div><TextArea label={myRole.prompt} value={powerText} onChange={setPowerText} placeholder={POWER_PLACEHOLDERS[state.my_role]} maxLength={400} /><button className="primary-button" disabled={busy || powerText.trim().length < 8} type="submit">Acionar habilidade <span>✦</span></button></form>}
                </>}
              </div>}
            </section>
            <aside className="quest-side-panel panel-card"><div className="quest-section-kicker">SUA EQUIPE</div><TeamRoster team={myTeam} /><div className="quest-step-list">{(["understand", "diverge", "decide", "build", ...(myTeam.chaos ? ["adapt"] : [])] as MissionStep[]).map((step) => <div className={myTeam.step === step ? "active" : myTeam.step === "complete" || (myTeam.step === "adapt" && step !== "adapt") ? "done" : ""} key={step}><span>{MISSION_STEPS[step].icon}</span><small>{MISSION_STEPS[step].label}</small></div>)}</div><p>Falem no Meet/Teams/Discord. O SquadQuest mantém o desafio, o canvas e o ritmo sincronizados.</p></aside>
          </div>
        </> : <p className="quest-wait-note">O Game Master está preparando as equipes.</p>}
      </section>}

      {state.phase === "pitch" && <section className="quest-content quest-centered">
        <div className="quest-heading"><div className="eyebrow centered"><span /> TODO MUNDO DE VOLTA À SALA PRINCIPAL <span /></div><h1>Pitch time.<br /><em>Quem começa?</em></h1><p>A ordem foi sorteada. Cada equipe tem até três minutos para contar a história do produto.</p></div>
        {currentPitch ? <article className="quest-pitch-card panel-card"><div className="round-label">PITCH {state.pitch_index} DE {teams.length} · TIME {currentPitch.name.toUpperCase()}</div><TeamRoster team={currentPitch} revealRoles={false} /><TeamMissionCard team={currentPitch} /><SolutionSummary team={currentPitch} /></article> : <div className="quest-pitch-card panel-card"><p>Preparando a próxima apresentação…</p></div>}
        {isHost ? <button className="primary-button quest-main-cta" disabled={busy} onClick={() => void execute("advance_squadquest_pitch", { target_room_id: roomId })} type="button">{state.pitch_index >= teams.length ? "Abrir votação anônima" : "Próximo pitch"}<span>→</span></button> : <p className="quest-wait-note">O Game Master conduz as apresentações e abrirá a votação ao final.</p>}
      </section>}

      {state.phase === "vote" && <section className="quest-content quest-centered">
        <div className="quest-heading"><div className="eyebrow centered"><span /> VOTAÇÃO ANÔNIMA <span /></div><h1>Três aplausos.<br /><em>Nenhum placar geral.</em></h1><p>Reconheça ideias diferentes. Você pode escolher um time diferente em cada categoria; não há vencedor único.</p></div>
        {isHost ? <div className="quest-host-action panel-card"><h2>Votos em andamento</h2><p>O resultado fica oculto até todos votarem. Você não vota nem vê a escolha de ninguém.</p><div className="quest-vote-progress">{state.final_ballot_count} de {completedPlayers * 3} escolhas registradas</div><button className="primary-button" disabled={busy || state.final_ballot_count < completedPlayers * 3} onClick={() => void execute("start_squadquest_reveal", { target_room_id: roomId })} type="button">Revelar papéis secretos <span>→</span></button></div> : <div className="quest-vote-categories">{FINAL_VOTE_CATEGORIES.map((category) => {
          const saved = state.my_final_votes.find((vote) => vote.category === category.key);
          return <article className="quest-vote-category panel-card" key={category.key}><div className="quest-section-kicker">{category.icon} {category.label.toUpperCase()}</div>{saved ? <div className="quest-vote-done">✓ Voto anônimo registrado para {teams.find((team) => team.id === saved.team_id)?.name ?? "um time"}.</div> : <div className="quest-choice-list">{teams.map((team) => <button className="quest-choice" key={team.id} disabled={busy} onClick={() => void execute("submit_squadquest_final_vote", { target_room_id: roomId, vote_category: category.key, target_team_id: team.id })} type="button"><span>✦ Time {team.name}</span><i>→</i></button>)}</div>}</article>;
        })}</div>}
      </section>}

      {state.phase === "reveal" && <section className="quest-content quest-centered">
        <div className="quest-heading"><div className="eyebrow centered"><span /> HORA DA VERDADE <span /></div><h1>Por trás de cada ideia,<br /><em>uma pessoa do time.</em></h1><p>Os papéis eram secretos. Agora todo mundo descobre quem estava fazendo o quê.</p></div>
        <div className="quest-role-reveal-grid">{state.revealed_roles.map((person) => <article className="quest-reveal-person panel-card" key={person.id}><span className="reveal-avatar" style={{ background: "#302b50" }}>{SECRET_ROLES[person.role_key].icon}</span><strong>{person.name}</strong><small>Time {teams.find((team) => team.id === person.team_id)?.name}</small><h3>{SECRET_ROLES[person.role_key].name}</h3><p>{SECRET_ROLES[person.role_key].power}</p></article>)}</div>
        {isHost ? <button className="primary-button quest-main-cta" disabled={busy} onClick={() => void execute("start_squadquest_results", { target_room_id: roomId })} type="button">Ver os aplausos do time <span>→</span></button> : <p className="quest-wait-note">O Game Master já vai mostrar o resultado das categorias.</p>}
      </section>}

      {state.phase === "results" && <section className="quest-content quest-centered">
        <div className="quest-heading"><div className="eyebrow centered"><span /> RECONHECIMENTO DO TIME <span /></div><h1>Três histórias.<br /><em>Três motivos para aplaudir.</em></h1><p>Sem pontos individuais e sem um único time campeão. Aqui estão as escolhas anônimas do grupo.</p></div>
        <div className="quest-awards">{FINAL_VOTE_CATEGORIES.map((category) => {
          const rows = teams.map((team) => ({ team, votes: state.results.find((result) => result.category === category.key && result.team_id === team.id)?.votes ?? 0 }));
          const high = Math.max(...rows.map((row) => row.votes));
          const winners = rows.filter((row) => row.votes === high && high > 0);
          return <article className="quest-award panel-card" key={category.key}><span>{category.icon}</span><small>{category.label}</small><h2>{winners.map((row) => `Time ${row.team.name}`).join(" + ") || "Um aplauso para todas as equipes"}</h2><div className="quest-award-bars">{rows.map((row) => <div key={row.team.id}><span>Time {row.team.name}</span><i><b style={{ width: `${high ? row.votes / high * 100 : 0}%` }} /></i><strong>{row.votes}</strong></div>)}</div></article>;
        })}</div>
        {isHost ? <button className="primary-button quest-main-cta" disabled={busy} onClick={() => void execute("start_squadquest_reflection", { target_room_id: roomId })} type="button">Fechar com uma descoberta <span>→</span></button> : <p className="quest-wait-note">O Game Master vai abrir o fechamento da missão.</p>}
      </section>}

      {state.phase === "reflection" && <section className="quest-content quest-centered">
        <div className="quest-heading"><div className="eyebrow centered"><span /> ÚLTIMA RODADA · CONEXÃO <span /></div><h1>O que descobri<br /><em>sobre alguém?</em></h1><p>Uma frase sincera fecha a missão melhor que qualquer ranking. Sua mensagem só aparece para todo mundo no final.</p></div>
        {isHost ? <div className="quest-host-action panel-card"><div className="quest-role-icon">❤️</div><h2>O time está escrevendo suas descobertas.</h2><p>As mensagens ficam privadas até todas as pessoas enviarem. Nenhum nome é marcado como “pronto”.</p><div className="quest-vote-progress">{state.reflection_count} de {completedPlayers} mensagens recebidas</div><button className="primary-button" disabled={busy || state.reflection_count < completedPlayers} onClick={() => void execute("finish_squadquest_game", { target_room_id: roomId })} type="button">Encerrar e revelar mensagens <span>→</span></button></div> : state.my_reflection_sent ? <div className="quest-host-action panel-card"><div className="quest-role-icon">✉️</div><h2>Sua descoberta está guardada.</h2><p>Ela será revelada junto com as mensagens do restante do time.</p></div> : <form className="quest-reflection-form panel-card" onSubmit={submitReflection}>
          <label className="quest-field"><span>Escolha alguém desta partida</span><select value={recipientId} onChange={(event) => setRecipientId(event.target.value)}>{participants.filter((person) => person.id !== self.id).map((person) => <option key={person.id} value={person.id}>{person.name}</option>)}</select></label>
          <TextArea label="Uma coisa que descobri ou passei a admirar nessa pessoa…" value={reflectionText} onChange={setReflectionText} placeholder="Uma frase curta, gentil e específica." maxLength={400} />
          <button className="primary-button full-button" disabled={busy || reflectionText.trim().length < 8 || !recipientId} type="submit">Guardar minha mensagem <span>❤️</span></button>
        </form>}
      </section>}

      {state.phase === "complete" && <section className="quest-content quest-centered">
        <div className="quest-heading"><div className="eyebrow centered"><span /> MISSÃO CONCLUÍDA <span /></div><h1>Vocês construíram<br /><em>mais que um produto.</em></h1><p>Uma última rodada de gentileza para levar da tela para a próxima conversa.</p></div>
        <div className="quest-reflection-wall">{state.reflections.map((reflection, index) => <article className="quest-reflection-card panel-card" key={`${reflection.author}-${index}`}><div className="quest-section-kicker">{reflection.author} → {reflection.recipient}</div><p>“{reflection.content}”</p><span>❤️</span></article>)}</div>
        <button className="secondary-button quest-main-cta" onClick={onExit} type="button">Voltar ao início</button>
      </section>}

      {error && <div className="error-message quest-error" role="alert">{error}</div>}
    </>}
    <footer className="home-footer"><span>1 Game Master · até 6 jogadores · sem placar individual</span><span>SquadQuest · {PHASE_LABELS[state?.phase ?? roomPhase]}</span></footer>
    </main>
  </>;
}

function BoardNotes({ label, notes, team, selectable = false, selected = [], onToggle }: {
  label: string;
  notes: NonNullable<GameplayTeamView["ideas"]>;
  team: GameplayTeamView;
  selectable?: boolean;
  selected?: string[];
  onToggle?: (id: string) => void;
}) {
  return <section className="quest-board-notes"><div className="quest-section-kicker">{label}</div>{notes.length ? <div className="quest-note-list">{notes.map((note) => {
    const author = team.members.find((member) => member.id === note.player_id);
    return <div className={`quest-note ${note.is_own ? "own" : ""} ${selected.includes(note.id) ? "selected" : ""}`} key={note.id}>
      {selectable ? <button className="quest-note-select" onClick={() => onToggle?.(note.id)} type="button" aria-label={`Selecionar ideia de ${author?.name ?? "jogador"}`}>{selected.includes(note.id) ? "✓" : "＋"}</button> : null}
      <p>{note.content}</p><small>{author?.name ?? "Pessoa do time"}{typeof note.votes_count === "number" ? ` · ${note.votes_count} votos` : ""}</small>
    </div>;
  })}</div> : <div className="quest-empty-note">As contribuições aparecem aqui para todo o time.</div>}</section>;
}

function SolutionSummary({ team }: { team: GameplayTeamView }) {
  const solution = team.solution;
  if (!solution) return <div className="quest-empty-note">A apresentação está sendo preparada.</div>;
  return <div className="quest-solution-summary"><div className="quest-section-kicker">{solution.name || `Produto do time ${team.name}`}</div><h3>{solution.value || "Proposta de valor em construção"}</h3><p><strong>Para quem:</strong> {solution.for_user || team.mission?.persona || "Sua persona"}</p><p><strong>Problema:</strong> {solution.problem || team.mission?.problem || "O problema central"}</p><div className="quest-storyboard">{(solution.how_works ?? []).map((step, index) => <div className="quest-storyboard-frame" key={index}><span>{index + 1}</span><p>{step || "…"}</p><SketchPad label={`Desenho do passo ${index + 1}`} value={solution.sketches?.[index] ?? ""} readOnly /></div>)}</div><PowerOutcomes outcomes={team.power_outcomes} /><p><strong>Por que usariam:</strong> {solution.why_use || "…"}</p>{team.chaos && <div className="quest-chaos-card"><span>🔥 {team.chaos.title}</span><p>{team.chaos.text}</p><small>{solution.adaptation}</small></div>}</div>;
}

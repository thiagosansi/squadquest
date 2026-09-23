"use client";

import { MISSION_STEPS, POWER_BONUS_SECONDS, formatClock, secondsUntil } from "@/lib/gameplay";
import type { GamePhase, GameplayTeamView, IdentityStep } from "@/lib/types";

export type GameTrailProps = {
  phase: GamePhase;
  identityStep?: IdentityStep;
  playerCount?: number;
  storiesSubmitted?: number;
  storiesNeeded?: number;
  teams?: GameplayTeamView[];
  chaosReleased?: boolean;
  pitchIndex?: number;
  finalBallots?: number;
  participants?: number;
  reflections?: number;
  now?: number;
};

type TrailState = "done" | "active" | "upcoming";
type NextStep = { action: string; blocker?: string };

const PHASE_ORDER: GamePhase[] = ["waiting", "identity", "teams", "roles", "mission", "pitch", "vote", "reveal", "results", "reflection", "complete"];

const TRAIL: Array<{ key: string; phase: GamePhase; icon: string; label: string }> = [
  { key: "waiting", phase: "waiting", icon: "🛋️", label: "Lobby" },
  { key: "identity", phase: "identity", icon: "🕵️", label: "Quem é?" },
  { key: "teams", phase: "teams", icon: "🎲", label: "Times" },
  { key: "roles", phase: "roles", icon: "🎭", label: "Papéis" },
  { key: "mission", phase: "mission", icon: "🛠️", label: "Missão" },
  { key: "chaos", phase: "mission", icon: "🔥", label: "Caos" },
  { key: "pitch", phase: "pitch", icon: "🎤", label: "Pitches" },
  { key: "vote", phase: "vote", icon: "🗳️", label: "Votação" },
  { key: "reveal", phase: "reveal", icon: "✨", label: "Reveal" },
  { key: "results", phase: "results", icon: "🏆", label: "Resultados" },
  { key: "reflection", phase: "reflection", icon: "❤️", label: "Reflexão" },
  { key: "complete", phase: "complete", icon: "🏁", label: "Fim" },
];

const CHAOS_UNLOCK_SECONDS = 240;

function phaseIndex(phase: GamePhase): number {
  return PHASE_ORDER.indexOf(phase);
}

function elapsedSeconds(team: GameplayTeamView, now: number): number {
  const startedAt = new Date(team.step_started_at).getTime();
  return Number.isFinite(startedAt) ? Math.max(0, Math.floor((now - startedAt) / 1000)) : 0;
}

function stepDuration(team: GameplayTeamView): number {
  if (!team.step) return 0;
  return MISSION_STEPS[team.step].minutes * 60 + Math.max(0, team.step_power_count ?? 0) * POWER_BONUS_SECONDS;
}

function plural(count: number, singular: string, pluralForm: string): string {
  return `${count} ${count === 1 ? singular : pluralForm}`;
}

/** Motivo pelo qual o GM ainda não consegue avançar o time (espelha canAdvanceTeam/advanceHint de QuestStages). */
export function teamBlocker(team: GameplayTeamView, chaosReleased: boolean, now: number): string | null {
  if (!team.step || team.step === "complete") return null;
  const challengeSeconds = team.power_challenge_status ? secondsUntil(team.power_challenge_status.deadline_at, now) : 0;
  if (challengeSeconds > 0) return `desafio de poder em andamento · ${formatClock(challengeSeconds)}`;
  if (team.step === "understand") return team.hypotheses_ready ? null : `${team.hypothesis_count} hipóteses · falta cobrir o time`;
  if (team.step === "diverge") return team.ideas_ready ? null : `${team.idea_count}/${team.member_count * 2} ideias · ${team.idea_ballots}/${team.member_count} votos`;
  if (team.step === "decide") return team.decision_ready ? null : "time decidindo a finalista";
  const elapsed = elapsedSeconds(team, now);
  const duration = stepDuration(team);
  const powersPending = Math.max(0, team.member_count - (team.powers_used_count ?? 0));
  if (powersPending > 0 && elapsed < duration) return `${plural(powersPending, "poder pendente", "poderes pendentes")} · libera em ${formatClock(duration - elapsed)}`;
  if (team.step === "build") {
    if (team.chaos) return "precisa adaptar ao caos";
    if (!chaosReleased) return "caos ainda não lançado";
    return team.solution_ready ? null : "canvas incompleto";
  }
  if (team.step === "adapt") return team.solution_ready ? null : "adaptação ao caos pendente";
  return null;
}

export function nextStep(props: GameTrailProps): NextStep[] {
  const { phase, identityStep, playerCount, storiesSubmitted, storiesNeeded, chaosReleased = false, pitchIndex = 0, finalBallots = 0, participants = 0, reflections = 0 } = props;
  const teams = props.teams ?? [];
  const now = props.now ?? Date.now();
  const missing = (min: number) => {
    if (playerCount === undefined || playerCount >= min) return undefined;
    const gap = min - playerCount;
    return `${gap === 1 ? "falta" : "faltam"} ${plural(gap, "jogador", "jogadores")} (mínimo ${min})`;
  };

  switch (phase) {
    case "waiting":
      return [{ action: "Iniciar Quem é?", blocker: missing(2) }];
    case "identity": {
      if (identityStep === "voting") return [{ action: "Aguardar os palpites e revelar" }];
      if (identityStep === "reveal") return [{ action: "Sortear a próxima história" }];
      if (identityStep === "complete") return [{ action: "Sortear os times", blocker: missing(4) }];
      const pending = storiesSubmitted !== undefined && storiesNeeded !== undefined && storiesSubmitted < storiesNeeded;
      return [{ action: "Sortear uma história", blocker: pending ? `${storiesSubmitted} de ${storiesNeeded} histórias enviadas` : undefined }];
    }
    case "teams":
      return [{ action: "Revelar os papéis secretos" }];
    case "roles":
      return [{ action: "Abrir as salas de missão" }];
    case "mission": {
      if (teams.length > 0 && teams.every((team) => team.step === "complete")) return [{ action: "Começar os pitches" }];
      const lines: NextStep[] = [];
      const chaosReady = !chaosReleased && teams.some((team) => team.step === "build" && elapsedSeconds(team, now) >= CHAOS_UNLOCK_SECONDS);
      if (chaosReady) lines.push({ action: "Lançar a carta de caos" });
      teams.filter((team) => team.step !== "complete").slice(0, 2).forEach((team) => {
        lines.push({ action: `Avançar ${team.name}`, blocker: teamBlocker(team, chaosReleased, now) ?? undefined });
      });
      return lines.length ? lines : [{ action: "Aguardar as equipes" }];
    }
    case "pitch":
      return [{ action: pitchIndex >= teams.length ? "Abrir a votação anônima" : "Próximo pitch" }];
    case "vote": {
      const needed = participants * 3;
      return [{ action: "Fechar a votação", blocker: needed > 0 && finalBallots < needed ? `${finalBallots} de ${needed} votos` : undefined }];
    }
    case "reveal":
      return [{ action: "Mostrar os resultados" }];
    case "results":
      return [{ action: "Abrir a reflexão final" }];
    case "reflection":
      return [{ action: "Encerrar a partida", blocker: participants > 0 && reflections < participants ? `${reflections} de ${participants} reflexões` : undefined }];
    case "complete":
      return [{ action: "Partida encerrada" }];
  }
}

function trailState(key: string, itemPhase: GamePhase, props: GameTrailProps): TrailState {
  const current = phaseIndex(props.phase);
  const own = phaseIndex(itemPhase);
  if (key === "chaos") {
    if (current > own) return "done";
    if (current < own) return "upcoming";
    if (props.chaosReleased) return "done";
    return (props.teams ?? []).some((team) => team.step === "build") ? "active" : "upcoming";
  }
  if (own < current) return "done";
  if (own === current) return "active";
  return "upcoming";
}

export function GameTrail(props: GameTrailProps) {
  const teams = props.teams ?? [];
  const missionSub = props.phase === "mission" && teams.length
    ? teams.map((team) => `${team.name} · ${team.step ? MISSION_STEPS[team.step].label : "…"}`).join(" / ")
    : null;
  const steps = nextStep(props);

  return <nav className="game-trail" aria-label="Trilha do jogo">
    <ol>{TRAIL.map((item) => {
      const state = trailState(item.key, item.phase, props);
      const sub = item.key === "mission" ? missionSub : null;
      return <li className={state} key={item.key} aria-current={state === "active" ? "step" : undefined}>
        <span aria-hidden="true">{item.icon}</span>
        <small>{item.label}</small>
        {sub && <em title={sub}>{sub}</em>}
      </li>;
    })}</ol>
    <div className="game-trail-next">
      <b>PRÓXIMO PASSO</b>
      {steps.map((step, index) => <span className="game-trail-step" key={`${step.action}-${index}`}>
        <strong>{step.action}</strong>
        {step.blocker && <small>{step.blocker}</small>}
      </span>)}
    </div>
  </nav>;
}

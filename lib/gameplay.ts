import type { MissionStep, SecretRoleKey } from "@/lib/types";

export const SECRET_ROLES: Record<SecretRoleKey, { name: string; icon: string; power: string; prompt: string }> = {
  devils_advocate: {
    name: "Advogado do Diabo",
    icon: "🦊",
    power: "E se estivermos errados?",
    prompt: "Registre uma falha importante que o time precisa responder.",
  },
  visionary: {
    name: "Visionário 10x",
    icon: "🔭",
    power: "Leve a ideia dez vezes mais longe.",
    prompt: "Descreva uma alternativa ousada, sem as limitações atuais.",
  },
  customer_voice: {
    name: "Voz do Cliente",
    icon: "👤",
    power: "Eu não compraria.",
    prompt: "Complete: “Eu não usaria essa solução porque…”",
  },
};

export const MISSION_STEPS: Record<MissionStep, { label: string; icon: string; minutes: number; instruction: string }> = {
  understand: {
    label: "Entender",
    icon: "🔎",
    minutes: 8,
    instruction: "Antes de propor uma solução, investiguem qual problema essa pessoa realmente enfrenta. Cada pessoa registra ao menos uma hipótese.",
  },
  diverge: {
    label: "Divergir",
    icon: "💡",
    minutes: 10,
    instruction: "Primeiro escrevam em silêncio por dois minutos. Cada pessoa adiciona pelo menos duas ideias; depois conversem e escolham duas finalistas com dois votos cada.",
  },
  decide: {
    label: "Decidir",
    icon: "🎯",
    minutes: 3,
    instruction: "Conversem sobre as duas ideias mais votadas. Unanimidade não é necessária; se empatar quando o tempo acabar, o sistema desempata.",
  },
  build: {
    label: "Construir",
    icon: "🛠️",
    minutes: 12,
    instruction: "Transformem a ideia escolhida em um produto simples, expliquem seu valor e montem um protótipo de três passos.",
  },
  adapt: {
    label: "Adaptar ao caos",
    icon: "🔥",
    minutes: 4,
    instruction: "A carta mudou as regras. Adaptem a solução sem abandonar completamente a necessidade original.",
  },
  complete: {
    label: "Missão concluída",
    icon: "✨",
    minutes: 0,
    instruction: "A solução está pronta para ser apresentada ao restante do grupo.",
  },
};

export const POWER_BONUS_SECONDS = 60;

export const POWER_WINDOWS: Record<SecretRoleKey, { steps: MissionStep[]; opensAfterSeconds: number; requiresValue: boolean; moment: string }> = {
  visionary: { steps: ["diverge"], opensAfterSeconds: 120, requiresValue: false, moment: "Divergir, depois da escrita silenciosa" },
  devils_advocate: { steps: ["decide"], opensAfterSeconds: 0, requiresValue: false, moment: "Decidir, entre as duas finalistas" },
  customer_voice: { steps: ["build", "adapt"], opensAfterSeconds: 0, requiresValue: true, moment: "Construir, com a proposta de valor escrita" },
};

/** Rótulo da marca que um desafio aprovado deixa no canvas. */
export const POWER_OUTCOME_LABELS: Record<SecretRoleKey, string> = {
  visionary: "Visão 10x",
  devils_advocate: "Risco reconhecido",
  customer_voice: "Resposta ao cliente",
};

export const POWER_CHALLENGE_TITLES: Record<SecretRoleKey, string> = {
  visionary: `Poder do ${SECRET_ROLES.visionary.name}`,
  devils_advocate: `Poder do ${SECRET_ROLES.devils_advocate.name}`,
  customer_voice: `Poder da ${SECRET_ROLES.customer_voice.name}`,
};

export const FINAL_VOTE_CATEGORIES = [
  { key: "buy", label: "Produto que eu realmente compraria", icon: "🛍️" },
  { key: "absurd", label: "Ideia mais absurda (no melhor sentido)", icon: "😂" },
  { key: "solution", label: "Solução mais criativa", icon: "💡" },
] as const;

/** Segundos inteiros até um prazo ISO; datas inválidas ou já vencidas contam como 0. */
export function secondsUntil(deadline: string, now: number): number {
  const at = new Date(deadline).getTime();
  return Number.isFinite(at) ? Math.max(0, Math.ceil((at - now) / 1000)) : 0;
}

export function formatClock(totalSeconds: number): string {
  const safeSeconds = Math.max(0, totalSeconds);
  const minutes = Math.floor(safeSeconds / 60);
  const seconds = safeSeconds % 60;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

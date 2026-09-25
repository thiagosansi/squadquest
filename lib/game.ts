import { AVATARS, MAX_TEAMS, type Avatar, type Player, type PlayerKind, type Room } from "@/lib/types";

const ROOM_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function makeId(prefix: string): string {
  return `${prefix}_${crypto.randomUUID()}`;
}

export function makeRoomCode(): string {
  const values = new Uint32Array(5);
  crypto.getRandomValues(values);
  return Array.from(values, (value) => ROOM_ALPHABET[value % ROOM_ALPHABET.length]).join("");
}

export function createPlayer(
  sessionId: string,
  name: string,
  avatar: Avatar,
  kind: PlayerKind,
): Player {
  return {
    id: makeId("player"),
    sessionId,
    name: name.trim().slice(0, 32),
    avatar,
    kind,
    online: true,
    lastSeenAt: Date.now(),
  };
}

export function createLocalRoom(code: string, host: Player): Room {
  return {
    id: makeId("room"),
    code,
    phase: "waiting",
    players: [host],
    transport: "local",
  };
}

export function defaultAvatar(seed = 0): Avatar {
  return AVATARS[seed % AVATARS.length];
}

export function isRecentlyOnline(lastSeenAt: number): boolean {
  return Date.now() - lastSeenAt < 18_000;
}

export function normalizeRoomCode(code: string): string {
  return code.replace(/[^a-z0-9]/gi, "").toUpperCase().slice(0, 5);
}

/** Maior número de times possível com `playerCount` jogadores (mínimo 2 por time, teto MAX_TEAMS). */
export function maxTeamCount(playerCount: number): number {
  return Math.min(MAX_TEAMS, Math.floor(playerCount / 2));
}

/** Contagens de times válidas (2..max); vazio quando não há gente para dois times. */
export function teamCountOptions(playerCount: number): number[] {
  const max = maxTeamCount(playerCount);
  return max < 2 ? [] : Array.from({ length: max - 1 }, (_, index) => index + 2);
}

/** Padrão: times de 3 a 4 pessoas, dentro do intervalo válido. */
export function defaultTeamCount(playerCount: number): number {
  const max = maxTeamCount(playerCount);
  return Math.min(max, Math.max(2, Math.round(playerCount / 4)));
}

/** Tamanhos dos times em rodízio (ex.: 8 jogadores em 3 times → [3, 3, 2]). */
export function teamSizes(playerCount: number, teamCount: number): number[] {
  if (teamCount < 1) return [];
  const base = Math.floor(playerCount / teamCount);
  const extra = playerCount % teamCount;
  return Array.from({ length: teamCount }, (_, index) => base + (index < extra ? 1 : 0));
}

/** "3, 3 e 2 pessoas" para a prévia do seletor de times. */
export function formatTeamSizes(sizes: number[]): string {
  if (sizes.length === 0) return "";
  if (sizes.length === 1) return `${sizes[0]} pessoas`;
  return `${sizes.slice(0, -1).join(", ")} e ${sizes[sizes.length - 1]} pessoas`;
}

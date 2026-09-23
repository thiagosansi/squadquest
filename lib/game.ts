import { AVATARS, type Avatar, type Player, type PlayerKind, type Room } from "@/lib/types";

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

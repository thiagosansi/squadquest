"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { AvatarPicker } from "@/components/AvatarPicker";
import { PlayerCard } from "@/components/PlayerCard";
import { QuestStages } from "@/components/QuestStages";
import { createLocalRoom, createPlayer, defaultAvatar, isRecentlyOnline, makeRoomCode, normalizeRoomCode } from "@/lib/game";
import { getSupabaseBrowserClient, hasSupabaseConfig } from "@/lib/supabase";
import {
  MAX_PLAYERS,
  avatarById,
  type DemoIdentityGame,
  type GamePhase,
  type IdentityAnswers,
  type IdentityPlayerOption,
  type IdentityPromptKey,
  type IdentityStep,
  type IdentityViewState,
  type Player,
  type Room,
} from "@/lib/types";
import type { SquadQuestSupabaseClient } from "@/lib/supabase";

type EntryMode = "create" | "join";
type Screen = "home" | "lobby" | "identity" | "quest";

const ROOM_STORAGE_PREFIX = "squadquest:room:";
const SESSION_KEY = "squadquest:session";
const ACTIVE_ROOM_KEY = "squadquest:active-room";

async function ensureAnonymousSession(client: SquadQuestSupabaseClient): Promise<string> {
  const { data: current } = await client.auth.getSession();
  if (current.session?.user) return current.session.user.id;
  const { data, error } = await client.auth.signInAnonymously();
  if (error || !data.user) throw error ?? new Error("Sessão anônima indisponível.");
  return data.user.id;
}

function getSessionId(): string {
  if (typeof window === "undefined") return "server-session";
  const existing = window.sessionStorage.getItem(SESSION_KEY);
  if (existing) return existing;
  const session = crypto.randomUUID();
  window.sessionStorage.setItem(SESSION_KEY, session);
  return session;
}

function getRoomStorageKey(code: string): string {
  return `${ROOM_STORAGE_PREFIX}${code}`;
}

function serializeRoom(room: Room): string {
  return JSON.stringify({ ...room, transport: "local" });
}

function readLocalRoom(code: string): Room | null {
  if (typeof window === "undefined") return null;
  const value = window.localStorage.getItem(getRoomStorageKey(code));
  if (!value) return null;
  try {
    const parsed = JSON.parse(value) as Room;
    return { ...parsed, transport: "local" };
  } catch {
    return null;
  }
}

function saveLocalRoom(room: Room) {
  window.localStorage.setItem(getRoomStorageKey(room.code), serializeRoom(room));
  window.dispatchEvent(new StorageEvent("storage", { key: getRoomStorageKey(room.code), newValue: serializeRoom(room) }));
}

function shortError(error: unknown): string {
  const message = error instanceof Error
    ? error.message
    : typeof error === "string"
      ? error
      : error && typeof error === "object" && "message" in error && typeof error.message === "string"
        ? error.message
        : "";
  const code = error && typeof error === "object" && "code" in error && typeof error.code === "string"
    ? error.code
    : "";
  if (code === "PGRST202" || /could not find the function/i.test(message)) {
    return "As novas fases ainda não estão ativas no banco. Aplique a migration 0007 do SquadQuest no SQL Editor do Supabase e recarregue a partida.";
  }
  if (message) return message;
  return "Não foi possível concluir esta ação.";
}

const IDENTITY_PROMPTS: { key: IdentityPromptKey; label: string; hint: string }[] = [
  { key: "hidden_story", label: "Algo sobre mim que quase ninguém sabe", hint: "Uma curiosidade que o time talvez nunca tenha ouvido." },
  { key: "dream", label: "Se dinheiro não fosse problema…", hint: "O que você faria, aprenderia ou viveria?" },
  { key: "unexpected_story", label: "Uma história inesperada", hint: "Um momento engraçado, improvável ou marcante." },
];

function localIdentityView(room: Room, self: Player): IdentityViewState {
  const game = room.demoIdentity ?? { submissions: {}, rounds: [] };
  const step = room.identityStep ?? "collecting";
  const active = game.rounds.at(-1);
  const author = active && (step === "reveal" || step === "complete")
    ? room.players.find((player) => player.id === active.authorPlayerId) ?? null
    : null;
  return {
    step,
    isHost: self.kind === "host",
    selfSubmitted: Boolean(game.submissions[self.id]),
    submittedCount: Object.keys(game.submissions).length,
    participantCount: room.players.filter((player) => player.kind === "player").length,
    players: room.players.filter((player) => player.kind === "player").map(toIdentityOption),
    currentRound: active ? {
      number: active.number,
      promptKey: active.promptKey,
      answer: active.answer,
      votesCount: Object.keys(active.votes).length,
      hasVoted: Boolean(active.votes[self.id]),
      author: author ? toIdentityOption(author) : null,
    } : null,
  };
}

function toIdentityOption(player: Player): IdentityPlayerOption {
  return { id: player.id, name: player.name, avatar: player.avatar, kind: player.kind };
}

function identityViewFromRpc(value: unknown): IdentityViewState {
  const data = value && typeof value === "object" ? value as Record<string, unknown> : {};
  const players = Array.isArray(data.players) ? data.players : [];
  const toOption = (value: unknown): IdentityPlayerOption | null => {
    if (!value || typeof value !== "object") return null;
    const item = value as Record<string, unknown>;
    if (typeof item.id !== "string" || typeof item.name !== "string") return null;
    return {
      id: item.id,
      name: item.name,
      avatar: avatarById(typeof item.avatar_id === "string" ? item.avatar_id : ""),
      kind: "player",
    };
  };
  const current = data.current_round && typeof data.current_round === "object"
    ? data.current_round as Record<string, unknown>
    : null;
  const author = current ? toOption(current.author) : null;
  const key = current?.prompt_key;
  const promptKey: IdentityPromptKey = key === "dream" || key === "unexpected_story" ? key : "hidden_story";
  const step = data.step === "voting" || data.step === "reveal" || data.step === "complete" ? data.step : "collecting";
  return {
    step,
    isHost: data.is_host === true,
    selfSubmitted: data.self_submitted === true,
    submittedCount: typeof data.submitted_count === "number" ? data.submitted_count : 0,
    participantCount: typeof data.participant_count === "number" ? data.participant_count : 0,
    players: players.map(toOption).filter((player): player is IdentityPlayerOption => player !== null),
    currentRound: current && typeof current.number === "number" && typeof current.answer === "string" ? {
      number: current.number,
      promptKey,
      answer: current.answer,
      votesCount: typeof current.votes_count === "number" ? current.votes_count : 0,
      hasVoted: current.has_voted === true,
      author,
    } : null,
  };
}

export function SquadQuestApp() {
  const [screen, setScreen] = useState<Screen>("home");
  const [entryMode, setEntryMode] = useState<EntryMode>("create");
  const [name, setName] = useState("");
  const [roomCode, setRoomCode] = useState("");
  const [avatar, setAvatar] = useState(defaultAvatar());
  const [room, setRoom] = useState<Room | null>(null);
  const [selfId, setSelfId] = useState("");
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const [remoteIdentityState, setRemoteIdentityState] = useState<IdentityViewState | null>(null);

  const supabase = useMemo(() => getSupabaseBrowserClient(), []);
  const demoMode = !hasSupabaseConfig();
  const self = room?.players.find((player) => player.id === selfId);
  const isHost = self?.kind === "host";
  const onlineCount = room?.players.filter((player) => player.online).length ?? 0;
  const activeRoomId = room?.id;
  const activeRoomCode = room?.code;
  const activeTransport = room?.transport;
  const activePlayerName = self?.name;
  const identityState = room && self
    ? room.transport === "local" ? localIdentityView(room, self) : remoteIdentityState
    : null;

  const loadRemoteIdentityState = useCallback(async (roomId: string) => {
    if (!supabase) return;
    const { data, error: stateError } = await supabase.rpc("get_squadquest_identity_state", { target_room_id: roomId });
    if (stateError) {
      setError(shortError(stateError));
      return;
    }
    if (data) setRemoteIdentityState(identityViewFromRpc(data));
  }, [supabase]);

  const updateRoomState = useCallback((nextRoom: Room) => {
    setRoom(nextRoom);
    if (nextRoom.phase !== "identity") setRemoteIdentityState(null);
    setScreen(nextRoom.phase === "waiting" ? "lobby" : nextRoom.phase === "identity" ? "identity" : "quest");
  }, []);

  const setRoomPhase = useCallback(
    async (phase: GamePhase) => {
      if (!room || !self || self.kind !== "host") return;
      setBusy(true);
      setError("");
      try {
        if (phase === "identity" && room.players.filter((player) => player.kind === "player").length < 2) {
          throw new Error("Pelo menos duas pessoas precisam entrar antes de iniciar Quem é?.");
        }
        if (room.transport === "local") {
          const nextRoom = {
            ...room,
            phase,
            identityStep: "collecting" as const,
            demoIdentity: { submissions: {}, rounds: [] },
          };
          saveLocalRoom(nextRoom);
          updateRoomState(nextRoom);
        } else if (supabase) {
          const { error: updateError } = await supabase.rpc("start_squadquest_identity", { target_room_id: room.id });
          if (updateError) throw updateError;
          updateRoomState({ ...room, phase, identityStep: "collecting" });
          await loadRemoteIdentityState(room.id);
        }
      } catch (actionError) {
        setError(shortError(actionError));
      } finally {
        setBusy(false);
      }
    },
    [loadRemoteIdentityState, room, self, supabase, updateRoomState],
  );

  const syncLocalRoom = useCallback(
    (nextRoom: Room) => {
      const refreshed = {
        ...nextRoom,
        players: nextRoom.players.map((player) => ({
          ...player,
          online: isRecentlyOnline(player.lastSeenAt),
        })),
      };
      updateRoomState(refreshed);
    },
    [updateRoomState],
  );

  useEffect(() => {
    const inviteCode = new URLSearchParams(window.location.search).get("partida");
    if (inviteCode && screen === "home") {
      setEntryMode("join");
      setRoomCode(normalizeRoomCode(inviteCode));
    }
  }, [screen]);

  useEffect(() => {
    const activeCode = window.sessionStorage.getItem(ACTIVE_ROOM_KEY);
    if (!activeCode) return;
    let cancelled = false;

    const resume = async () => {
      try {
        if (demoMode) {
          const savedRoom = readLocalRoom(activeCode);
          const sessionId = getSessionId();
          const savedPlayer = savedRoom?.players.find((player) => player.sessionId === sessionId);
          if (!savedRoom || !savedPlayer || cancelled) return;
          setSelfId(savedPlayer.id);
          updateRoomState(savedRoom);
          return;
        }
        if (!supabase) return;
        const { data: auth } = await supabase.auth.getSession();
        if (!auth.session?.user) return;
        const { data: roomRow } = await supabase.from("rooms").select("id, code, phase, identity_step").eq("code", activeCode).maybeSingle();
        if (!roomRow) return;
        const { data: playerRow } = await supabase.from("players").select("id, session_id, name, avatar_id, is_host, last_seen_at").eq("room_id", roomRow.id).eq("session_id", auth.session.user.id).maybeSingle();
        if (!playerRow) return;
        const { data: playerRows } = await supabase.from("players").select("id, session_id, name, avatar_id, is_host, last_seen_at").eq("room_id", roomRow.id).order("created_at");
        if (cancelled) return;
        setSelfId(playerRow.id);
        updateRoomState({
          id: roomRow.id,
          code: roomRow.code,
          phase: roomRow.phase as GamePhase,
          identityStep: roomRow.identity_step as IdentityStep,
          players: (playerRows ?? [playerRow]).map(toPlayer),
          transport: "supabase",
        });
        if (roomRow.phase === "identity") await loadRemoteIdentityState(roomRow.id);
      } catch {
        // A stale session or an expired room falls back to the entry screen.
      }
    };
    void resume();
    return () => { cancelled = true; };
  }, [demoMode, loadRemoteIdentityState, supabase, updateRoomState]);

  useEffect(() => {
    if (!activeRoomCode || activeTransport !== "local") return;
    const storageKey = getRoomStorageKey(activeRoomCode);
    const onStorage = (event: StorageEvent) => {
      if (event.key !== storageKey || !event.newValue) return;
      try {
        syncLocalRoom(JSON.parse(event.newValue) as Room);
      } catch {
        // Ignore malformed external storage events.
      }
    };
    window.addEventListener("storage", onStorage);
    return () => {
      window.removeEventListener("storage", onStorage);
    };
  }, [activeRoomCode, activeTransport, syncLocalRoom]);

  useEffect(() => {
    if (!activeRoomId || activeTransport !== "supabase" || !supabase) return;
    const realtime = supabase
      .channel(`room:${activeRoomId}`)
      .on("postgres_changes", { event: "*", schema: "squadquest", table: "rooms", filter: `id=eq.${activeRoomId}` }, (payload) => {
        const next = payload.new as { phase?: GamePhase; identity_step?: string };
        if (next.phase) {
          setRoom((current) => current ? {
            ...current,
            phase: next.phase!,
            identityStep: next.identity_step as IdentityStep | undefined,
          } : current);
          setScreen(next.phase === "waiting" ? "lobby" : next.phase === "identity" ? "identity" : "quest");
          if (next.phase !== "identity") setRemoteIdentityState(null);
          if (next.phase === "identity") void loadRemoteIdentityState(activeRoomId);
        }
      })
      .on("postgres_changes", { event: "*", schema: "squadquest", table: "players", filter: `room_id=eq.${activeRoomId}` }, async () => {
        const { data } = await supabase.from("players").select("id, session_id, name, avatar_id, is_host, last_seen_at").eq("room_id", activeRoomId).order("created_at");
        if (data) {
          setRoom((current) => current ? { ...current, players: data.map(toPlayer) } : current);
        }
      })
      .on("presence", { event: "sync" }, () => {
        const state = realtime.presenceState<{ player_id: string }>();
        const onlineIds = new Set(Object.values(state).flat().map((entry) => entry.player_id));
        setRoom((current) => current ? {
          ...current,
          players: current.players.map((player) => ({ ...player, online: onlineIds.has(player.id) || player.id === selfId })),
        } : current);
      });
    void realtime.subscribe(async (status) => {
      if (status === "SUBSCRIBED" && selfId) {
        await realtime.track({ player_id: selfId, name: activePlayerName ?? "" });
      }
    });
    return () => {
      void supabase.removeChannel(realtime);
    };
  }, [activeRoomId, activeTransport, activePlayerName, loadRemoteIdentityState, selfId, supabase]);

  useEffect(() => {
    if (!activeRoomId || activeTransport !== "supabase" || room?.phase !== "identity") return;
    const refresh = window.setInterval(() => void loadRemoteIdentityState(activeRoomId), 3_500);
    return () => window.clearInterval(refresh);
  }, [activeRoomId, activeTransport, loadRemoteIdentityState, room?.phase]);

  useEffect(() => {
    if (!activeRoomCode || !activeTransport || !selfId) return;
    if (activeTransport !== "local") return;
    const heartbeat = window.setInterval(async () => {
      const current = readLocalRoom(activeRoomCode);
      if (!current) return;
      const now = Date.now();
      const nextRoom = { ...current, players: current.players.map((player) => (player.id === selfId ? { ...player, online: true, lastSeenAt: now } : player)) };
      saveLocalRoom(nextRoom);
      syncLocalRoom(nextRoom);
    }, 6_000);
    return () => window.clearInterval(heartbeat);
  }, [activeRoomCode, activeTransport, selfId, syncLocalRoom]);

  async function createSupabaseRoom(player: Player) {
    if (!supabase) return null;
    const { data: roomData, error: roomError } = await supabase.from("rooms").insert({ code: makeRoomCode(), phase: "waiting" }).select("id, code, phase, identity_step").single();
    if (roomError || !roomData) throw roomError ?? new Error("Sala não criada.");
    const { data: playerData, error: playerError } = await supabase.from("players").insert({ room_id: roomData.id, session_id: player.sessionId, name: player.name, avatar_id: player.avatar.id, is_host: true }).select("id, session_id, name, avatar_id, is_host, last_seen_at").single();
    if (playerError || !playerData) throw playerError ?? new Error("Game Master não criado.");
    return {
      id: roomData.id,
      code: roomData.code,
      phase: roomData.phase as GamePhase,
      identityStep: roomData.identity_step as IdentityStep,
      players: [toPlayer(playerData)],
      transport: "supabase" as const,
    };
  }

  async function joinSupabaseRoom(code: string, player: Player) {
    if (!supabase) return null;
    const { data: roomData, error: roomError } = await supabase.from("rooms").select("id, code, phase, identity_step").eq("code", code).single();
    if (roomError || !roomData) throw new Error("Partida não encontrada. Confira o código e tente novamente.");
    const { data: returningPlayer, error: returningError } = await supabase.from("players").select("id, session_id, name, avatar_id, is_host, last_seen_at").eq("room_id", roomData.id).eq("session_id", player.sessionId).maybeSingle();
    if (returningError) throw returningError;
    let playerData = returningPlayer;
    if (!playerData) {
      if (roomData.phase !== "waiting") throw new Error("Esta missão já começou; só quem já estava na sala pode voltar.");
      const { count } = await supabase.from("players").select("id", { count: "exact", head: true }).eq("room_id", roomData.id).eq("is_host", false);
      if ((count ?? 0) >= MAX_PLAYERS) throw new Error("Esta partida já está cheia.");
      const { data, error: playerError } = await supabase.from("players").insert({ room_id: roomData.id, session_id: player.sessionId, name: player.name, avatar_id: player.avatar.id, is_host: false }).select("id, session_id, name, avatar_id, is_host, last_seen_at").single();
      if (playerError || !data) throw playerError ?? new Error("Não foi possível entrar nesta partida.");
      playerData = data;
    }
    const { data: playersData } = await supabase.from("players").select("id, session_id, name, avatar_id, is_host, last_seen_at").eq("room_id", roomData.id).order("created_at");
    return {
      id: roomData.id,
      code: roomData.code,
      phase: roomData.phase as GamePhase,
      identityStep: roomData.identity_step as IdentityStep,
      players: (playersData ?? [playerData]).map(toPlayer),
      transport: "supabase" as const,
    };
  }

  async function handleEnter() {
    setError("");
    setNotice("");
    const cleanName = name.trim();
    const cleanCode = normalizeRoomCode(roomCode);
    if (cleanName.length < 2) {
      setError("Digite pelo menos 2 caracteres para o seu nome.");
      return;
    }
    if (entryMode === "join" && cleanCode.length !== 5) {
      setError("O código da partida tem 5 caracteres.");
      return;
    }
    setBusy(true);
    try {
      const sessionId = demoMode ? getSessionId() : supabase ? await ensureAnonymousSession(supabase) : getSessionId();
      const newPlayer = createPlayer(sessionId, cleanName, avatar, entryMode === "create" ? "host" : "player");
      let nextRoom: Room | null = null;
      if (demoMode) {
        if (entryMode === "create") {
          let code = makeRoomCode();
          while (readLocalRoom(code)) code = makeRoomCode();
          nextRoom = createLocalRoom(code, newPlayer);
          saveLocalRoom(nextRoom);
          setNotice("Modo demo local ativo — abra esta URL em outra aba para testar participantes.");
        } else {
          const existing = readLocalRoom(cleanCode);
          if (!existing) throw new Error("Partida não encontrada neste navegador. Crie uma sala nesta aba primeiro.");
          const returningPlayer = existing.players.find((player) => player.sessionId === sessionId);
          if (returningPlayer) {
            nextRoom = { ...existing, players: existing.players.map((player) => player.id === returningPlayer.id ? { ...player, online: true, lastSeenAt: Date.now() } : player) };
          } else {
            if (existing.phase !== "waiting") throw new Error("Esta missão já começou; só quem já estava na sala pode voltar.");
            if (existing.players.filter((player) => player.kind === "player").length >= MAX_PLAYERS) throw new Error("Esta partida já está cheia.");
            nextRoom = { ...existing, players: [...existing.players, newPlayer] };
          }
          saveLocalRoom(nextRoom);
        }
      } else {
        nextRoom = entryMode === "create" ? await createSupabaseRoom(newPlayer) : await joinSupabaseRoom(cleanCode, newPlayer);
      }
      if (!nextRoom) throw new Error("Não foi possível abrir a partida.");
      const joinedPlayer = nextRoom.players.find((player) => player.sessionId === sessionId);
      if (!joinedPlayer) throw new Error("Não foi possível vincular sua sessão à partida.");
      setSelfId(joinedPlayer.id);
      window.sessionStorage.setItem(ACTIVE_ROOM_KEY, nextRoom.code);
      updateRoomState(nextRoom);
    } catch (actionError) {
      setError(shortError(actionError));
    } finally {
      setBusy(false);
    }
  }

  async function submitIdentityAnswers(answers: IdentityAnswers) {
    if (!room || !self || self.kind === "host") return;
    setBusy(true);
    setError("");
    try {
      if (room.transport === "local") {
        const game: DemoIdentityGame = room.demoIdentity ?? { submissions: {}, rounds: [] };
        if (game.submissions[self.id]) throw new Error("Suas respostas já foram enviadas.");
        const nextRoom = {
          ...room,
          demoIdentity: { ...game, submissions: { ...game.submissions, [self.id]: answers } },
        };
        saveLocalRoom(nextRoom);
        updateRoomState(nextRoom);
      } else if (supabase) {
        const { error: submitError } = await supabase.rpc("submit_squadquest_identity_answers", {
          target_room_id: room.id,
          answer_hidden_story: answers.hidden_story,
          answer_dream: answers.dream,
          answer_unexpected_story: answers.unexpected_story,
        });
        if (submitError) throw submitError;
        await loadRemoteIdentityState(room.id);
      }
    } catch (actionError) {
      setError(shortError(actionError));
    } finally {
      setBusy(false);
    }
  }

  async function drawIdentityStory() {
    if (!room || !self || self.kind !== "host") return;
    setBusy(true);
    setError("");
    try {
      if (room.transport === "local") {
        const game: DemoIdentityGame = room.demoIdentity ?? { submissions: {}, rounds: [] };
        const participants = room.players.filter((player) => player.kind === "player");
        if (participants.length < 2 || participants.some((player) => !game.submissions[player.id])) {
          throw new Error("Aguarde pelo menos duas pessoas e as respostas de todo mundo.");
        }
        if (room.identityStep !== "collecting" && room.identityStep !== "reveal") {
          throw new Error("Conclua a etapa atual antes de sortear outra história.");
        }
        const usedAuthors = new Set(game.rounds.map((round) => round.authorPlayerId));
        const candidates = participants
          .filter((player) => !usedAuthors.has(player.id))
          .flatMap((player) => IDENTITY_PROMPTS.map((prompt) => ({
            authorPlayerId: player.id,
            promptKey: prompt.key,
            answer: game.submissions[player.id][prompt.key],
          })));
        if (game.rounds.length >= 3 || candidates.length === 0) {
          const nextRoom = { ...room, identityStep: "complete" as const };
          saveLocalRoom(nextRoom);
          updateRoomState(nextRoom);
        } else {
          const picked = candidates[Math.floor(Math.random() * candidates.length)];
          const round = {
            number: game.rounds.length + 1,
            promptKey: picked.promptKey,
            answer: picked.answer,
            authorPlayerId: picked.authorPlayerId,
            votes: {},
          };
          const nextRoom = {
            ...room,
            identityStep: "voting" as const,
            demoIdentity: { ...game, rounds: [...game.rounds, round] },
          };
          saveLocalRoom(nextRoom);
          updateRoomState(nextRoom);
        }
      } else if (supabase) {
        const { error: drawError } = await supabase.rpc("start_squadquest_identity_round", { target_room_id: room.id });
        if (drawError) throw drawError;
        await loadRemoteIdentityState(room.id);
      }
    } catch (actionError) {
      setError(shortError(actionError));
    } finally {
      setBusy(false);
    }
  }

  async function submitIdentityVote(guessedPlayerId: string) {
    if (!room || !self || self.kind === "host") return;
    setBusy(true);
    setError("");
    try {
      if (room.transport === "local") {
        const game: DemoIdentityGame = room.demoIdentity ?? { submissions: {}, rounds: [] };
        const index = game.rounds.length - 1;
        const active = game.rounds[index];
        if (!active || room.identityStep !== "voting") throw new Error("Não há uma votação aberta agora.");
        if (active.votes[self.id]) throw new Error("Seu palpite já foi enviado.");
        const rounds = [...game.rounds];
        rounds[index] = { ...active, votes: { ...active.votes, [self.id]: guessedPlayerId } };
        const nextRoom = { ...room, demoIdentity: { ...game, rounds } };
        saveLocalRoom(nextRoom);
        updateRoomState(nextRoom);
      } else if (supabase) {
        const { error: voteError } = await supabase.rpc("submit_squadquest_identity_vote", {
          target_room_id: room.id,
          guessed_player_id: guessedPlayerId,
        });
        if (voteError) throw voteError;
        await loadRemoteIdentityState(room.id);
      }
    } catch (actionError) {
      setError(shortError(actionError));
    } finally {
      setBusy(false);
    }
  }

  async function revealIdentityStory() {
    if (!room || !self || self.kind !== "host") return;
    setBusy(true);
    setError("");
    try {
      if (room.transport === "local") {
        const game: DemoIdentityGame = room.demoIdentity ?? { submissions: {}, rounds: [] };
        const index = game.rounds.length - 1;
        if (index < 0 || room.identityStep !== "voting") throw new Error("Não há uma história para revelar.");
        const nextRounds = [...game.rounds];
        const active = nextRounds[index];
        nextRounds[index] = { ...active, revealed: true };
        const nextRoom = {
          ...room,
          identityStep: active.number >= 3 ? "complete" as const : "reveal" as const,
          demoIdentity: { ...game, rounds: nextRounds },
        };
        saveLocalRoom(nextRoom);
        updateRoomState(nextRoom);
      } else if (supabase) {
        const { error: revealError } = await supabase.rpc("reveal_squadquest_identity_round", { target_room_id: room.id });
        if (revealError) throw revealError;
        await loadRemoteIdentityState(room.id);
      }
    } catch (actionError) {
      setError(shortError(actionError));
    } finally {
      setBusy(false);
    }
  }

  async function drawTeams() {
    if (!room || !self || self.kind !== "host") return;
    setBusy(true);
    setError("");
    try {
      if (room.transport !== "supabase" || !supabase) throw new Error("O sorteio dos times precisa estar conectado ao Supabase.");
      const { error: drawError } = await supabase.rpc("draw_squadquest_teams", { target_room_id: room.id });
      if (drawError) throw drawError;
      updateRoomState({ ...room, phase: "teams" });
    } catch (actionError) {
      setError(shortError(actionError));
    } finally {
      setBusy(false);
    }
  }

  async function leaveRoom() {
    if (!room || !self) return;
    if (room.transport === "local" && room.phase === "waiting") {
      const nextRoom = { ...room, players: room.players.filter((player) => player.id !== self.id) };
      saveLocalRoom(nextRoom);
    } else if (room.transport === "local") {
      const nextRoom = { ...room, players: room.players.map((player) => player.id === self.id ? { ...player, online: false, lastSeenAt: Date.now() - 20_000 } : player) };
      saveLocalRoom(nextRoom);
    } else if (supabase && room.phase === "waiting") {
      await supabase.from("players").delete().eq("id", self.id);
    }
    setRoom(null);
    setSelfId("");
    setRemoteIdentityState(null);
    setScreen("home");
    setNotice("");
    window.sessionStorage.removeItem(ACTIVE_ROOM_KEY);
  }

  async function copyInvite() {
    if (!room) return;
    const invite = `${window.location.origin}/?partida=${room.code}`;
    await navigator.clipboard?.writeText(invite);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1800);
  }

  const startButtonLabel = busy ? "Abrindo missão…" : "Iniciar Quem é?";

  if (screen === "home") {
    return (
      <main className="page-shell home-shell">
        <div className="ambient-orb orb-one" />
        <div className="ambient-orb orb-two" />
        <header className="topbar">
          <div className="brand"><span className="brand-mark">✦</span><span>SquadQuest</span></div>
          <span className={`connection-badge ${demoMode ? "demo" : "live"}`}><i />{demoMode ? "Modo demo local" : "Multiplayer conectado"}</span>
        </header>
        <section className="hero-section">
          <div className="eyebrow"><span /> TEAM BUILDING, MAS COM UMA MISSÃO</div>
          <h1>O time entra.<br /><em>A história começa.</em></h1>
          <p className="hero-copy">Uma aventura multiplayer para descobrir como o seu time pensa, decide e se adapta junto.</p>
        </section>
        <section className="entry-card">
          <div className="mode-switch" role="tablist" aria-label="Escolha como entrar">
            <button className={entryMode === "create" ? "active" : ""} onClick={() => { setEntryMode("create"); setError(""); }} type="button">Criar partida</button>
            <button className={entryMode === "join" ? "active" : ""} onClick={() => { setEntryMode("join"); setError(""); }} type="button">Entrar em uma</button>
          </div>
          <div className="entry-content">
            <div className="entry-heading">
              <span className="entry-icon">{entryMode === "create" ? "🧭" : "🎟️"}</span>
              <div><h2>{entryMode === "create" ? "Você será o Game Master" : "Qual é o código da missão?"}</h2><p>{entryMode === "create" ? "Crie a sala, convide até 6 pessoas e conduza a aventura." : "Peça o código de 5 caracteres para quem criou a partida."}</p></div>
            </div>
            {entryMode === "join" && <label className="field-label">Código da partida<input className="code-input" value={roomCode} onChange={(event) => setRoomCode(normalizeRoomCode(event.target.value))} placeholder="F7K2P" maxLength={5} autoCapitalize="characters" /></label>}
            <label className="field-label">Seu nome<input value={name} onChange={(event) => setName(event.target.value)} placeholder="Como o time te chama?" maxLength={32} onKeyDown={(event) => { if (event.key === "Enter") void handleEnter(); }} /></label>
            <div className="field-label">Escolha seu avatar<AvatarPicker value={avatar} onChange={setAvatar} /></div>
            {error && <div className="error-message" role="alert">{error}</div>}
            {notice && <div className="notice-message">{notice}</div>}
            <button className="primary-button full-button" disabled={busy} onClick={() => void handleEnter()} type="button">{busy ? "Preparando…" : entryMode === "create" ? "Criar minha partida" : "Entrar na partida"}<span>→</span></button>
            <p className="privacy-note">Sem login. Sem ranking individual. Só o time e a missão.</p>
          </div>
        </section>
        <footer className="home-footer"><span>7 pessoas · 1 missão · infinitas histórias</span><span>v0.3 · Jogo completo</span></footer>
      </main>
    );
  }

  if (!room || !self) return null;

  if (screen === "identity") {
    return <IdentityScreen
      room={room}
      self={self}
      state={identityState}
      busy={busy}
      error={error}
      onBack={leaveRoom}
      onSubmit={submitIdentityAnswers}
      onDraw={drawIdentityStory}
      onVote={submitIdentityVote}
      onReveal={revealIdentityStory}
      onDrawTeams={drawTeams}
    />;
  }

  if (screen === "quest") return <QuestStages
    roomId={room.id}
    roomCode={room.code}
    phase={room.phase}
    self={self}
    supabase={supabase}
    onExit={leaveRoom}
  />;

  return (
    <main className="page-shell lobby-shell">
      <div className="ambient-orb orb-one" /><div className="ambient-orb orb-two" />
      <header className="topbar lobby-topbar">
        <div className="brand"><span className="brand-mark">✦</span><span>SquadQuest</span></div>
        <div className="room-pill"><span>SALA</span><strong>{room.code}</strong><button onClick={() => void copyInvite()} type="button" aria-label="Copiar convite">{copied ? "✓" : "⧉"}</button></div>
        <button className="text-button" onClick={() => void leaveRoom()} type="button">Sair</button>
      </header>
      <section className="lobby-content">
        <div className="lobby-intro"><div className="eyebrow"><span /> SALA DE ESPERA</div><h1>O time está se formando.</h1><p>Compartilhe o código e espere todo mundo entrar na missão.</p></div>
        <div className="lobby-grid">
          <section className="roster-panel panel-card">
            <div className="panel-heading"><div><h2>Quem está aqui?</h2><p><span className="live-dot" /> {onlineCount} de 7 conectados</p></div><span className="roster-count">{room.players.filter((player) => player.kind === "player").length}/{MAX_PLAYERS}</span></div>
            <div className="player-grid">{room.players.map((player) => <PlayerCard key={player.id} player={player} />)}{Array.from({ length: Math.max(0, MAX_PLAYERS - room.players.filter((player) => player.kind === "player").length) }).map((_, index) => <div className="empty-player" key={`empty-${index}`}><span>＋</span><small>Aguardando jogador</small></div>)}</div>
          </section>
          <aside className="host-panel panel-card">
            {isHost ? <><div className="host-panel-icon">🎮</div><h2>Sua vez de conduzir.</h2><p>Quando o time estiver pronto, inicie a primeira fase. Todos os navegadores avançam juntos.</p><div className="host-rule"><span>✦</span><span>Você não participa dos times</span></div><button className="primary-button full-button" disabled={busy || room.players.filter((player) => player.kind === "player").length < 2} onClick={() => void setRoomPhase("identity")} type="button">{startButtonLabel}<span>→</span></button><small className="host-hint">Pelo menos 2 jogadores precisam entrar para iniciar. Você fica fora do jogo.</small></> : <><div className="waiting-icon"><span>⏳</span></div><h2>Esperando o Game Master.</h2><p>Você já está na sala. Assim que o host iniciar, a próxima fase aparece aqui para todo mundo.</p><div className="waiting-line"><i /><span>Conectado como {self.name}</span></div></>}
          </aside>
        </div>
        {error && <div className="error-message lobby-error" role="alert">{error}</div>}
        {notice && <div className="notice-message lobby-notice">{notice}</div>}
        <div className="share-strip"><span>Convide seu time com o código <strong>{room.code}</strong></span><button className="secondary-button" onClick={() => void copyInvite()} type="button">{copied ? "Convite copiado" : "Copiar convite"} <span>⧉</span></button></div>
      </section>
      <footer className="home-footer"><span>Game Master no comando · presença em tempo real</span><span>Jogo completo</span></footer>
    </main>
  );
}

function toPlayer(row: { id: string; session_id: string; name: string; avatar_id: string; is_host: boolean; last_seen_at: string | null }): Player {
  const lastSeenAt = row.last_seen_at ? new Date(row.last_seen_at).getTime() : Date.now();
  return { id: row.id, sessionId: row.session_id, name: row.name, avatar: avatarById(row.avatar_id), kind: row.is_host ? "host" : "player", online: isRecentlyOnline(lastSeenAt), lastSeenAt };
}

function IdentityScreen({
  room,
  self,
  state,
  busy,
  error,
  onBack,
  onSubmit,
  onDraw,
  onVote,
  onReveal,
  onDrawTeams,
}: {
  room: Room;
  self: Player;
  state: IdentityViewState | null;
  busy: boolean;
  error: string;
  onBack: () => void;
  onSubmit: (answers: IdentityAnswers) => void;
  onDraw: () => void;
  onVote: (playerId: string) => void;
  onReveal: () => void;
  onDrawTeams: () => void;
}) {
  const [answers, setAnswers] = useState<IdentityAnswers>({ hidden_story: "", dream: "", unexpected_story: "" });
  const [formError, setFormError] = useState("");
  const current = state?.currentRound;
  const promptLabel = current ? IDENTITY_PROMPTS.find((prompt) => prompt.key === current.promptKey)?.label : "";
  const canDraw = Boolean(state && state.participantCount >= 2 && state.submittedCount === state.participantCount);

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const values = IDENTITY_PROMPTS.map((prompt) => answers[prompt.key].trim());
    if (values.some((answer) => answer.length < 8)) {
      setFormError("Conte um pouquinho mais em cada resposta (pelo menos 8 caracteres).");
      return;
    }
    setFormError("");
    onSubmit({
      hidden_story: values[0],
      dream: values[1],
      unexpected_story: values[2],
    });
  }

  return (
    <main className="page-shell identity-shell">
      <div className="ambient-orb orb-one" /><div className="ambient-orb orb-two" />
      <header className="topbar">
        <div className="brand"><span className="brand-mark">✦</span><span>SquadQuest</span></div>
        <div className="phase-indicator"><span className="phase-number">01</span><span>QUEM É?</span></div>
        <button className="text-button" onClick={onBack} type="button">Sair</button>
      </header>
      <section className="identity-game-content">
        <div className="eyebrow centered"><span /> PRIMEIRA FASE <span /></div>
        <h1>Quem é<br /><em>essa pessoa?</em></h1>
        <p className="identity-lead">Histórias anônimas, palpites sem placar e uma revelação para aproximar o time.</p>

        {!state ? <div className="identity-panel panel-card"><div className="sync-message"><i /><span>Carregando a fase…</span></div></div> : <>
          {state.step === "collecting" && <div className="identity-panel panel-card">
            {state.isHost ? <>
              <div className="identity-symbol small-symbol">✍️</div>
              <h2>O time está preparando histórias.</h2>
              <p>As respostas são privadas. O sistema sorteia uma história sem mostrar quem escreveu.</p>
              <div className="submission-progress"><span>{state.submittedCount} de {state.participantCount}</span><div><i style={{ width: `${state.participantCount ? Math.min(100, state.submittedCount / state.participantCount * 100) : 0}%` }} /></div><small>respostas prontas</small></div>
              <button className="primary-button full-button" disabled={busy || !canDraw} onClick={onDraw} type="button">{busy ? "Preparando…" : "Sortear uma história"}<span>→</span></button>
              {!canDraw && <small className="host-hint">O sorteio libera quando pelo menos duas pessoas enviarem as três respostas.</small>}
            </> : state.selfSubmitted ? <>
              <div className="identity-symbol small-symbol">🔒</div>
              <h2>Suas histórias estão guardadas.</h2>
              <p>Ninguém verá quem escreveu. O Game Master vai sortear uma resposta para o time tentar adivinhar.</p>
              <div className="waiting-line"><i /><span>{state.submittedCount} de {state.participantCount} respostas prontas</span></div>
            </> : <>
              <div className="form-player"><span className="mini-avatar" style={{ background: self.avatar.color }}>{self.avatar.emoji}</span><span>Responda em segredo, {self.name}</span></div>
              <form className="identity-answer-form" onSubmit={handleSubmit}>
                {IDENTITY_PROMPTS.map((prompt) => <label className="answer-field" key={prompt.key}>
                  <span>{prompt.label}</span><small>{prompt.hint}</small>
                  <textarea value={answers[prompt.key]} maxLength={500} rows={3} onChange={(event) => setAnswers((currentAnswers) => ({ ...currentAnswers, [prompt.key]: event.target.value }))} />
                </label>)}
                {formError && <div className="error-message" role="alert">{formError}</div>}
                <button className="primary-button full-button" disabled={busy} type="submit">{busy ? "Guardando…" : "Enviar minhas histórias"}<span>→</span></button>
              </form>
            </>}
          </div>}

          {state.step === "voting" && current && <div className="identity-panel panel-card">
            <div className="round-label">HISTÓRIA {current.number} DE 3</div>
            <div className="story-prompt">{promptLabel}</div>
            <blockquote className="story-quote">“{current.answer}”</blockquote>
            {state.isHost ? <>
              <div className="waiting-line"><i /><span>{current.votesCount} palpites registrados · sem placar</span></div>
              <p>Quando o grupo estiver pronto, revele quem compartilhou essa história.</p>
              <button className="primary-button full-button" disabled={busy} onClick={onReveal} type="button">{busy ? "Revelando…" : "Revelar história"}<span>✦</span></button>
            </> : current.hasVoted ? <>
              <div className="vote-receipt"><span>✓</span><div><strong>Palpite registrado.</strong><small>Seu voto é anônimo. Aguarde a revelação do Game Master.</small></div></div>
              <div className="waiting-line"><i /><span>{current.votesCount} palpites registrados</span></div>
            </> : <>
              <p className="vote-instruction">Quem você acha que viveu essa história?</p>
              <div className="guess-grid">{state.players.map((player) => <button className="guess-option" disabled={busy} key={player.id} onClick={() => onVote(player.id)} type="button">
                <span className="mini-avatar" style={{ background: player.avatar.color }}>{player.avatar.emoji}</span><span>{player.name}</span><i>→</i>
              </button>)}</div>
            </>}
          </div>}

          {(state.step === "reveal" || state.step === "complete") && current && <div className="identity-panel panel-card reveal-panel">
            <div className="round-label">{state.step === "complete" ? "FASE CONCLUÍDA" : `REVELAÇÃO · HISTÓRIA ${current.number}`}</div>
            <div className="reveal-avatar" style={{ background: current.author?.avatar.color ?? "#9b8cff" }}>{current.author?.avatar.emoji ?? "✦"}</div>
            <h2>{current.author?.name ?? "Uma pessoa do time"}!</h2>
            <p className="reveal-caption">Essa história era de {current.author?.name ?? "alguém do time"}.</p>
            <div className="revealed-story"><span>{promptLabel}</span><p>“{current.answer}”</p></div>
            <p>Sem pontos, sem certo ou errado — só mais uma história para conhecer melhor quem está do outro lado da tela.</p>
            {state.step === "reveal" ? <button className="primary-button full-button" disabled={busy} onClick={onDraw} type="button">{busy ? "Preparando…" : "Próxima história"}<span>→</span></button> : state.isHost ? <><div className="completion-note">✦ &nbsp;Quem é? concluído. Agora vamos descobrir quais ideias vão nascer em cada time.</div><button className="primary-button full-button" disabled={busy || room.players.filter((player) => player.kind === "player").length < 4} onClick={onDrawTeams} type="button">Sortear os times <span>🎲</span></button><small className="host-hint">A missão precisa de pelo menos 4 jogadores, para formar dois times jogáveis.</small></> : <div className="completion-note">✦ &nbsp;Quem é? concluído. O Game Master vai sortear os times.</div>}
          </div>}
        </>}
        {error && <div className="error-message identity-error" role="alert">{error}</div>}
        <div className="identity-room-note">{room.transport === "local"
          ? "DEMO LOCAL · respostas ficam neste navegador; use apenas conteúdo de teste, não histórias pessoais."
          : `Sala ${room.code} · Game Master conduz a fase · sem ranking individual`}</div>
      </section>
      <footer className="home-footer"><span>Uma história de cada vez · até 3 rodadas</span><span>SquadQuest</span></footer>
    </main>
  );
}

import type { Player } from "@/lib/types";

export function PlayerCard({ player }: { player: Player }) {
  return (
    <div className={`player-card ${player.kind === "host" ? "host-card" : ""}`}>
      <div className="player-avatar" style={{ background: player.avatar.color }}>
        {player.avatar.emoji}
        <span className={`presence-dot ${player.online ? "online" : ""}`} aria-label={player.online ? "online" : "offline"} />
      </div>
      <div className="player-card-copy">
        <strong>{player.name}</strong>
        <span>{player.kind === "host" ? "Game Master" : "Jogador"}</span>
      </div>
      {player.kind === "host" && <span className="host-tag">HOST</span>}
    </div>
  );
}

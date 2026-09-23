"use client";

import { useState, type FormEvent } from "react";
import { POWER_CHALLENGE_TITLES, POWER_OUTCOME_LABELS, SECRET_ROLES, formatClock, secondsUntil } from "@/lib/gameplay";
import { avatarById, type PowerChallengeReply, type PowerChallengeView, type PowerOutcome } from "@/lib/types";

export type PowerChallengeRpcName = "reply_squadquest_power_challenge" | "resolve_squadquest_power_challenge";

type Props = {
  challenge: PowerChallengeView;
  roomId: string;
  now: number;
  busy: boolean;
  error: string;
  execute: (name: PowerChallengeRpcName, args: Record<string, unknown>) => Promise<boolean>;
};

const MIN_REPLY = 8;
const MAX_REPLY = 300;
const WARN_SECONDS = 15;

function ReplyList({ replies }: { replies: PowerChallengeReply[] }) {
  if (!replies.length) return <p className="power-challenge-empty">Nenhuma resposta ainda.</p>;
  return <ul className="power-challenge-replies">{replies.map((reply) => {
    const avatar = avatarById(reply.avatar_id);
    return <li key={`${reply.player_id}-${reply.round}-${reply.created_at}`}>
      <span className="mini-avatar" style={{ background: avatar.color }} aria-hidden="true">{avatar.emoji}</span>
      <div><strong>{reply.name}{reply.round === 2 && <em>rodada 2</em>}</strong><p>{reply.content}</p></div>
    </li>;
  })}</ul>;
}

/** Overlay bloqueante do desafio de poder. Só aparece enquanto o servidor devolver team.power_challenge; não há botão de fechar. */
export function PowerChallenge({ challenge, roomId, now, busy, error, execute }: Props) {
  const [replyText, setReplyText] = useState("");
  const role = SECRET_ROLES[challenge.role_key];
  const remaining = secondsUntil(challenge.deadline_at, now);
  const expired = remaining <= 0;
  const roundReplies = challenge.replies.filter((reply) => reply.round === challenge.round);
  const visibleReplies = challenge.i_am_holder || challenge.my_reply_submitted ? challenge.replies : challenge.replies.filter((reply) => reply.round < challenge.round);
  const trimmed = replyText.trim();
  const canReply = !busy && !expired && trimmed.length >= MIN_REPLY && trimmed.length <= MAX_REPLY;
  const clockClass = expired ? "over" : remaining < WARN_SECONDS ? "warn" : "";

  function submitReply(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canReply) return;
    void execute("reply_squadquest_power_challenge", { target_room_id: roomId, challenge_id: challenge.id, reply_text: trimmed })
      .then((success) => { if (success) setReplyText(""); });
  }

  function resolve(decision: "approve" | "extend") {
    if (busy || expired) return;
    void execute("resolve_squadquest_power_challenge", { target_room_id: roomId, challenge_id: challenge.id, decision });
  }

  return <div className="power-challenge-backdrop" role="dialog" aria-modal="true" aria-labelledby="power-challenge-title">
    <section className="power-challenge">
      <header className="power-challenge-head">
        <span className="power-challenge-icon" aria-hidden="true">{role.icon}</span>
        <div>
          <div className="quest-section-kicker">DESAFIO DE PODER · RODADA {challenge.round}/2</div>
          <h2 id="power-challenge-title">{POWER_CHALLENGE_TITLES[challenge.role_key]}</h2>
          <small>lançado por {challenge.holder_name}</small>
        </div>
        <strong className={`power-challenge-clock ${clockClass}`}>{expired ? "Tempo esgotado, fechando…" : formatClock(remaining)}</strong>
      </header>

      <blockquote className="power-challenge-prompt">“{challenge.prompt}”</blockquote>

      {challenge.i_am_holder ? <>
        <div className="power-challenge-count">{roundReplies.length}/{challenge.expected_replies} responderam{challenge.round === 2 ? " nesta rodada" : ""}</div>
        <ReplyList replies={visibleReplies} />
        <p className="power-challenge-help">Aprovar registra as respostas como marca no canvas.{challenge.round === 1 ? " Se faltar gente, dá para abrir mais uma rodada de 60 s." : ""}</p>
        <div className="power-challenge-actions">
          <button className="primary-button" disabled={busy || expired || roundReplies.length === 0} onClick={() => resolve("approve")} type="button">Aprovar <span>✓</span></button>
          {challenge.round === 1 && !expired && <button className="secondary-button" disabled={busy} onClick={() => resolve("extend")} type="button">Mais uma rodada (+60 s)</button>}
        </div>
      </> : challenge.my_reply_submitted ? <>
        <p className="power-challenge-wait">✓ Sua resposta foi enviada. Aguardando o julgamento de {challenge.holder_name}.</p>
        <ReplyList replies={visibleReplies} />
      </> : <>
        <div className="power-challenge-count">{roundReplies.length}/{challenge.expected_replies} já responderam</div>
        {visibleReplies.length > 0 && <ReplyList replies={visibleReplies} />}
        <form onSubmit={submitReply}>
          <label className="quest-field">
            <span>Sua resposta ao {role.name}</span>
            <textarea value={replyText} onChange={(event) => setReplyText(event.target.value)} placeholder="Responda em uma ou duas frases…" maxLength={MAX_REPLY} rows={3} disabled={busy || expired} autoFocus />
            <small>{trimmed.length}/{MAX_REPLY}{trimmed.length < MIN_REPLY ? ` · mínimo ${MIN_REPLY} caracteres` : ""}</small>
          </label>
          <button className="primary-button" disabled={!canReply} type="submit">Responder <span>→</span></button>
        </form>
      </>}

      {error && <div className="error-message" role="alert">{error}</div>}
    </section>
  </div>;
}

/** Marcas deixadas pelos desafios já resolvidos: aparecem no canvas (build/adapt) e no pitch. */
export function PowerOutcomes({ outcomes }: { outcomes: PowerOutcome[] | null | undefined }) {
  if (!outcomes?.length) return null;
  return <div className="quest-power-outcomes">{outcomes.map((outcome) => {
    const role = SECRET_ROLES[outcome.role_key];
    const label = POWER_OUTCOME_LABELS[outcome.role_key];
    const unanswered = outcome.status === "unanswered";
    return <div className={`quest-mission-card quest-power-outcome ${unanswered ? "unanswered" : ""}`} key={outcome.id}>
      <div className="quest-section-kicker">{unanswered ? `SEM RESPOSTA · ${label}` : label}</div>
      <em>“{outcome.prompt}”</em>
      {outcome.replies.length ? outcome.replies.map((reply, index) => <p key={`${reply.name}-${index}`}><strong>{reply.name}:</strong> {reply.content}</p>) : <p>Ninguém respondeu a tempo.</p>}
      <small>{role.icon} {role.name} · {outcome.holder_name}{outcome.round === 2 ? " · 2 rodadas" : ""}</small>
    </div>;
  })}</div>;
}

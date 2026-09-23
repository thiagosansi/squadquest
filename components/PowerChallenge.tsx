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

/** Quando presente, as respostas da rodada `round` viram selecionáveis (uma por vez). */
type Selectable = { round: number; selectedId: string | null; disabled: boolean; onSelect: (id: string) => void };

const MIN_REPLY = 8;
const MAX_REPLY = 300;
const WARN_SECONDS = 15;
const MISSING_ID_TITLE = "atualize a migration";

function replyKey(reply: PowerChallengeReply) {
  return reply.id || `${reply.player_id}-${reply.round}-${reply.created_at}`;
}

function ReplyList({ replies, selectable }: { replies: PowerChallengeReply[]; selectable?: Selectable }) {
  if (!replies.length) return <p className="power-challenge-empty">Nenhuma resposta ainda.</p>;
  return <ul className="power-challenge-replies">{replies.map((reply) => {
    const avatar = avatarById(reply.avatar_id);
    const isCurrentRound = Boolean(selectable && reply.round === selectable.round);
    // Até a migration 0011 expor `id` em power_challenge.replies, o item chega sem id e não pode ser escolhido.
    const hasId = Boolean(reply.id);
    const canSelect = isCurrentRound && hasId && !selectable?.disabled;
    const selected = isCurrentRound && hasId && selectable?.selectedId === reply.id;
    const choose = canSelect ? () => selectable?.onSelect(reply.id) : undefined;
    return <li key={replyKey(reply)} className={`${isCurrentRound ? "selectable" : ""} ${selected ? "selected" : ""}`.trim() || undefined} onClick={choose}>
      <span className="mini-avatar" style={{ background: avatar.color }} aria-hidden="true">{avatar.emoji}</span>
      <div><strong>{reply.name}{reply.round === 2 && <em>rodada 2</em>}</strong><p>{reply.content}</p></div>
      {isCurrentRound && <button className="power-challenge-choose" type="button" aria-pressed={selected} disabled={!canSelect} title={hasId ? undefined : MISSING_ID_TITLE} onClick={choose}>{selected ? "✓ Escolhida" : "Escolher"}</button>}
    </li>;
  })}</ul>;
}

/** Overlay bloqueante do desafio de poder. Só aparece enquanto o servidor devolver team.power_challenge; não há botão de fechar. */
export function PowerChallenge({ challenge, roomId, now, busy, error, execute }: Props) {
  const [replyText, setReplyText] = useState("");
  const [pickedReplyId, setPickedReplyId] = useState<string | null>(null);
  const role = SECRET_ROLES[challenge.role_key];
  const remaining = secondsUntil(challenge.deadline_at, now);
  const expired = remaining <= 0;
  const roundReplies = challenge.replies.filter((reply) => reply.round === challenge.round);
  // A escolha só vale se ainda apontar para uma resposta da rodada atual (uma rodada nova invalida a anterior).
  const selectedReplyId = pickedReplyId && roundReplies.some((reply) => reply.id === pickedReplyId) ? pickedReplyId : null;
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

  /** `approve` exige a resposta escolhida (chosen_reply_id); `extend` não envia o campo. */
  function resolve(decision: "approve" | "extend", chosenReplyId?: string) {
    if (busy || expired) return;
    if (decision === "approve" && !chosenReplyId) return;
    const args: Record<string, unknown> = { target_room_id: roomId, challenge_id: challenge.id, decision };
    if (decision === "approve") args.chosen_reply_id = chosenReplyId;
    void execute("resolve_squadquest_power_challenge", args);
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
        <ReplyList replies={visibleReplies} selectable={{ round: challenge.round, selectedId: selectedReplyId, disabled: busy || expired, onSelect: setPickedReplyId }} />
        <p className="power-challenge-help">Escolha a resposta que mais desafia o time; ela vira a marca no canvas.{challenge.round === 1 ? " Se faltar gente, dá para abrir mais uma rodada de 60 s." : ""}</p>
        <div className="power-challenge-actions">
          <button className="primary-button" disabled={busy || expired || !selectedReplyId} onClick={() => resolve("approve", selectedReplyId ?? undefined)} type="button">Aprovar a escolhida <span>✓</span></button>
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
    // Dados anteriores à migration 0011 podem chegar sem o campo: tratar como aprovado pelo tempo.
    const chosen = outcome.chosen_reply ?? null;
    const byTime = outcome.status === "approved" && !chosen && outcome.replies.length > 0;
    // Remove só a primeira ocorrência da escolhida (mesmo nome + conteúdo); as demais ficam na lista compacta.
    const chosenIndex = chosen ? outcome.replies.findIndex((reply) => reply.name === chosen.name && reply.content === chosen.content) : -1;
    const others = chosenIndex >= 0 ? outcome.replies.filter((_, index) => index !== chosenIndex) : outcome.replies;
    const kicker = unanswered ? `SEM RESPOSTA · ${label}` : byTime ? `${label} · aprovado pelo tempo` : label;
    return <div className={`quest-mission-card quest-power-outcome ${unanswered ? "unanswered" : ""}`} key={outcome.id}>
      <div className="quest-section-kicker">{kicker}</div>
      <em>“{outcome.prompt}”</em>
      {chosen ? <>
        <p className="chosen"><strong>{chosen.name}:</strong> {chosen.content} <em>✓ escolhida por {outcome.holder_name}</em></p>
        {others.length > 0 && <details>
          <summary>outras respostas ({others.length})</summary>
          {others.map((reply, index) => <p key={`${reply.name}-${index}`}><strong>{reply.name}:</strong> {reply.content}</p>)}
        </details>}
      </> : outcome.replies.length ? outcome.replies.map((reply, index) => <p key={`${reply.name}-${index}`}><strong>{reply.name}:</strong> {reply.content}</p>) : <p>Ninguém respondeu a tempo.</p>}
      <small>{role.icon} {role.name} · {outcome.holder_name}{outcome.round === 2 ? " · 2 rodadas" : ""}</small>
    </div>;
  })}</div>;
}

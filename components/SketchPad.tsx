"use client";

import { useRef, useState, type PointerEvent } from "react";

const WIDTH = 600;
const HEIGHT = 400;
const MAX_LENGTH = 60000;
const MIN_DISTANCE = 2;

type Point = { x: number; y: number };
type Stroke = { pointerId: number; last: Point; path: string; segments: number };

type Props = {
  value: string;
  onChange?: (next: string) => void;
  readOnly?: boolean;
  label?: string;
};

function clamp(value: number, max: number): number {
  return Math.min(max, Math.max(0, Math.round(value)));
}

function pointFromEvent(event: PointerEvent<SVGSVGElement>): Point | null {
  const rect = event.currentTarget.getBoundingClientRect();
  if (!rect.width || !rect.height) return null;
  return { x: clamp(((event.clientX - rect.left) / rect.width) * WIDTH, WIDTH), y: clamp(((event.clientY - rect.top) / rect.height) * HEIGHT, HEIGHT) };
}

function removeLastStroke(value: string): string {
  const index = value.lastIndexOf("M");
  return index <= 0 ? "" : value.slice(0, index).trimEnd();
}

export function SketchPad({ value, onChange, readOnly = false, label = "Quadro de desenho" }: Props) {
  const strokeRef = useRef<Stroke | null>(null);
  const [currentPath, setCurrentPath] = useState("");
  const [limitReached, setLimitReached] = useState(false);

  if (readOnly && !value) return null;

  function startStroke(event: PointerEvent<SVGSVGElement>) {
    if (readOnly || strokeRef.current || event.button !== 0) return;
    const point = pointFromEvent(event);
    if (!point) return;
    const path = `M${point.x} ${point.y}`;
    strokeRef.current = { pointerId: event.pointerId, last: point, path, segments: 0 };
    setCurrentPath(path);
    setLimitReached(false);
    try { event.currentTarget.setPointerCapture(event.pointerId); } catch { /* capture is a nicety, drawing still works without it */ }
  }

  function moveStroke(event: PointerEvent<SVGSVGElement>) {
    const stroke = strokeRef.current;
    if (!stroke || stroke.pointerId !== event.pointerId) return;
    const point = pointFromEvent(event);
    if (!point || Math.hypot(point.x - stroke.last.x, point.y - stroke.last.y) < MIN_DISTANCE) return;
    stroke.path += ` L${point.x} ${point.y}`;
    stroke.last = point;
    stroke.segments += 1;
    setCurrentPath(stroke.path);
  }

  function endStroke(event: PointerEvent<SVGSVGElement>) {
    const stroke = strokeRef.current;
    if (!stroke || stroke.pointerId !== event.pointerId) return;
    strokeRef.current = null;
    setCurrentPath("");
    try { if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId); } catch { /* already released */ }
    const path = stroke.segments ? stroke.path : `${stroke.path} L${stroke.last.x} ${stroke.last.y}`;
    const next = value ? `${value} ${path}` : path;
    if (next.length > MAX_LENGTH) { setLimitReached(true); return; }
    onChange?.(next);
  }

  return <div className="sketch-pad">
    <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} preserveAspectRatio="none" role="img" aria-label={label}
      onPointerDown={readOnly ? undefined : startStroke} onPointerMove={readOnly ? undefined : moveStroke} onPointerUp={readOnly ? undefined : endStroke}
      onPointerCancel={readOnly ? undefined : endStroke} onPointerLeave={readOnly ? undefined : endStroke}>
      {value && <path d={value} fill="none" stroke="var(--purple)" strokeWidth={4} strokeLinecap="round" strokeLinejoin="round" />}
      {currentPath && <path d={currentPath} fill="none" stroke="var(--purple)" strokeWidth={4} strokeLinecap="round" strokeLinejoin="round" />}
    </svg>
    {!readOnly && <div className="sketch-pad-tools">
      <button disabled={!value} onClick={() => { setLimitReached(false); onChange?.(removeLastStroke(value)); }} type="button">Desfazer</button>
      <button disabled={!value} onClick={() => { setLimitReached(false); onChange?.(""); }} type="button">Limpar</button>
      {limitReached && <span className="sketch-pad-warning">Limite de desenho atingido</span>}
    </div>}
  </div>;
}

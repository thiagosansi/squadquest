"use client";

import { AVATARS, type Avatar } from "@/lib/types";

type AvatarPickerProps = {
  value: Avatar;
  onChange: (avatar: Avatar) => void;
};

export function AvatarPicker({ value, onChange }: AvatarPickerProps) {
  return (
    <div className="avatar-picker" aria-label="Escolha seu avatar">
      {AVATARS.map((avatar) => (
        <button
          className={`avatar-choice ${value.id === avatar.id ? "selected" : ""}`}
          key={avatar.id}
          type="button"
          aria-label={`Avatar ${avatar.label ?? avatar.id}`}
          aria-pressed={value.id === avatar.id}
          onClick={() => onChange(avatar)}
          style={{ "--avatar-color": avatar.color } as React.CSSProperties}
        >
          <span>{avatar.emoji}</span>
        </button>
      ))}
    </div>
  );
}

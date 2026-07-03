import type { CSSProperties } from 'react'

export function FishIcon({ className, style }: { className?: string; style?: CSSProperties }) {
  return (
    <svg className={className} style={style} viewBox="224 54 270 270" aria-hidden="true">
      <use href="#dory-fish" />
    </svg>
  )
}

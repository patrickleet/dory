import { useEffect, useRef } from 'react'
import { StaticMeshGradient } from '@paper-design/shaders-react'
import { FISH_VIEWBOX, fishPaths } from './fishArt'
import { useReducedMotion } from '../hooks/useReducedMotion'

const clamp = (v: number, lo: number, hi: number) => (v < lo ? lo : v > hi ? hi : v)

export function DoryFish() {
  const reduced = useReducedMotion()
  const stageRef = useRef<HTMLDivElement>(null)
  const fishRef = useRef<SVGSVGElement>(null)
  const pupilRef = useRef<SVGCircleElement>(null)
  const glintRef = useRef<SVGCircleElement>(null)

  useEffect(() => {
    if (reduced) return
    const stage = stageRef.current
    const fish = fishRef.current
    const pupil = pupilRef.current
    const glint = glintRef.current
    if (!stage || !fish || !pupil || !glint) return

    let width = 0
    let height = 0
    let fishWidth = 0
    let fishHeight = 0

    function measure() {
      width = stage!.clientWidth
      height = stage!.clientHeight
      const cs = getComputedStyle(fish!)
      fishWidth = parseFloat(cs.width) || 150
      fishHeight = parseFloat(cs.height) || 136
    }
    const ro = new ResizeObserver(measure)
    ro.observe(stage)
    measure()

    const pos = { x: width / 2, y: height / 2 }
    const vel = { x: -40, y: 0 }
    let facing = -1
    let rot = 0
    let target: { x: number; y: number } | null = null
    let nextWander = 0
    let nextBubble = 0
    let pointer: { x: number; y: number } | null = null

    function onPointerMove(ev: PointerEvent) {
      const r = fish!.getBoundingClientRect()
      const eyeX = r.left + r.width * (facing === 1 ? 0.72 : 0.28)
      const eyeY = r.top + r.height * 0.55
      const dx = ev.clientX - eyeX
      const dy = ev.clientY - eyeY
      const d = Math.hypot(dx, dy) || 1
      const m = Math.min(5, d / 40)
      pupil!.setAttribute('transform', `translate(${((dx / d) * m).toFixed(1)} ${((dy / d) * m).toFixed(1)})`)
      glint!.setAttribute(
        'transform',
        `translate(${((dx / d) * m * 0.5).toFixed(1)} ${((dy / d) * m * 0.5).toFixed(1)})`,
      )
    }
    addEventListener('pointermove', onPointerMove, { passive: true })

    function onStagePointerMove(ev: PointerEvent) {
      const r = stage!.getBoundingClientRect()
      pointer = { x: ev.clientX - r.left, y: ev.clientY - r.top }
    }
    function onStagePointerLeave() {
      pointer = null
    }
    stage.addEventListener('pointermove', onStagePointerMove, { passive: true })
    stage.addEventListener('pointerleave', onStagePointerLeave, { passive: true })

    function spawnBubble() {
      if (!width) return
      const b = document.createElement('i')
      b.className = 'fbubble'
      const s = 3 + Math.random() * 5
      b.style.width = b.style.height = `${s.toFixed(1)}px`
      b.style.left = `${(pos.x + (facing === 1 ? fishWidth * 0.38 : -fishWidth * 0.38)).toFixed(1)}px`
      b.style.top = `${(pos.y + fishHeight * 0.06).toFixed(1)}px`
      stage!.appendChild(b)
      b.animate(
        [
          { transform: 'translateY(0)', opacity: 0.75 },
          { transform: `translateY(-${(34 + Math.random() * 30).toFixed(0)}px)`, opacity: 0 },
        ],
        { duration: 1100 + Math.random() * 700, easing: 'ease-out' },
      ).onfinish = () => b.remove()
    }
    function burst(n: number) {
      for (let i = 0; i < n; i++) setTimeout(spawnBubble, i * 45)
    }

    function onClick() {
      vel.x += facing === 1 ? 420 : -420
      vel.y -= 90
      burst(10)
    }
    fish.addEventListener('click', onClick)

    function pickWander(now: number) {
      target = {
        x: fishWidth / 2 + 16 + Math.random() * Math.max(40, width - fishWidth - 32),
        y: fishHeight / 2 + 8 + Math.random() * Math.max(20, height - fishHeight - 16),
      }
      nextWander = now + 2600 + Math.random() * 3200
    }

    let last = performance.now()
    let raf = 0
    function swim(now: number) {
      const dt = Math.min(0.05, (now - last) / 1000)
      last = now
      if (!document.hidden && width > 0) {
        const goal = pointer || target
        let effectiveGoal = goal
        if (!pointer && (!target || now > nextWander)) {
          pickWander(now)
          effectiveGoal = target
        }
        if (effectiveGoal) {
          const dx = effectiveGoal.x - pos.x
          const dy = effectiveGoal.y - pos.y
          const dist = Math.hypot(dx, dy) || 1
          let max = pointer ? 170 : 95
          if (dist < 60 && !pointer) max *= dist / 60
          vel.x += (((dx / dist) * max - vel.x) * Math.min(1, dt * 1.8))
          vel.y += (((dy / dist) * max - vel.y) * Math.min(1, dt * 1.8))
        }
        pos.x += vel.x * dt
        pos.y += vel.y * dt
        const minX = fishWidth / 2
        const maxX = width - fishWidth / 2
        const minY = fishHeight / 2
        const maxY = height - fishHeight / 2
        if (pos.x < minX) {
          pos.x = minX
          vel.x = Math.abs(vel.x) * 0.5
        }
        if (pos.x > maxX) {
          pos.x = maxX
          vel.x = -Math.abs(vel.x) * 0.5
        }
        if (pos.y < minY) {
          pos.y = minY
          vel.y = Math.abs(vel.y) * 0.5
        }
        if (pos.y > maxY) {
          pos.y = maxY
          vel.y = -Math.abs(vel.y) * 0.5
        }
        const speed = Math.hypot(vel.x, vel.y)
        if (vel.x > 16) facing = 1
        else if (vel.x < -16) facing = -1
        rot += (clamp(-vel.y * 0.09, -13, 13) - rot) * Math.min(1, dt * 4)
        fish!.style.transform =
          `translate(${(pos.x - fishWidth / 2).toFixed(1)}px,${(pos.y - fishHeight / 2).toFixed(1)}px)` +
          ` scaleX(${facing === 1 ? -1 : 1}) rotate(${rot.toFixed(1)}deg)`
        fish!.style.setProperty('--wagdur', `${clamp(1.9 - speed / 120, 0.35, 1.9).toFixed(2)}s`)
        if (speed > 70 && now > nextBubble) {
          nextBubble = now + 260
          spawnBubble()
        }
      }
      raf = requestAnimationFrame(swim)
    }
    raf = requestAnimationFrame(swim)

    return () => {
      cancelAnimationFrame(raf)
      ro.disconnect()
      removeEventListener('pointermove', onPointerMove)
      stage.removeEventListener('pointermove', onStagePointerMove)
      stage.removeEventListener('pointerleave', onStagePointerLeave)
      fish.removeEventListener('click', onClick)
    }
  }, [reduced])

  return (
    <div className="fish-stage" ref={stageRef} id="fish-stage">
      {!reduced && (
        <div className="fish-glow" aria-hidden="true">
          <StaticMeshGradient
            style={{ width: '100%', height: '100%' }}
            colors={['#eaf1fe', '#dbeeff', '#e3f8ea', '#ffffff']}
            speed={0.05}
            positions={2}
            waveX={0.3}
            waveY={0.3}
            mixing={0.6}
          />
        </div>
      )}
      <svg
        id="fish"
        ref={fishRef}
        viewBox={FISH_VIEWBOX}
        role="img"
        aria-label="Dory the fish, click me"
      >
        <path className="topfin" d={fishPaths.topfin} fill="#FFB020" />
        <path className="tail" d={fishPaths.tail} fill="#FFB020" />
        <g className="fishbody">
          <defs>
            <clipPath id="doryBodyHero">
              <ellipse
                cx={fishPaths.bodyClip.cx}
                cy={fishPaths.bodyClip.cy}
                rx={fishPaths.bodyClip.rx}
                ry={fishPaths.bodyClip.ry}
              />
            </clipPath>
          </defs>
          <ellipse
            cx={fishPaths.bodyClip.cx}
            cy={fishPaths.bodyClip.cy}
            rx={fishPaths.bodyClip.rx}
            ry={fishPaths.bodyClip.ry}
            fill="#3D7BF4"
          />
          <g clipPath="url(#doryBodyHero)">
            <path d={fishPaths.darkBack} fill="#0D1B3D" />
          </g>
          <path d={fishPaths.pectoralFin} fill="#2F62D9" />
          <circle cx={284} cy={210} r={16} fill="#FFFFFF" />
          <circle ref={pupilRef} className="pupil" cx={281} cy={211} r={8} fill="#0D1B3D" />
          <circle ref={glintRef} className="glint" cx={285} cy={206} r={2.6} fill="#FFFFFF" />
          <path d={fishPaths.mouth} fill="none" stroke="#0D1B3D" strokeWidth={4} strokeLinecap="round" />
        </g>
      </svg>
    </div>
  )
}

import { useEffect, useRef, useState, type ReactNode, type ElementType } from 'react'

export function Reveal({
  children,
  as: Tag = 'div',
  className = '',
}: {
  children: ReactNode
  as?: ElementType
  className?: string
}) {
  const ref = useRef<HTMLElement>(null)
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            setVisible(true)
            io.unobserve(el)
          }
        }
      },
      { threshold: 0.12 },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [])

  return (
    <Tag ref={ref} className={`reveal${visible ? ' in' : ''}${className ? ` ${className}` : ''}`}>
      {children}
    </Tag>
  )
}

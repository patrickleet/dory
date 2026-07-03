import { lazy, Suspense } from 'react'
import './App.css'
import { FishDefs } from './components/FishDefs'
import { Header } from './components/Header'
import { Hero } from './components/Hero'
import { UnderTheHood } from './components/UnderTheHood'
import { Features } from './components/Features'
import { DevEnvironments } from './components/DevEnvironments'
import { MemoryBars } from './components/MemoryBars'
import { Footprint } from './components/Footprint'
import { Install } from './components/Install'
import { Footer } from './components/Footer'

// Three.js is the single heaviest dependency in the bundle; split it into its own
// chunk so the hero paints before it's even fetched.
const MemoryModel = lazy(() =>
  import('./components/MemoryModel').then((m) => ({ default: m.MemoryModel })),
)

function ModelPlaceholder() {
  return (
    <section id="model" style={{ paddingTop: 36 }}>
      <div className="wrap">
        <span className="kicker">How Dory wins the memory game</span>
        <h2>Every VM you don't boot is RAM you keep.</h2>
        <div className="model-wrap" style={{ height: 520 }} />
      </div>
    </section>
  )
}

function App() {
  return (
    <>
      <FishDefs />
      <Header />
      <main>
        <Hero />
        <Suspense fallback={<ModelPlaceholder />}>
          <MemoryModel />
        </Suspense>
        <UnderTheHood />
        <Features />
        <DevEnvironments />
        <MemoryBars />
        <Footprint />
        <Install />
      </main>
      <Footer />
    </>
  )
}

export default App

import { useMemo, useState, type ElementType } from 'react'
import {
  ArrowDownTrayIcon,
  ArrowPathRoundedSquareIcon,
  BeakerIcon,
  CheckCircleIcon,
  ClipboardDocumentIcon,
  CommandLineIcon,
  CpuChipIcon,
  CubeTransparentIcon,
  DocumentMagnifyingGlassIcon,
  FolderArrowDownIcon,
  LifebuoyIcon,
  MagnifyingGlassIcon,
  ShieldCheckIcon,
} from '@heroicons/react/24/outline'
import './App.css'

type CodeBlock = {
  label: string
  code: string
}

type GuideSection = {
  id: string
  nav: string
  title: string
  summary: string
  icon: ElementType
  body?: string[]
  bullets?: string[]
  codeBlocks?: CodeBlock[]
  table?: {
    columns: string[]
    rows: string[][]
  }
}

const installCheck = `brew install --cask Augani/dory/dory
open -a Dory

# Verify the installed app path, daemon, and Docker API.
/Applications/Dory.app/Contents/Helpers/dorydctl engine status
/Applications/Dory.app/Contents/Helpers/docker ps`

const firstDockerRun = `docker context use dory
docker run --rm hello-world
docker compose up -d
dory doctor --active`

const orbStackImport = `# Keep OrbStack open while importing.
# OrbStack creates its Docker socket only while the app is running.
open -a OrbStack

# In Dory:
# Settings -> Import -> OrbStack -> Preflight -> Import selected data`

const portableImageMove = `# Portable fallback when moving one image manually.
docker context use orbstack
docker save my/image:tag -o image.tar

docker context use dory
docker load -i image.tar`

const portableVolumeMove = `# Export a named volume from the old engine.
docker context use orbstack
docker run --rm -v my_volume:/from -v "$PWD:/backup" alpine \\
  tar -C /from -czf /backup/my_volume.tgz .

# Import it into Dory.
docker context use dory
docker volume create my_volume
docker run --rm -v my_volume:/to -v "$PWD:/backup" alpine \\
  tar -C /to -xzf /backup/my_volume.tgz`

const machineCreate = `# Settings -> Machines controls which host env vars may be copied.
# The CLI also accepts a one-shot allow-list from the current shell.
export DORY_MACHINE_ENV_ALLOW_LIST="ANTHROPIC_API_KEY,GH_TOKEN,OPENAI_API_KEY"

dory machine create agent-dev \\
  --memory-mb 4096 \\
  --cpus 4 \\
  --share workspace="$PWD":/workspace:rw

dory machine exec agent-dev --cwd /workspace -- /bin/sh -lc 'uname -a && pwd'
dory machine shell agent-dev`

const machineExec = `# Run a command inside the VM boundary.
dory machine exec agent-dev --cwd /workspace -- /bin/sh -lc 'npm test'

# Open an interactive shell.
dory machine shell agent-dev`

const sandboxRun = `# Ephemeral, dedicated VM. No host files are visible unless mounted.
dory sandbox run --json \\
  --network none \\
  --mount "$PWD:/workspace:rw" \\
  -- /bin/sh -lc 'cd /workspace && npm test'`

const readOnlyReview = `# Give an agent read-only project access for review.
dory sandbox run --json \\
  --network none \\
  --mount "$PWD:/workspace:ro" \\
  -- /bin/sh -lc 'cd /workspace && rg -n "TODO|FIXME|unsafe" .'`

const agentPrompt = `You are working inside a Dory Linux machine or sandbox.

Rules:
1. Treat the VM as the whole computer. Only use files, tools, env vars, and network access visible inside it.
2. Work from /workspace when it exists. Do not assume the macOS home directory is mounted.
3. Do not request host paths, SSH keys, or tokens unless the user explicitly mounted or allowed them.
4. Prefer structured commands through:
   dory machine exec <name> --cwd /workspace -- <command>
   or:
   dory sandbox run --json --mount "$PWD:/workspace:rw" -- <command>
5. If a required file or credential is missing, report the missing in-VM resource instead of trying to escape the machine.`

const diagnostics = `dory doctor --active
dory network --active
dory mount --json
dory disk
dory cleanup
dory routes
dory repair
dory support bundle
dory logs collect --json
dory idle status`

const benchmarkRun = `BENCH_WORKDIR="$PWD/.benchmark-results" \\
scripts/benchmark-compare.sh \\
  --dory-app /Applications/Dory.app \\
  --engines dory,orbstack,colima \\
  --metrics memory,cpu,network,fs \\
  --memory-counts 0,1,3,5,10 \\
  --runs 3 \\
  --cpu-mb 256 \\
  --fs-files 2000`

const sections: GuideSection[] = [
  {
    id: 'review',
    nav: 'Review',
    title: 'Complete review of what we built',
    summary:
      'Dory is now a native Mac container app with its own daemon-managed engine, Docker-compatible workflows, machine isolation, imports, diagnostics, and agent-ready sandboxes.',
    icon: DocumentMagnifyingGlassIcon,
    body: [
      'The work moved Dory from a good-looking app into a real engine product. The installed app can start the daemon, wake the engine, expose Docker, and keep the user out of DerivedData paths.',
      'The important shift is ownership: doryd owns the engine lifecycle and networking, while the app becomes the control surface. That lets Docker, machines, imports, and routes keep working even when the window is not open.',
    ],
    bullets: [
      'Docker now works from the installed app path: the engine reaches running and the bundled Docker CLI can list containers.',
      'Settings now cover engine lifecycle policy, manual stop behavior, stop-on-quit behavior, app-only updates, machine defaults, and in-app success notifications.',
      'The CLI path is human: users can run dory machine shell NAME instead of a DerivedData helper path.',
      'App updates are split from heavy engine assets so small UI releases do not force users to download the engine again.',
      'Imports are built around Docker-compatible sources and one-click preflight flows, including OrbStack when its socket exists.',
      'Machines gained scoped mounts, environment allow-lists, default bundled kernel/rootfs discovery, and safer no-home-share defaults.',
      'Agent sandboxes run commands in dedicated VMs with no host sharing unless the user provides explicit mounts.',
      'Benchmarking is reproducible and raw-artifact based, with a plan to close CPU and filesystem gaps without giving up the shared-VM architecture.',
    ],
  },
  {
    id: 'install',
    nav: 'Install',
    title: 'Install and verify Dory',
    summary:
      'Install the app, open it once, then verify the daemon, engine, Docker socket, and Docker context from the terminal.',
    icon: ArrowDownTrayIcon,
    body: [
      'Users should run the installed app, not a DerivedData build. The installed bundle contains the app, doryd, dorydctl, dory-hv, Docker, Compose, kubectl, and the machine assets.',
      'If Docker returns EOF immediately after a manual stop, wait for doryd to wake the engine or start it from the app. The steady state should report running.',
    ],
    codeBlocks: [
      { label: 'Install and verify the installed bundle', code: installCheck },
      { label: 'First Docker run', code: firstDockerRun },
    ],
  },
  {
    id: 'settings',
    nav: 'Settings',
    title: 'Settings that matter',
    summary:
      'Dory settings are not decoration. They control daemon lifetime, engine backend, imports, updates, machine isolation, file sharing, and environment transfer.',
    icon: ShieldCheckIcon,
    bullets: [
      'Engine backend: use Dory engine by default, or point the app at an existing Docker-compatible socket when needed.',
      'Daemon lifetime: users can choose whether doryd keeps running after the app quits or exits with the app.',
      'Manual stop: stopping the engine should confirm success in-app instead of leaving users guessing.',
      'Auto-Idle: idle policy can stop the heavy engine while leaving state on disk and allowing controlled wake-up.',
      'Updates: the app can update independently from the heavy engine assets unless the engine bundle actually changes.',
      'Machines: users choose which host env names may be copied into new machines. Empty values are skipped.',
      'File sharing: machine host access is scoped. New machines no longer silently share the whole Mac home folder by default.',
    ],
  },
  {
    id: 'docker',
    nav: 'Docker',
    title: 'Docker workflow',
    summary:
      'Dory presents a normal Docker API on the Mac while running workloads in one shared Linux VM.',
    icon: CommandLineIcon,
    bullets: [
      'Use the dory Docker context for normal docker, compose, build, pull, run, exec, logs, and ps workflows.',
      'Published ports bind on localhost. Dory can also manage local domains and HTTPS when the user grants networking permissions.',
      'Compose projects are first-class: app views group services, and the CLI path remains compatible with existing scripts.',
      'The app bundles Docker CLI, Docker Compose, and kubectl so a clean Mac does not need Docker Desktop or Homebrew Docker packages.',
    ],
    codeBlocks: [{ label: 'Everyday Docker commands', code: firstDockerRun }],
  },
  {
    id: 'imports',
    nav: 'Import',
    title: 'Import and export data',
    summary:
      'Dory should make migration feel reversible: preflight first, import with a click, and keep portable Docker commands for advanced users.',
    icon: FolderArrowDownIcon,
    body: [
      'OrbStack only places its Docker socket while the OrbStack app is open. That is expected. Open OrbStack before using Dory import so the preflight can see images, containers, and volumes.',
      'For Docker Desktop, Colima, Rancher Desktop, Podman, and custom sockets, start the source engine first, then run Dory import from the app.',
    ],
    bullets: [
      'Preflight should show what can transfer, what needs attention, and estimated disk impact before changing anything.',
      'One-click import should handle supported images, containers, and metadata from detected Docker-compatible sources.',
      'Portable export still matters. docker save/load and volume tarballs give users a manual escape hatch.',
    ],
    codeBlocks: [
      { label: 'OrbStack one-click import checklist', code: orbStackImport },
      { label: 'Portable image move', code: portableImageMove },
      { label: 'Portable volume move', code: portableVolumeMove },
    ],
  },
  {
    id: 'machines',
    nav: 'Machines',
    title: 'Linux machines',
    summary:
      'Machines are real Linux VMs for development, testing, risky installs, and agent work. They have shells, exec, snapshots, mounts, and controlled env transfer.',
    icon: CpuChipIcon,
    body: [
      'Machine commands now use the public dory CLI. The wrapper fills bundled kernel and rootfs defaults, so users do not need to copy a long helper path out of the built app.',
      'Environment variables are copied only when their names are allowed in Settings -> Machines or through DORY_MACHINE_ENV_ALLOW_LIST. Explicit --env values passed to create win over automatic values.',
    ],
    bullets: [
      'No Mac home folder is shared into new machines unless the user opts in or adds scoped mounts.',
      'Use --share TAG=HOST:GUEST:rw for explicit project access.',
      'Use dory machine exec for repeatable commands and dory machine shell for interactive work.',
      'Use snapshots before risky package upgrades, agent experiments, or destructive tests.',
    ],
    codeBlocks: [
      { label: 'Create a scoped development machine', code: machineCreate },
      { label: 'Run commands inside the machine', code: machineExec },
    ],
  },
  {
    id: 'agents',
    nav: 'AI agents',
    title: 'Copy guides for AI agents',
    summary:
      'Give Claude Code or another agent a machine boundary. It sees the VM filesystem, mounted folders, copied env, and allowed network only.',
    icon: CubeTransparentIcon,
    body: [
      'The safest default is a sandbox: it is created for a single run, gets no host files unless mounted, and can run without network. Persistent machines are better for long-lived projects.',
      'For agent work, mount only the project path. Keep tokens in the allow-list only when the task truly needs them.',
    ],
    codeBlocks: [
      { label: 'Persistent agent machine', code: machineCreate },
      { label: 'Ephemeral sandbox run', code: sandboxRun },
      { label: 'Read-only review sandbox', code: readOnlyReview },
      { label: 'Prompt to paste into an AI agent', code: agentPrompt },
    ],
  },
  {
    id: 'diagnostics',
    nav: 'Repair',
    title: 'Diagnostics and repair',
    summary:
      'When something feels off, Dory should provide a command that explains the state before a user resets anything.',
    icon: LifebuoyIcon,
    bullets: [
      'doctor checks the socket, Docker context, registry, proxy, exposure, ports, domains, mounts, disk, memory, and helper setup.',
      'repair proposes non-destructive fixes before users reset the engine.',
      'support bundle and logs collect produce redacted artifacts users can attach to issues.',
      'idle status explains whether the heavy engine is running, sleeping, or waiting for a wake request.',
    ],
    codeBlocks: [{ label: 'Support checklist', code: diagnostics }],
  },
  {
    id: 'benchmarks',
    nav: 'Benchmarks',
    title: 'Benchmarks and architecture',
    summary:
      'The current numbers show Dory leading container-to-container networking, while Colima and OrbStack lead CPU and filesystem. The architecture plan explains how to close that gap.',
    icon: BeakerIcon,
    body: [
      'Dory uses one shared Linux VM. That is why container-to-container networking is already strong: traffic stays inside the guest kernel bridge instead of crossing one VM boundary per container.',
      'The measured losses are not a reason to abandon dory-hv. The gap analysis points to fixable root causes: vCPU QoS, virtio-blk queueing, cache eviction policy, ext4 tuning, and FUSE writeback behavior.',
    ],
    table: {
      columns: ['Engine', 'CPU median', 'C2C network', 'Bind mount'],
      rows: [
        ['Dory', '2.1020 s', '97.7721 Gbps', '0.6880 s'],
        ['OrbStack', '1.7190 s', '90.1203 Gbps', '0.2220 s'],
        ['Colima', '1.5750 s', '80.9901 Gbps', '0.1590 s'],
      ],
    },
    bullets: [
      'Current leader: Dory on container-to-container networking.',
      'Current leader: Colima on CPU and bind-mount filesystem in the July 8 local snapshot.',
      'Do not publish a memory winner from that snapshot; macOS compression made several memory deltas negative.',
      'The next wins should come from QoS, async or multiqueue block IO, workload-aware cache reclaim, writeback cache, and a rebuilt Docker 29.6.x rootfs.',
    ],
    codeBlocks: [{ label: 'Reproduce the comparison', code: benchmarkRun }],
  },
  {
    id: 'updates',
    nav: 'Updates',
    title: 'Ship small app updates without redownloading the engine',
    summary:
      'The app and the engine are now separate release concerns. That lets users receive UI fixes, settings polish, and import improvements without paying the engine download cost.',
    icon: ArrowPathRoundedSquareIcon,
    bullets: [
      'Full app artifacts include the app plus engine assets for clean installs.',
      'Lite app updates can update the SwiftUI app and helpers without replacing the large kernel/rootfs assets.',
      'Engine updates should happen only when the engine, kernel, rootfs, Docker toolchain, or guest agent changes.',
      'This keeps Dory pleasant to update while preserving the zero-prerequisite install story.',
    ],
  },
]

const allSearchText = (section: GuideSection) =>
  [
    section.nav,
    section.title,
    section.summary,
    ...(section.body ?? []),
    ...(section.bullets ?? []),
    ...(section.codeBlocks?.flatMap((block) => [block.label, block.code]) ?? []),
    ...(section.table?.rows.flat() ?? []),
  ]
    .join(' ')
    .toLowerCase()

function App() {
  const [query, setQuery] = useState('')
  const normalizedQuery = query.trim().toLowerCase()
  const visibleSections = useMemo(() => {
    if (!normalizedQuery) return sections
    return sections.filter((section) => allSearchText(section).includes(normalizedQuery))
  }, [normalizedQuery])

  return (
    <div className="site-shell">
      <header className="topbar">
        <a className="brand" href="#top" aria-label="Dory guide home">
          <span className="brand-mark">D</span>
          <span>Dory</span>
        </a>
        <nav className="top-links" aria-label="Primary">
          <a href="#install">Install</a>
          <a href="#machines">Machines</a>
          <a href="#agents">AI agents</a>
          <a href="#benchmarks">Benchmarks</a>
        </nav>
      </header>

      <div className="layout">
        <aside className="sidebar" aria-label="Guide navigation">
          <div className="search-box">
            <MagnifyingGlassIcon aria-hidden="true" />
            <input
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search guides"
              aria-label="Search guides"
            />
          </div>
          <p className="search-count">
            {visibleSections.length} of {sections.length} guides
          </p>
          <nav className="section-nav">
            {sections.map((section) => {
              const Icon = section.icon
              return (
                <a key={section.id} href={`#${section.id}`}>
                  <Icon aria-hidden="true" />
                  <span>{section.nav}</span>
                </a>
              )
            })}
          </nav>
        </aside>

        <main id="top" className="content">
          <section className="hero-doc">
            <p className="eyeline">Native Mac containers, machines, and agent sandboxes</p>
            <h1>Dory is powerful now. This is the guide to using it well.</h1>
            <p>
              A plain-language handbook for installing Dory, reaching Docker, importing data,
              creating Linux machines, running AI agents inside VM boundaries, and reproducing the
              benchmark evidence.
            </p>
            <div className="hero-actions">
              <a href="#install">Start with install</a>
              <a href="#agents">Copy the agent guide</a>
            </div>
          </section>

          {visibleSections.length === 0 ? (
            <section className="empty-state">
              <MagnifyingGlassIcon aria-hidden="true" />
              <h2>No guide matched “{query}”.</h2>
              <p>Try Docker, OrbStack, sandbox, env, benchmark, import, or machine.</p>
            </section>
          ) : (
            visibleSections.map((section) => <GuideArticle key={section.id} section={section} />)
          )}
        </main>
      </div>
    </div>
  )
}

function GuideArticle({ section }: { section: GuideSection }) {
  const Icon = section.icon
  return (
    <article id={section.id} className="guide-section">
      <div className="section-heading">
        <Icon aria-hidden="true" />
        <div>
          <p>{section.nav}</p>
          <h2>{section.title}</h2>
        </div>
      </div>
      <p className="summary">{section.summary}</p>
      {section.body?.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
      {section.bullets ? (
        <ul>
          {section.bullets.map((bullet) => (
            <li key={bullet}>
              <CheckCircleIcon aria-hidden="true" />
              <span>{bullet}</span>
            </li>
          ))}
        </ul>
      ) : null}
      {section.table ? <GuideTable table={section.table} /> : null}
      {section.codeBlocks?.map((block) => <CopyBlock key={block.label} block={block} />)}
    </article>
  )
}

function GuideTable({ table }: { table: GuideSection['table'] }) {
  if (!table) return null
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            {table.columns.map((column) => (
              <th key={column}>{column}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {table.rows.map((row) => (
            <tr key={row.join('|')}>
              {row.map((cell) => (
                <td key={cell}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function CopyBlock({ block }: { block: CodeBlock }) {
  const [copied, setCopied] = useState(false)

  async function copy() {
    await navigator.clipboard.writeText(block.code)
    setCopied(true)
    window.setTimeout(() => setCopied(false), 1400)
  }

  return (
    <div className="code-card">
      <div className="code-head">
        <span>{block.label}</span>
        <button type="button" onClick={copy}>
          <ClipboardDocumentIcon aria-hidden="true" />
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
      <pre>
        <code>{block.code}</code>
      </pre>
    </div>
  )
}

export default App

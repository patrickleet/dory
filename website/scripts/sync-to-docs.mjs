// Copies the Vite build (../docs-build) into ../docs, the GitHub Pages source.
// Only ever touches paths this build actually produces (index.html, assets/,
// favicons, screenshot.png, shots/) — hand-maintained docs/ content such as
// comparison.md, research/, appcast.xml, logo.svg, demo.gif, and .nojekyll are
// never in docs-build and are left untouched.
import { cp, rm, readdir, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.dirname(fileURLToPath(import.meta.url))
const buildDir = path.resolve(root, '../../docs-build')
const docsDir = path.resolve(root, '../../docs')

async function exists(p) {
  try {
    await stat(p)
    return true
  } catch {
    return false
  }
}

async function main() {
  if (!(await exists(buildDir))) {
    throw new Error(`build output not found at ${buildDir} — run the build first`)
  }

  const entries = await readdir(buildDir)
  for (const entry of entries) {
    const dest = path.join(docsDir, entry)
    await rm(dest, { recursive: true, force: true })
    await cp(path.join(buildDir, entry), dest, { recursive: true })
  }

  console.log(`synced ${entries.length} entries from docs-build/ into docs/`)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})

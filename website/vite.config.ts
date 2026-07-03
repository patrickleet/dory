import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Served from https://augani.github.io/dory/ (a project-pages subpath), and the
// built output lands in ../docs, which GitHub Pages serves as-is. Relative asset
// URLs keep the build portable regardless of the path depth it's served under.
export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    outDir: '../docs-build',
    emptyOutDir: true,
  },
})

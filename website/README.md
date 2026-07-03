# Dory landing page

Source for [augani.github.io/dory](https://augani.github.io/dory) — React + TypeScript + Vite,
builds directly into `../docs`, which GitHub Pages serves as-is.

```sh
npm install
npm run dev     # local dev server with HMR
npm run build   # typecheck, build, then sync the output into ../docs
```

`npm run build` writes to `../docs-build` (gitignored) and a `postbuild` script copies it into
`../docs`. Hand-maintained files that live in `docs/` but aren't part of this app
(`comparison.md`, `research/`, `appcast.xml`, `logo.svg`, `demo.gif`, `.nojekyll`) are never
touched by the sync step.

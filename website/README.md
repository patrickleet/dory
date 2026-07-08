# Dory landing page

Source for [augani.github.io/dory](https://augani.github.io/dory) — React + TypeScript + Vite,
published by GitHub Pages Actions from the generated `../docs-build` artifact.

```sh
npm install
npm run dev     # local dev server with HMR
npm run build   # typecheck and build into ../docs-build
```

`npm run build` writes to `../docs-build` (gitignored). GitHub Pages uploads that
directory directly in `.github/workflows/pages.yml`; `docs/` is also ignored and kept
for local-only notes or stale build artifacts.

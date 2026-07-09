# Dory Runtime Architecture

Status: adopted 2026-07-09.

Dory has four separate runtime roles. Keeping these roles separate is part of the product architecture, not an implementation detail.

## Owners

- `Dory.app` owns user intent and presentation. It opens settings, shows success/failure notices, reconciles the installed LaunchAgent, and asks `doryd` to start/wake/sleep the engine over XPC.
- `doryd` owns durable runtime state and engine lifecycle. Runtime mode and idle policy are read from `~/.dory/config.json` through `IdlePolicyStore`; doryd decides whether the Docker tier starts immediately or arms its socket for wake-on-use.
- `launchd` owns only daemon supervision. Its plist points at the bundled helpers, static ports, static domain suffix, logging, and KeepAlive/RunAtLoad. It must not carry user runtime mode.
- Helpers own execution. `dory-hv` owns the Docker VM, `dory-vmm` owns machine VMs, `gvproxy` owns userspace networking transport, and bundled CLI helpers are reconciled into `~/.dory/bin`.

## Startup Contract

On daemon launch:

- `always-on` starts the Docker tier immediately.
- `manual`, `auto-idle`, and `battery-saver` arm the Docker socket without treating launchd environment as policy.
- `DORYD_FORCE_AUTOSTART_DOCKER_TIER=1` is reserved for development smoke tests.

On app launch:

- the app reconciles the LaunchAgent from the installed bundle;
- if doryd is available but the engine is not running, the app promotes the engine to running so Docker commands work after opening Dory;
- idle policy decides whether doryd may sleep the engine again later.

On settings changes:

- runtime mode and idle policy are persisted through doryd and confirmed with an in-app notice;
- settings notices must describe the applied state, not only the requested state;
- if a settings action has multiple owners, for example host CLI files plus a daemon LaunchAgent refresh, the app must report partial application instead of a blanket success;
- LaunchAgent refreshes are for static daemon settings such as host CLI repair, domain suffix, and ports;
- settings failures use settings notices instead of unrelated global action errors.

## Docker Reachability Contract

Docker reachability is a product invariant, not a benchmark convenience.

- The stable user socket is `~/.dory/dory.sock`; app code should prefer the doryd-reported socket path when doryd owns the engine.
- Terminal integration installs stable user commands into `~/.dory/bin`; UI copy and terminal launch commands must use `docker`, `docker compose`, and `dory machine shell <name>`, not bundle-private helper paths.
- App terminal affordances may resolve private helpers for internal diagnostics, but user-facing machine shells require the stable `dory` command. `TerminalSession` must not carry bundle-private `dorydctl` paths.
- Opening Dory means "make Docker usable now." The app may promote a stopped or sleeping doryd-owned Docker tier to running, but doryd remains the owner of durable runtime mode and later sleep decisions.
- If doryd cannot start the Docker tier, the app must leave the backend as disconnected instead of silently falling back to another local Docker engine while the preference is Dory.

## Regression Guards

Keep tests around these boundaries:

- LaunchAgent plist generation must not include `DORYD_AUTOSTART_DOCKER_TIER`.
- stale launchd runtime hints must not override persisted runtime mode.
- the stable user command for machines is `dory machine shell <name>`, not a full helper path.
- legacy terminal-session payloads that contain private helper paths decode without reusing those paths.

## Engine Performance Contract

Performance work follows the same ownership split as lifecycle work.

- Product benchmarks must run against `/Applications/Dory.app` and its installed helpers unless the run is explicitly labeled as an experiment.
- LaunchAgent environment is not a tuning database. Temporary keys such as `DORYD_CPUS` may be used to falsify a hypothesis, but must be removed after the run unless the behavior is promoted into source and tests.
- Engine sizing, scheduler policy, storage semantics, cache policy, and file-sharing behavior belong in source-owned configuration paths, not hand-edited plists.
- A benchmark optimization graduates only when it has a source change, a regression guard or focused test where practical, an installed-app smoke, and a saved raw benchmark directory.
- Failed experiments must be actively reverted from source, the installed app, and the live LaunchAgent before another product-state run.
- Benchmark reports must separate product-state runs from one-off environment experiments.

The current benchmark strategy is:

- protect the shared-VM networking path, where Dory already leads;
- keep vCPU scheduling and I/O workers inside `dory-hv`, because those are custom-VMM advantages;
- avoid kernel churn until the engine execution path proves the guest kernel is the bottleneck;
- prefer narrow, falsifiable experiments over broad bundles of unrelated tuning.

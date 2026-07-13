# Changelog

## 0.3.0 - Local Runtime Release Candidate

This release is focused on the local product: a clean-Mac app, shared-VM runtime, Docker-compatible
workflow, Linux machines, migration confidence, managed settings, and public benchmark evidence.
Remote engines, cloud backup, relay services, and phone workflows remain intentionally deferred.

### Added

- Apple-Silicon-first self-contained release shape with an arm64 app, compatibility aliases, a lite
  app, and an arm64 headless engine tarball. Intel is a later roadmap phase.
- Bundled Docker CLI, Docker Buildx, Docker Compose v2, and `kubectl` for clean Macs.
- doryd-backed engine ownership with durable on-disk state and Linux machine lifecycle.
- Full Linux machines as isolated VMs, not Docker containers, with addresses, terminal commands,
  snapshots, resource settings, mounts, ports, and recipes.
- Migration confidence report for Docker Desktop and OrbStack sources, including transfer items,
  attention items, target-aware image disk, exact named-volume usage, existing Dory usage,
  host/engine capacity headroom, Compose projects, bind mounts, volume references, and risky
  container modes. Unknown or insufficient capacity now blocks before the first target write.
- Managed settings profile preview for local team rollout: engine route, domains, DNS/proxy ports,
  Auto-Idle policy, file-sharing policy, sandbox mount policy, hidden credential stores, env allow
  list, and telemetry mode `none`.
- App and menu-bar memory reporting for Dory processes.
- Public benchmark playbook and cross-engine GitHub workflow.

### Changed

- Public release manifests are now bound to the full source commit, and candidate construction,
  long qualification, and publication are separate jobs. The non-publishing qualification job runs
  the isolated 16→128 GiB growth/discard/persistence gate, the bounded
  concurrent-backpressure/restart/port-recovery gate, then the eight-hour endurance and
  25-hour same-TCP gates concurrently on one isolated exact runtime; a later job with fresh
  credentials must rehash the candidate and evidence, independently parse every retained gate
  result, and recheck the workflow run, attempt, commit, durations, notarization, and Sparkle
  contract before GitHub/Homebrew publication.
  Completed long-gate evidence is moved out of the short socket-path engine home after shutdown,
  avoiding a multi-gigabyte duplicate at the qualification job's peak disk usage.
- Public manifest artifact paths are now portable filenames; runner-local and absolute build paths
  are rejected before staging or publication.
- Release qualification, cold-start, and 16→128 GiB growth harnesses now keep isolated VM homes on
  deliberately short paths, fail before launch if any private Unix socket would exceed macOS's
  103-byte limit, and keep long evidence paths outside the runtime socket namespace.
- Public artifact validation now rejects XCTest bundles and `*Tests-Runner.app` payloads, preventing
  development-only UI test runners from leaking into the notarized app or Sparkle archive.
- All GitHub Actions dependencies are pinned to immutable commits, and invalid job-level
  `runner.temp` expressions in both release and physical-Intel workflows now initialize through
  `RUNNER_TEMP` at runtime. Every workflow passes semantic Actions linting.
- Removed the unqualified public “~0% idle CPU” number; public copy now points to the attributed
  eight-hour CPU/RSS/FD plateau required for each immutable release candidate.
- Hardened competitor regression coverage against process-wide proxy head-of-line blocking: six
  deliberately unread multi-megabyte Docker log streams must not prevent twelve concurrent control
  requests from completing, and the gate checks engine FD recovery afterward.
- Added an opt-in 25-hour same-connection TCP soak for the competitor failure where active published
  connections drop at the 24-hour boundary; shortened runs are explicitly reported as not proving it.
- Writable-layer migration now preflights both its deterministic final and rollback image references,
  and an injected replacement-bind failure proves the prior owned snapshot tag is restored.
- Opening Dory now asks doryd to make the Docker engine usable immediately. Auto-Idle remains
  daemon-owned and may stop an empty engine again after the configured idle period.
- doryd's idle policy can stop an empty Docker tier while keeping state on disk; active or unknown
  workloads are preserved.
- macOS 14 is the app floor and uses the bundled Virtualization.framework `dory-vmm` engine tier
  when its guest assets are present. The raw Hypervisor.framework `dory-hv` tier requires macOS 15+;
  installs without a supported built-in tier can still use an existing Docker-compatible engine.
- Release bundling now uses the same default host CLI versions as the development build path.

### Fixed

- Fixed OrbStack/Docker imports of named volumes and containers: Dory now uses portable volume
  names instead of source-daemon storage paths, removes duplicate mount declarations and stale
  network IDs, resumes only Dory-owned partial imports, preserves inspected container settings and
  running/stopped state, and reports the Docker API's exact failure instead of a generic message.
  Deleted image tags now use separate valid source and restored target references for volume-copy
  helpers, so a successful content-ID image fallback cannot strand the corresponding volume. If
  two Docker daemon versions normalize the loaded archive to a different content ID, Dory binds
  the newly loaded image directly and removes failed-attempt dangling images instead of leaking
  hundreds of megabytes or unnecessarily committing the source container. Containers whose only
  surviving reference is a bare source-daemon content ID are rewritten to a portable retained
  Dory reference, and a failed start/pause removes only the container created by that migration
  attempt so retrying cannot be blocked by a stranded same-name object. Migration now also
  preserves full custom-network driver/IPAM/options, static endpoint intent, and advanced Docker
  mount options; preflights tag/object/subnet conflicts globally; keys partial ownership to a
  privacy-preserving stable source socket identity; snapshots deleted-tag containers without
  pausing them or reusing user tags; bounds and cancels archive I/O; and reports helper cleanup
  failures. Empty, detached, driver-compatible same-name target volumes can be adopted while
  preserving their labels; every non-empty/attached conflict is listed and blocks before images.
  If a later archive or legacy-network replacement fails, Dory now restores the adopted empty
  volume metadata or original detached network contract instead of leaving target metadata missing.
  Running volume-backed sources must be stopped or paused by the user, while running containers
  with fixed host ports are created stopped until the source engine releases those ports instead
  of being discarded after an expected bind conflict.
  Container files written outside volumes are no longer silently dropped: strict `SizeRw`
  inventory includes them in capacity admission, running changed containers require an explicit
  user stop/pause, and stopped or paused layers are streamed from non-pausing owned snapshots and
  used as the recreated container image.
- Preserved v0.2 Docker state during the engine cutover by validating and APFS-cloning the legacy
  ext4 data disk on first start. The original Apple-container disk is left untouched for rollback;
  the raw-HV and macOS 14 VZ tiers both attach the cloned Docker store.
- Dory no longer replaces or removes a user's pre-existing Docker Buildx or Compose CLI plugin.
  Install, daemon reconciliation, and uninstall mutate plugin symlinks only when Dory can prove it
  owns them.
- Prevented duplicate LaunchServices app instances with `LSMultipleInstancesProhibited`.
- Signed and verified both the test host and `DoryUITests-Runner` before UI execution, preventing
  Gatekeeper's misleading “damaged and can’t be opened” failure for local release-gate tests.
- Made doryd's Docker system-disk probe request only container data, wait for a complete bounded
  response, and avoid cancelling dockerd's snapshot walk on larger installations.
- Prevented concurrent raw-HV or VZ helpers from mounting the same persistent ext4 Docker disk;
  engine state is explicit and protected by a nonblocking owner-reporting lock.
- Detects sparse Docker disks truncated below the filesystem length declared by their ext4
  superblock, rejects ext4 magic with invalid filesystem geometry before sparse growth, and refuses
  to attach either case. Existing ext4 disks that fail e2fsck, resize, or mount now power off
  fail-closed; `mkfs.ext4` is reachable only when the host proved the disk is an unallocated blank.
- Removed the former 16 GiB Docker-storage ceiling. New and existing data disks grow sparsely to
  128 GiB, the guest validates and expands ext4 before mounting, and diagnostics report physical
  APFS allocation rather than the sparse logical capacity. Boot and graceful shutdown issue
  `fstrim` through virtio discard so deleted Docker data returns blocks to APFS. The isolated growth
  gate seeds a 16 GiB filesystem with physically allocated free extents, proves discard reclaim and
  guest capacity, verifies named-volume persistence after restart, and never touches the user's
  engine state. On backing filesystems without hole punching, plain discard now safely no-ops
  instead of zero-writing and accidentally allocating the entire discarded range. The backend also
  rejects disabled, oversized, over-segmented, or unknown-flag discard/write-zeroes requests before
  mutating any range, matching the limits advertised to the guest.
- Forced standalone-engine shutdown now reaps a reparented, state-owned `gvproxy` sidecar using
  both private socket paths as its ownership identity; unrelated engine processes are untouched.
- Added the app's Docker-create compatibility dataplane to the headless runtime, fixing explicit
  loopback UDP/TCP publishing. LAN opt-in now preserves explicit loopback intent instead of
  widening it after guest-binding normalization.
- Fixed bind-mount service-user ownership (`chown 999:999`) by virtualizing guest UID/GID without
  changing host APFS ownership, including refresh, hard-link, and replacement behavior.
- Fixed stale bind-file metadata across same-inode shrink/grow/content changes and atomic
  replacement, with a dedicated live coherence gate.
- Resolved standalone legacy-disk import from the launcher's explicit home and added fail-closed
  state/PID/socket protections plus a destructive dedicated-engine prune contract.
- The Apple-Silicon standalone engine now enables bundled FEX/amd64 by default and persists its
  CPU, memory, translation, GPU, LAN, and selected data-drive settings across stop/start. An
  explicit `--no-amd64` opt-out remains available, so a plain restart cannot strand containers
  whose recorded OCI runtime is `dory-runc`.
- Added an authenticated private-registry gate covering rejected anonymous pulls, login,
  pull/push, BuildKit registry credentials and secret mounts, and save/load without retaining test
  credentials.

### Known Limits

- Apple Silicon now uses the bundled FEX runtime instead of qemu-user for the advertised common
  amd64 development-image contract. Native arm64 images remain faster, and x86-only products not
  covered by the release gates still require product-specific qualification.
- Intel raw `dory-hv` support is wired and packaged, but full readiness remains gated by physical
  Intel Mac release testing.
- Native container IPv6, external LAN/source-IP preservation, and physical sleep/VPN campaigns are
  still tracked as network parity work before broad marketing claims. Host IPv4/IPv6 localhost and
  TCP/UDP publication are covered.

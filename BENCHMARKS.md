# Dory Benchmarks

Dory publishes benchmarks as raw, reproducible runs, not screenshots. Every public number should
come with the machine spec, the command used, raw TSV/JSON output, and a note about which engines
were installed and running on the same Mac.

The main harness is [`scripts/benchmark-compare.sh`](scripts/benchmark-compare.sh). It compares Dory
against Docker Desktop and OrbStack by default. Apple's separate `container` CLI can be added as an
optional competitor on macOS 26+ hosts, but it is not part of the default 0.3 release benchmark.

## What 0.3 Measures

| Metric | Why it matters | Harness |
|---|---|---|
| Idle memory | Shows the cost users feel when a container runtime is sitting in the background. | `--metrics memory` |
| CPU workload | Shows runtime/startup/scheduling overhead for the same repeated CPU-bound task. | `--metrics cpu` |
| Container-to-container network | Shows the shared-VM bridge path that real Compose stacks use. | `--metrics network` |
| Bind-mount filesystem | Shows the host-to-VM path used by editors, hot reload, and local source mounts. | `--metrics fs` |

Every run writes:

- `machine-spec.tsv`: Mac model, memory, CPU, macOS build, Docker client, optional Apple
  Container CLI, and the released Dory.app identity when `--dory-app` is used.
- `engine-versions.tsv`: per-engine interface, endpoint, server/CLI version, OS/kernel, and arch.
- `memory.tsv`, `cpu.tsv`, `network.tsv`, `filesystem.tsv`: raw per-metric data.
- `status.tsv`: pass, fail, and skip reasons per engine.
- `summary.md`: a publishable local table generated from the raw TSV files.
- `summary.json`: machine-readable aggregate for GitHub Actions artifacts and scripts.

## Current Local Evidence

These are the local measurements we can already stand behind. We should keep replacing this section
with fresh raw artifacts as 0.3 release candidates are rebuilt.

| Claim | Current evidence | Publication note |
|---|---|---|
| Dory uses one shared Linux VM for all containers. | Architecture and release bundle verification in [`COMPATIBILITY.md`](COMPATIBILITY.md). | This is a design fact and does not require a competitor run. |
| Dory has measured roughly 122 MB for two idle containers versus roughly 574 MB as per-container VMs on the same Mac. | Legacy focused harness [`scripts/benchmark.sh`](scripts/benchmark.sh), retained for continuity. | Treat as Dory's own measurement until a fresh `benchmark-compare.sh` artifact is attached to the release. |
| Dory measured 97.77 Gbps median container-to-container throughput on one Apple-silicon Mac. | `BENCH_IPERF_IMAGE=taoyou/iperf3-alpine:latest scripts/benchmark-compare.sh --dory-app /Applications/Dory.app --engines dory --metrics memory,cpu,network,fs --memory-counts 0,1,3,5,10 --runs 3 --cpu-mb 256 --fs-files 2000`, raw run `.benchmark-results/20260708T184829Z-32856`. | Same-machine competitor runs are listed below; publish medians with the raw artifacts. |
| Dory does not need to wake the heavy engine just because the app opens. | doryd/app tests attach to a sleeping daemon without calling `engineStart()`. | This supports the "idle means idle" UX claim. |

## July 8, 2026 Local Snapshot

These runs were taken sequentially on the same Mac: Mac14,10, Apple M2 Pro, 16 GB RAM,
macOS 27.0 build 26A5368g, Darwin 27.0.0 arm64. Dory was measured from an installed
`/Applications/Dory.app` local benchmark build, version 0.3.1 build 2. OrbStack and Colima were
installed with Homebrew, run one at a time, then stopped.

| Engine | Docker server | CPU median, 256 MiB sha256 | C2C network median | Bind mount, 2000 files | In-container, 2000 files | Raw artifact |
|---|---:|---:|---:|---:|---:|---|
| Dory | 27.5.1 | 2.1020 s | 97.7721 Gbps | 0.6880 s | 0.7730 s | `.benchmark-results/20260708T184829Z-32856` |
| OrbStack | 29.4.0 | 1.7190 s | 90.1203 Gbps | 0.2220 s | 0.2970 s | `.benchmark-results/20260708T185520Z-45964` |
| Colima | 29.5.2 | 1.5750 s | 80.9901 Gbps | 0.1590 s | 0.2310 s | `.benchmark-results/20260708T185955Z-63870` |

The same runs also captured idle-memory rows for 0, 1, 3, 5, and 10 `alpine:latest` containers.
Those rows are preserved in each `memory.tsv`, but several system-memory and process-RSS deltas
went negative while macOS compressed/reclaimed pages. Do not publish a memory winner from this
snapshot without rerunning the memory metric under a quieter setup.

## Reproduce A Full Run

Run this on a physical Mac, not a GitHub-hosted macOS runner. Hosted macOS runners are VMs and do not
have the nested virtualization needed for this benchmark.

```sh
# Audit the work before touching any engine:
scripts/benchmark-compare.sh \
  --engines dory,orbstack,docker-desktop \
  --metrics memory,cpu,network,fs \
  --dry-run

# Live cross-engine run against the installed release app:
BENCH_WORKDIR="$PWD/.benchmark-results" \
scripts/benchmark-compare.sh \
  --dory-app /Applications/Dory.app \
  --engines dory,orbstack,docker-desktop \
  --metrics memory,cpu,network,fs \
  --memory-counts 0,1,3,5,10 \
  --runs 3 \
  --cpu-mb 256 \
  --fs-files 2000
```

For a Dory-only release candidate smoke:

```sh
BENCH_WORKDIR="$PWD/.benchmark-results" \
scripts/benchmark-compare.sh \
  --dory-app /Applications/Dory.app \
  --engines dory \
  --metrics memory,cpu,network,fs \
  --memory-counts 0,1,3
```

## GitHub Workflow

The [Benchmark workflow](.github/workflows/benchmark.yml) is manual and scheduled, but it only runs
on a self-hosted Mac labeled `self-hosted`, `macOS`, and `dory`. It uploads the full result directory
as a GitHub Actions artifact.

Recommended runner matrix for 0.3:

| Runner | Required labels | Engines |
|---|---|---|
| Apple silicon, macOS 15+ | `self-hosted`, `macOS`, `dory` | Dory, Docker Desktop, OrbStack |
| Apple silicon, macOS 26+ optional competitor run | `self-hosted`, `macOS`, `dory`, `apple-container` | Dory, Docker Desktop, OrbStack, Apple Container |
| Intel, macOS 14/15+ | `self-hosted`, `macOS`, `dory`, `intel` | Dory Intel beta, Docker Desktop, Colima/OrbStack where supported |

## Publication Rules

- Publish raw artifacts with every table.
- Disclose the Mac model, RAM, chip, macOS build, engine versions, and date.
- Report medians and keep the raw TSV rows.
- Do not mix cold image pulls into warm runtime numbers.
- Do not compare Apple Container networking as if it used Docker bridge semantics. It is
  host-routed between separate VMs.
- Do not publish Dory-vs-OrbStack or Dory-vs-Docker multipliers until those engines were measured
  on the same machine in the same run.
- Do not publish filesystem speed-up claims from write-back-cached bind mounts unless the workload
  includes a durability check.

The boring rule is the useful one: if a skeptical developer cannot rerun the exact command and see
the raw files, it is not a release benchmark yet.

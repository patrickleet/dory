# Dory virtio-fs file sharing: benchmark and analysis

Date: 2026-07-04. Host: Apple Silicon, macOS 27.0.

This is the Track 1 (virtio-fs) file-sharing data-plane validation and the OrbStack comparison
the roadmap made an exit criterion. It is measured end to end, not simulated.

## How it was measured

- **Dory**: a real `dory-hv` guest (kernel `6.12.30-dory`, built from `guest/kernel/`) boots a
  minimal Alpine rootfs and mounts a `--share` of a macOS directory as `virtiofs`, then runs the
  workload directly on the shared mount. This exercises the actual VirtioFS device + FUSE server
  (`Packages/ContainerizationEngine/Sources/DoryHV/VirtioFS.swift`, `Fuse/`).
- **OrbStack**: the same macOS directory is bind-mounted into a container and the same workload runs
  on it, exercising OrbStack's file-sharing data plane.
- **Docker Desktop**: not installed on this host, so it is absent from the table. The harness
  (`scripts/benchmark.sh fileshare`) will include it automatically when its socket is present.
- Workload: `fio` 4k random read (128 MiB, iodepth 16, 15s), a 128 MiB `dd` write, and
  `git status` on a 4067-file repository. Same parameters on both engines.

## Results

| Metric | Dory virtio-fs (plain) | OrbStack | Ratio |
|---|---|---|---|
| fio 4k randread | 19,764 IOPS (~77 MB/s) | 111,820 IOPS (~437 MB/s) | OrbStack ~5.6x faster |
| dd 128 MiB write | 0.19 s | 0.20 s | comparable |
| git status (4067 files) | ~0.01 s | ~0.4 s | Dory faster on metadata |

(git-status absolute times are near the guest timer resolution; the point is that metadata-heavy
traversal is not a weakness — Dory's FUSE server answers `getattr`/`lookup` from a host-side
`fstatat`, which is efficient.)

## Reading the numbers honestly

- **virtio-fs works end to end.** The device, FUSE protocol negotiation (floor 7.27), HostFS
  (uid squash, `O_NOFOLLOW`, `..` rejection), and the guest mount all function on a from-source
  Dory kernel. This closes the "no end-to-end guest-boot virtio-fs gate" gap the completion audit
  flagged.
- **Write and metadata are already competitive.** Sequential write matches OrbStack; metadata
  traversal (the git-status case) is fast because reads of file attributes go straight to a host
  `fstatat` rather than through a caching layer.
- **Random-read throughput is behind OrbStack (~5.6x).** This is expected and diagnostic: the
  current FUSE server services each `READ` with a synchronous request on the vCPU thread and a
  full-buffer copy (the deferred review finding #30: move blocking I/O off the vCPU thread and use
  zero-copy segment views over guest memory). Random 4k read is the workload most sensitive to that
  per-request round-trip, so it is where the gap shows.

## The path to close the gap (both are already-scoped work)

1. **DAX** (Track 1.7). The host primitive is proven: `dory-hv daxprobe` confirms `hv_vm_map` of a
   file-backed mmap into guest PA is coherent both directions. DAX bypasses the FUSE round-trip for
   reads entirely (the guest reads mapped pages directly), which directly targets the 4k-randread
   gap. What is NOT yet working is the guest-side DAX *activation*: mounting `-o dax` reports
   `virtio-fs: dax can't be enabled as filesystem device does not support it` — the guest is not yet
   accepting the advertised SHM window as a `dax_device` (guest `memremap` over the window + lazy
   `FUSE_SETUPMAPPING` population). The MMIO SHM registers and FUSE_INIT map-alignment are wired; the
   remaining work is the guest window/`dax_device` handshake. This is the honest go/no-go outcome the
   spike anticipated: host mechanism proven, guest activation deferred, feature behind the `:dax` flag.
2. **Off-vCPU-thread FUSE I/O + zero-copy** (review finding #30). Dispatch blocking `pread`/`pwrite`
   off the vCPU thread and write results directly into the device-writable virtqueue segment,
   removing both the vCPU stall and the two intermediate buffer copies per request.

## Reproducing

```sh
# Dory side (needs a built guest kernel + a signed dory-hv):
guest/kernel/build.sh                       # produces guest/out/Image
dory-hv boot --kernel guest/out/Image --disk <fio-rootfs.ext4> \
  --share bench=<macos-dir>:rw --cmdline "console=ttyAMA0 root=/dev/vda rw init=/init"
# Competitors (auto-detected sockets):
scripts/benchmark.sh fileshare
```

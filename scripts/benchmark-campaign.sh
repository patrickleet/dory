#!/bin/bash
# Full competitive benchmark campaign: for each engine, INSTALL -> START (per VM profile) -> MEASURE
# -> STOP -> UNINSTALL + PURGE, so every engine is measured in isolation with nothing else installed.
# Dory is measured last against a signed Release Dory.app.
#
# The actual measurement is delegated to scripts/benchmark-compare.sh (same probe for every engine).
# This orchestrator only owns the lifecycle: clean install, VM sizing, socket wait, and complete purge.
#
# Two VM-fairness profiles run per engine:
#   pinned  -- every VM capped to the same vCPU/RAM ceiling (CAMPAIGN_PINNED_CPUS/_MEM_GB), so the
#              comparison isolates engine overhead, not who ships a bigger VM. Note that OrbStack and
#              Dory reclaim RAM dynamically, so "pinned" is a ceiling; Colima/Podman reserve it.
#   default -- each engine exactly as it installs, i.e. the out-of-the-box experience.
#
# SAFETY: engines are installed and PURGED one at a time (only one competitor VM exists at any moment),
# which keeps disk and memory bounded on a 16 GB / limited-disk Mac. Any engine that fails to install,
# start, or measure is recorded and SKIPPED; the campaign continues to the next.
#
# Usage:
#   scripts/benchmark-campaign.sh --dory-app release-build/export-arm64/Dory.app
#   scripts/benchmark-campaign.sh --engines colima,podman --profiles default --dry-run
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPARE="$ROOT/scripts/benchmark-compare.sh"

ENGINES="${CAMPAIGN_ENGINES:-orbstack,colima,podman,dory}"
PROFILES="${CAMPAIGN_PROFILES:-pinned,default}"
PINNED_CPUS="${CAMPAIGN_PINNED_CPUS:-6}"
PINNED_MEM_GB="${CAMPAIGN_PINNED_MEM_GB:-6}"
DEFAULT_LABEL_CPUS="${CAMPAIGN_DEFAULT_CPUS:-}"   # informational only; empty means engine default
RUNS="${CAMPAIGN_RUNS:-2}"
MEMORY_COUNT="${CAMPAIGN_MEMORY_COUNT:-3}"
METRICS="${CAMPAIGN_METRICS:-memory,build}"
DORY_APP="${CAMPAIGN_DORY_APP:-$ROOT/release-build/export-arm64/Dory.app}"
DRY_RUN="${DRY_RUN:-0}"
SOCKET_WAIT="${CAMPAIGN_SOCKET_WAIT:-120}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
CAMPAIGN_DIR="${CAMPAIGN_WORKDIR:-$HOME/.dory-benchmark/campaign-$RUN_ID}"
CAMPAIGN_LOG="$CAMPAIGN_DIR/campaign.log"
CAMPAIGN_TSV="$CAMPAIGN_DIR/campaign-results.tsv"

mkdir -p "$CAMPAIGN_DIR"
printf 'engine\tprofile\tresult\tresult_dir\tdetail\n' > "$CAMPAIGN_TSV"

log()  { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$CAMPAIGN_LOG" >&2; }
run()  { log "+ $*"; [ "$DRY_RUN" = "1" ] && return 0; "$@"; }
brewq() { run brew "$@"; }

disk_free_gb() { df -g / | awk 'NR==2 { print $4 }'; }

record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}" >> "$CAMPAIGN_TSV"
  log "RESULT $1/$2: $3 ${5:-}"
}

pinned_mem_mib() { echo $(( PINNED_MEM_GB * 1024 )); }

# Wait until $1 is a live docker socket answering `version`, up to SOCKET_WAIT seconds.
wait_docker_sock() {
  local sock="$1" waited=0
  [ "$DRY_RUN" = "1" ] && return 0
  while [ "$waited" -lt "$SOCKET_WAIT" ]; do
    [ -S "$sock" ] && docker -H "unix://$sock" version >/dev/null 2>&1 && return 0
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

measure() {
  local engine="$1" profile="$2" sockenv="$3" sock="$4" extra_env="${5:-}"
  local out="$CAMPAIGN_DIR/$engine-$profile"
  mkdir -p "$out"
  local jobs="$PINNED_CPUS"
  [ "$profile" = "default" ] && jobs="8"
  log "measuring $engine [$profile] -> $out"
  if [ "$DRY_RUN" = "1" ]; then
    log "+ (dry-run) BENCH_WORKDIR=$out $sockenv=$sock benchmark-compare --engines $engine --metrics $METRICS"
    record "$engine" "$profile" "DRY" "$out" "dry-run"
    return 0
  fi
  local dory_app_arg=""
  [ "$engine" = "dory" ] && dory_app_arg="--dory-app $DORY_APP"
  # shellcheck disable=SC2086
  if env "$sockenv=$sock" $extra_env BENCH_WORKDIR="$out" BENCH_BUILD_JOBS="$jobs" \
       METRICS="$METRICS" BENCH_RUNS="$RUNS" BENCH_MEMORY_COUNT="$MEMORY_COUNT" \
       "$COMPARE" --engines "$engine" --metrics "$METRICS" $dory_app_arg \
       >"$out/compare.log" 2>&1; then
    record "$engine" "$profile" "OK" "$out" "$(grep -hE 'median=|delta' "$out"/*/status.tsv 2>/dev/null | tr '\n' ';' | cut -c1-200)"
  else
    record "$engine" "$profile" "MEASURE_FAILED" "$out" "see compare.log"
  fi
}

# ---- OrbStack ------------------------------------------------------------------------------------
install_orbstack() { brewq install --cask orbstack; }
start_orbstack() {
  local profile="$1"
  if [ "$profile" = "pinned" ]; then
    run orb config set cpu "$PINNED_CPUS" 2>/dev/null || log "note: orb config set cpu unsupported; OrbStack default CPU"
    run orb config set memory_mib "$(pinned_mem_mib)" 2>/dev/null || log "note: orb config set memory_mib unsupported; OrbStack manages memory dynamically"
  fi
  run orb start 2>/dev/null || run open -a OrbStack
  wait_docker_sock "$HOME/.orbstack/run/docker.sock"
}
stop_orbstack() { run orb stop 2>/dev/null || true; }
purge_orbstack() {
  run orb stop 2>/dev/null || true
  run orb delete-data -y 2>/dev/null || true
  run osascript -e 'quit app "OrbStack"' 2>/dev/null || true
  brewq uninstall --cask --zap orbstack 2>/dev/null || brewq uninstall --cask orbstack 2>/dev/null || true
  run rm -rf "$HOME/.orbstack" "$HOME/Library/Application Support/OrbStack" \
      "$HOME/Library/Caches/dev.orbstack.OrbStack" "$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack" 2>/dev/null || true
}

# ---- Colima --------------------------------------------------------------------------------------
install_colima() { brewq install colima; }
start_colima() {
  local profile="$1"
  if [ "$profile" = "pinned" ]; then
    run colima start --cpu "$PINNED_CPUS" --memory "$PINNED_MEM_GB" --disk 20
  else
    run colima start
  fi
  wait_docker_sock "$HOME/.colima/default/docker.sock"
}
stop_colima() { run colima stop 2>/dev/null || true; }
purge_colima() {
  run colima delete -f 2>/dev/null || true
  brewq uninstall colima 2>/dev/null || true
  run rm -rf "$HOME/.colima" "$HOME/.lima/colima" 2>/dev/null || true
}

# ---- Podman --------------------------------------------------------------------------------------
install_podman() { brewq install podman; }
start_podman() {
  local profile="$1"
  run podman machine rm -f podman-machine-default 2>/dev/null || true
  if [ "$profile" = "pinned" ]; then
    run podman machine init --cpus "$PINNED_CPUS" --memory "$(pinned_mem_mib)" --disk-size 20
  else
    run podman machine init
  fi
  run podman machine start
  if [ "$DRY_RUN" != "1" ]; then
    PODMAN_SOCK="$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)"
    export PODMAN_SOCK
    log "podman socket: $PODMAN_SOCK"
    wait_docker_sock "$PODMAN_SOCK"
  fi
}
stop_podman() { run podman machine stop 2>/dev/null || true; }
purge_podman() {
  run podman machine stop 2>/dev/null || true
  run podman machine rm -f 2>/dev/null || true
  brewq uninstall podman 2>/dev/null || true
  run rm -rf "$HOME/.local/share/containers" "$HOME/.config/containers" 2>/dev/null || true
}

# ---- Dory (signed Release app) -------------------------------------------------------------------
install_dory() {
  [ -d "$DORY_APP" ] || { log "ERROR: Dory release app not found at $DORY_APP"; return 1; }
  log "using signed Release Dory.app at $DORY_APP"
}
start_dory() {
  local profile="$1"
  # Dory reclaims RAM dynamically (free-page reporting); the pinned profile sets a ceiling via env
  # consumed by the launch agent. If the app auto-sizes, this is a no-op and is footnoted.
  if [ "$profile" = "pinned" ]; then
    export DORYD_CPUS="$PINNED_CPUS" DORYD_MEMORY_MB="$(pinned_mem_mib)"
  else
    unset DORYD_CPUS DORYD_MEMORY_MB 2>/dev/null || true
  fi
  # prepare_dory_release_app inside benchmark-compare opens the app and waits for the socket.
  return 0
}
stop_dory() { run osascript -e 'quit app "Dory"' 2>/dev/null || true; run pkill -f 'dory-hv|doryd' 2>/dev/null || true; }
purge_dory() { :; }  # do not uninstall the user's Dory; it is the product under test

engine_defined() { type "install_$1" >/dev/null 2>&1; }

run_engine() {
  local engine="$1" profile sockenv sock
  if ! engine_defined "$engine"; then
    record "$engine" "-" "UNKNOWN_ENGINE" "" "no recipe"
    return
  fi
  case "$engine" in
    orbstack) sockenv="ORBSTACK_SOCK"; sock="$HOME/.orbstack/run/docker.sock" ;;
    colima)   sockenv="COLIMA_SOCK";   sock="$HOME/.colima/default/docker.sock" ;;
    podman)   sockenv="PODMAN_SOCK";   sock="" ;;
    dory)     sockenv="DORY_SOCK";     sock="$HOME/.dory/dory.sock" ;;
  esac

  log "===== ENGINE $engine (disk free $(disk_free_gb)G) ====="
  if ! "install_$engine"; then
    record "$engine" "-" "INSTALL_FAILED" "" "install recipe returned non-zero"
    "purge_$engine" 2>/dev/null || true
    return
  fi

  local OLD_IFS="$IFS"; IFS=','
  for profile in $PROFILES; do
    IFS="$OLD_IFS"
    profile="$(printf '%s' "$profile" | tr -d ' ')"
    [ -n "$profile" ] || { IFS=','; continue; }
    if ! "start_$engine" "$profile"; then
      record "$engine" "$profile" "START_FAILED" "" "start/socket-wait failed"
      "stop_$engine" 2>/dev/null || true
      IFS=','; continue
    fi
    [ "$engine" = "podman" ] && sock="${PODMAN_SOCK:-}"
    measure "$engine" "$profile" "$sockenv" "$sock"
    "stop_$engine" 2>/dev/null || true
    IFS=','
  done
  IFS="$OLD_IFS"

  log "purging $engine ..."
  "purge_$engine" 2>/dev/null || true
  log "disk free after $engine purge: $(disk_free_gb)G"
}

log "campaign $RUN_ID engines=$ENGINES profiles=$PROFILES pinned=${PINNED_CPUS}cpu/${PINNED_MEM_GB}GB runs=$RUNS"
log "results dir: $CAMPAIGN_DIR"
[ "$DRY_RUN" = "1" ] && log "DRY RUN -- no installs, starts, or measurements are executed"

OLD_IFS="$IFS"; IFS=','
for engine in $ENGINES; do
  IFS="$OLD_IFS"
  engine="$(printf '%s' "$engine" | tr -d ' ')"
  [ -n "$engine" ] && run_engine "$engine"
  IFS=','
done
IFS="$OLD_IFS"

log "===== CAMPAIGN COMPLETE ====="
column -t -s "$(printf '\t')" "$CAMPAIGN_TSV" 2>/dev/null | tee -a "$CAMPAIGN_LOG" || cat "$CAMPAIGN_TSV"
log "raw results under: $CAMPAIGN_DIR"

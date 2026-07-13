#!/bin/bash
# Destructive prepublication upgrade/rollback gate for a clean, dedicated physical Apple-silicon
# release user. It starts the latest older public Dory build, creates owned Docker state, makes
# Sparkle 2's real updater download/replace/relaunch that running app with the exact notarized
# candidate, verifies migration and candidate correctness, then rolls back to the byte-identical
# older app and verifies that user state was not deleted.
#
# Safety contract:
#   * refuses any pre-existing Dory state, preference domain, LaunchAgent, context, or process;
#   * only removes Docker resources carrying this run's ownership label;
#   * only removes ~/.dory and app support after verifying an ownership marker created by this run;
#   * never prunes Docker/container storage and never touches an installed /Applications/Dory.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CANDIDATE_APP="${1:-}"
SPARKLE_UPDATE_ZIP="${2:-${DORY_SPARKLE_UPDATE_ZIP:-}}"
SPARKLE_APPCAST="${3:-${DORY_SPARKLE_APPCAST:-}}"
TEAM_ID="${DORY_RELEASE_TEAM_ID:-864H636QW4}"
PREF_DOMAIN="com.pythonxi.Dory"
SERVICE="gui/$(id -u)/dev.dory.doryd"
PLIST="$HOME/Library/LaunchAgents/dev.dory.doryd.plist"
STATE="$HOME/.dory"
APP_SUPPORT="$HOME/Library/Application Support/com.pythonxi.Dory"
RUN_TOKEN="${GITHUB_RUN_ID:-local}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ID="$(printf '%s' "$RUN_TOKEN" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_.-' | cut -c 1-56)"
LABEL_KEY="dev.dory.release-upgrade"
TEST_ROOT=""
DOWNLOAD_ROOT=""
PREVIOUS_ROOT=""
INSTALL_ROOT=""
INSTALLED_APP=""
LOG_ROOT=""
STATE_OWNER="$STATE/.release-upgrade-gate-owner"
SUPPORT_OWNER="$APP_SUPPORT/.release-upgrade-gate-owner"
DOCKER_OWNER="$HOME/.docker/.release-upgrade-gate-owner"
STOPPED_NAME="dory-upgrade-stopped-$RUN_ID"
RUNNING_NAME="dory-upgrade-running-$RUN_ID"
STOPPED_VOLUME="dory-upgrade-stopped-$RUN_ID"
RUNNING_VOLUME="dory-upgrade-running-$RUN_ID"
NETWORK_NAME="dory-upgrade-network-$RUN_ID"
IMAGE_REF="${DORY_RELEASE_UPGRADE_IMAGE:-}"
STOPPED_ID=""
RUNNING_ID=""
NETWORK_ID=""
IMAGE_ID=""
CURRENT_APP_PID=""
CURRENT_SOCKET=""
PREVIOUS_APP=""
PREVIOUS_VERSION=""
PREVIOUS_BUILD=""
CANDIDATE_VERSION=""
CANDIDATE_BUILD=""
PREVIOUS_KIND=""
CONTAINER_CLI=""
LEGACY_OUTER_OWNED=0
CLEANING=0
SPARKLE_CLI=""
SPARKLE_FEED_PID=""
SPARKLE_FEED_URL=""
PREVIOUS_CONTEXT=default
DOCKER_CONFIG_EXISTED=1
PROFILE_PATHS=("$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile")
PROFILE_EXISTED=()

fail() {
  echo "release upgrade/rollback smoke error: $*" >&2
  exit 1
}

initialize_test_root() {
  local base
  if [ -z "$TEST_ROOT" ]; then
    base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
    mkdir -p "$base"
    TEST_ROOT="$(mktemp -d "$base/dory-release-upgrade-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}.XXXXXX")" \
      || fail "could not allocate a collision-safe release gate directory"
  fi
  DOWNLOAD_ROOT="$TEST_ROOT/download"
  PREVIOUS_ROOT="$TEST_ROOT/previous"
  INSTALL_ROOT="$TEST_ROOT/install"
  INSTALLED_APP="$INSTALL_ROOT/Dory.app"
  LOG_ROOT="$TEST_ROOT/evidence"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

app_cdhash() {
  codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1
}

app_tree_digest() {
  python3 - "$1" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob("*"), key=lambda value: value.relative_to(root).as_posix()):
    relative = path.relative_to(root).as_posix()
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if path.is_symlink():
        record = f"L\0{relative}\0{mode:o}\0{os.readlink(path)}\0".encode()
        digest.update(record)
    elif path.is_file():
        digest.update(f"F\0{relative}\0{mode:o}\0{metadata.st_size}\0".encode())
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")
    elif path.is_dir():
        digest.update(f"D\0{relative}\0{mode:o}\0".encode())
    else:
        raise SystemExit(f"unsupported app payload entry: {relative}")
print(digest.hexdigest())
PY
}

stop_sparkle_feed() {
  local pid="${SPARKLE_FEED_PID:-}"
  [ -n "$pid" ] || return 0
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  SPARKLE_FEED_PID=""
  SPARKLE_FEED_URL=""
}

socket_ready() {
  local socket="$1"
  [ -S "$socket" ] \
    && curl -fsS --max-time 3 --unix-socket "$socket" http://d/_ping 2>/dev/null \
      | grep -q '^OK$'
}

docker_on() {
  local socket="$1"
  shift
  "$CANDIDATE_APP/Contents/Helpers/docker" -H "unix://$socket" "$@"
}

owned_container_label() {
  docker_on "$1" inspect --format "{{ index .Config.Labels \"$LABEL_KEY\" }}" "$2" 2>/dev/null || true
}

owned_volume_label() {
  docker_on "$1" volume inspect --format "{{ index .Labels \"$LABEL_KEY\" }}" "$2" 2>/dev/null || true
}

owned_network_label() {
  docker_on "$1" network inspect --format "{{ index .Labels \"$LABEL_KEY\" }}" "$2" 2>/dev/null || true
}

remove_owned_resources_on_socket() {
  local socket="$1" name volume label
  socket_ready "$socket" || return 0
  for name in "$RUNNING_NAME" "$STOPPED_NAME"; do
    label="$(owned_container_label "$socket" "$name")"
    if [ "$label" = "$RUN_ID" ]; then
      docker_on "$socket" rm -f "$name" >/dev/null 2>&1 || true
    elif [ -n "$label" ]; then
      echo "cleanup refused non-owned container $name (label=$label)" >&2
    fi
  done
  for volume in "$RUNNING_VOLUME" "$STOPPED_VOLUME"; do
    label="$(owned_volume_label "$socket" "$volume")"
    if [ "$label" = "$RUN_ID" ]; then
      docker_on "$socket" volume rm "$volume" >/dev/null 2>&1 || true
    elif [ -n "$label" ]; then
      echo "cleanup refused non-owned volume $volume (label=$label)" >&2
    fi
  done
  label="$(owned_network_label "$socket" "$NETWORK_NAME")"
  if [ "$label" = "$RUN_ID" ]; then
    docker_on "$socket" network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  elif [ -n "$label" ]; then
    echo "cleanup refused non-owned network $NETWORK_NAME (label=$label)" >&2
  fi
}

stop_frontend() {
  local pid="${CURRENT_APP_PID:-}"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    # Give AppDelegate its normal termination callback first so the legacy release can quiesce its
    # Apple-container engine. Signals are only a bounded fallback for a hung UI process.
    /usr/bin/osascript -e 'tell application id "com.pythonxi.Dory" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
    for _ in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  fi
  CURRENT_APP_PID=""
}

stop_current_phase() {
  local socket="${1:-$CURRENT_SOCKET}"
  stop_frontend
  if [ "$PREVIOUS_KIND" = legacy ] && [ "$socket" = "$STATE/engine.sock" ] \
     && [ -n "$CONTAINER_CLI" ] && "$CONTAINER_CLI" inspect dory-engine >/dev/null 2>&1; then
    "$CONTAINER_CLI" stop dory-engine >/dev/null 2>&1 \
      || fail "could not gracefully stop the legacy Apple-container engine"
  fi
  if launchctl print "$SERVICE" >/dev/null 2>&1; then
    launchctl bootout "$SERVICE" >/dev/null 2>&1 \
      || launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 \
      || fail "could not stop the current candidate LaunchAgent"
  fi
  for _ in $(seq 1 120); do
    socket_ready "$socket" || break
    sleep 0.25
  done
  socket_ready "$socket" && fail "engine remained reachable after its app/service stopped"
}

cleanup() {
  local profile index marker socket
  [ "$CLEANING" = 0 ] || return 0
  CLEANING=1
  set +e
  stop_sparkle_feed
  mkdir -p "$LOG_ROOT"
  [ -f "$STATE/doryd.log" ] && cp "$STATE/doryd.log" "$LOG_ROOT/final-doryd.log"
  [ -f "$STATE/hv/dory-hv.log" ] && cp "$STATE/hv/dory-hv.log" "$LOG_ROOT/final-dory-hv.log"
  [ -f "$PLIST" ] && cp "$PLIST" "$LOG_ROOT/final-dev.dory.doryd.plist"

  for socket in "$STATE/dory.sock" "$STATE/engine.sock" "$STATE/hv/engine.sock"; do
    remove_owned_resources_on_socket "$socket"
  done
  stop_frontend
  launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true

  # The gate persists routeDockerCLI=false, so neither app is authorized to install shell tools.
  # Do not invoke `dory uninstall` here: uninstalling an integration this run did not create could
  # delete a pre-existing Compose plugin. Context cleanup below is retained as a fail-safe, but the
  # clean-user preflight proves that a `dory` context did not predate this run.
  if [ -x "$CANDIDATE_APP/Contents/Helpers/docker" ]; then
    "$CANDIDATE_APP/Contents/Helpers/docker" context use "$PREVIOUS_CONTEXT" >/dev/null 2>&1 || true
    "$CANDIDATE_APP/Contents/Helpers/docker" context rm -f dory >/dev/null 2>&1 || true
  fi
  if [ "$LEGACY_OUTER_OWNED" = 1 ] && [ -n "$CONTAINER_CLI" ] && [ -x "$CONTAINER_CLI" ]; then
    for _ in $(seq 1 20); do
      "$CONTAINER_CLI" rm -f dory-engine >/dev/null 2>&1 || true
      "$CONTAINER_CLI" volume rm dory-engine-data >/dev/null 2>&1 || true
      if ! "$CONTAINER_CLI" inspect dory-engine >/dev/null 2>&1 \
         && ! "$CONTAINER_CLI" volume inspect dory-engine-data >/dev/null 2>&1; then
        break
      fi
      sleep 0.5
    done
  fi

  if [ -f "$STATE_OWNER" ]; then
    marker="$(cat "$STATE_OWNER" 2>/dev/null || true)"
    [ "$marker" = "$RUN_ID" ] && rm -rf "$STATE"
  fi
  if [ -f "$SUPPORT_OWNER" ]; then
    marker="$(cat "$SUPPORT_OWNER" 2>/dev/null || true)"
    [ "$marker" = "$RUN_ID" ] && rm -rf "$APP_SUPPORT"
  fi
  rm -f "$PLIST"
  defaults delete "$PREF_DOMAIN" >/dev/null 2>&1 || true
  for index in "${!PROFILE_PATHS[@]}"; do
    profile="${PROFILE_PATHS[$index]}"
    if [ "${PROFILE_EXISTED[$index]:-1}" = 0 ] && [ -f "$profile" ] \
       && ! grep -q '[^[:space:]]' "$profile"; then
      rm -f "$profile"
    fi
  done
  if [ "$DOCKER_CONFIG_EXISTED" = 0 ] && [ -f "$DOCKER_OWNER" ]; then
    marker="$(cat "$DOCKER_OWNER" 2>/dev/null || true)"
    [ "$marker" = "$RUN_ID" ] && rm -rf "$HOME/.docker"
  fi
  rm -rf "$INSTALL_ROOT" "$PREVIOUS_ROOT" "$DOWNLOAD_ROOT"
}

preflight_clean_user() {
  local process profile
  [ "$(uname -s)" = Darwin ] || fail "requires macOS"
  [ "$(uname -m)" = arm64 ] || fail "requires a physical Apple-silicon release user"
  [ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
    || fail "Hypervisor.framework is unavailable; hosted/nested runners do not qualify"
  [ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
    || fail "nested Virtualization.framework host detected; physical hardware is required"
  case "$(sysctl -n hw.model 2>/dev/null || printf unknown)" in
    VirtualMac*) fail "VirtualMac hosts do not qualify as physical release hardware" ;;
  esac
  [ "${DORY_RELEASE_PHYSICAL_ARM64_CONFIRMED:-0}" = 1 ] \
    || fail "physical Apple-silicon host facts were not independently recorded"
  printf '%s\n' "$IMAGE_REF" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
    || fail "DORY_RELEASE_UPGRADE_IMAGE must be a digest-pinned Alpine image"
  [ -n "$CANDIDATE_APP" ] && [ -n "$SPARKLE_UPDATE_ZIP" ] && [ -n "$SPARKLE_APPCAST" ] \
    || fail "usage: release-upgrade-rollback-smoke.sh <notarized candidate Dory.app> <app-update.zip> <appcast.xml>"
  case "$CANDIDATE_APP" in /*) ;; *) CANDIDATE_APP="$ROOT/$CANDIDATE_APP" ;; esac
  CANDIDATE_APP="$(cd "$(dirname "$CANDIDATE_APP")" && pwd)/$(basename "$CANDIDATE_APP")"
  [ -d "$CANDIDATE_APP" ] || fail "candidate app is missing: $CANDIDATE_APP"
  case "$SPARKLE_UPDATE_ZIP" in /*) ;; *) SPARKLE_UPDATE_ZIP="$ROOT/$SPARKLE_UPDATE_ZIP" ;; esac
  case "$SPARKLE_APPCAST" in /*) ;; *) SPARKLE_APPCAST="$ROOT/$SPARKLE_APPCAST" ;; esac
  SPARKLE_UPDATE_ZIP="$(cd "$(dirname "$SPARKLE_UPDATE_ZIP")" && pwd)/$(basename "$SPARKLE_UPDATE_ZIP")"
  SPARKLE_APPCAST="$(cd "$(dirname "$SPARKLE_APPCAST")" && pwd)/$(basename "$SPARKLE_APPCAST")"
  [ -s "$SPARKLE_UPDATE_ZIP" ] || fail "Sparkle update ZIP is missing or empty: $SPARKLE_UPDATE_ZIP"
  [ -s "$SPARKLE_APPCAST" ] || fail "Sparkle appcast is missing or empty: $SPARKLE_APPCAST"

  launchctl print "$SERVICE" >/dev/null 2>&1 \
    && fail "Dory LaunchAgent is already loaded; use the dedicated clean release user"
  [ ! -e "$PLIST" ] || fail "existing Dory LaunchAgent would be touched: $PLIST"
  [ ! -e "$STATE" ] || fail "existing Dory state would be touched: $STATE"
  [ ! -e "$APP_SUPPORT" ] || fail "existing Dory app support would be touched: $APP_SUPPORT"
  defaults export "$PREF_DOMAIN" - >/dev/null 2>&1 \
    && fail "existing Dory preferences would be touched"
  for process in Dory doryd dory-hv dory-vmm dory-vm; do
    pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1 \
      && fail "$process is already running; use the dedicated clean release user"
  done
  for profile in "${PROFILE_PATHS[@]}"; do
    if [ -f "$profile" ]; then PROFILE_EXISTED+=(1); else PROFILE_EXISTED+=(0); fi
    if [ -f "$profile" ] && grep -Fq '# >>> dory cli >>>' "$profile"; then
      fail "existing Dory shell integration would be touched: $profile"
    fi
  done
  if [ -e "$HOME/.docker" ]; then DOCKER_CONFIG_EXISTED=1; else DOCKER_CONFIG_EXISTED=0; fi
  [ ! -e "$HOME/.docker/cli-plugins/docker-compose" ] \
    || fail "existing Docker Compose plugin would be replaced by Dory: $HOME/.docker/cli-plugins/docker-compose"
  [ ! -e "$HOME/.docker/cli-plugins/docker-buildx" ] \
    || fail "existing Docker Buildx plugin would be replaced by Dory: $HOME/.docker/cli-plugins/docker-buildx"
  "$CANDIDATE_APP/Contents/Helpers/docker" context inspect dory >/dev/null 2>&1 \
    && fail "existing Docker context dory would be touched"
  PREVIOUS_CONTEXT="$("$CANDIDATE_APP/Contents/Helpers/docker" context show 2>/dev/null || printf default)"
  [ -n "$PREVIOUS_CONTEXT" ] || PREVIOUS_CONTEXT=default
}

validate_trusted_app() {
  local app="$1" role="$2" details archs assessment assessment_status evidence_role
  [ -x "$app/Contents/MacOS/Dory" ] || fail "$role app executable is missing"
  codesign --verify --strict --deep "$app" || fail "$role app signature is invalid"
  xcrun stapler validate "$app" || fail "$role app has no valid notarization ticket"
  assessment_status="$(spctl --status 2>&1 || true)"
  grep -q '^assessments enabled' <<< "$assessment_status" \
    || fail "Gatekeeper assessments are disabled; $role trust cannot be proven on this release host"
  assessment="$(spctl --assess --type execute --verbose=4 "$app" 2>&1)" \
    || fail "$role app is rejected by Gatekeeper: $assessment"
  grep -q '^source=Notarized Developer ID$' <<< "$assessment" \
    || fail "$role Gatekeeper assessment is not a notarized Developer ID acceptance: $assessment"
  evidence_role="$(printf '%s' "$role" | tr -cd '[:alnum:]_.-')"
  mkdir -p "$LOG_ROOT"
  printf '%s\n%s\n' "$assessment_status" "$assessment" \
    > "$LOG_ROOT/$evidence_role-gatekeeper.txt"
  details="$(codesign -dv --verbose=4 "$app" 2>&1)"
  grep -q '^Identifier=com.pythonxi.Dory$' <<< "$details" \
    || fail "$role app has the wrong bundle identifier"
  grep -q "^TeamIdentifier=$TEAM_ID$" <<< "$details" \
    || fail "$role app has the wrong Developer ID team"
  grep -q '^Authority=Developer ID Application:' <<< "$details" \
    || fail "$role app is not Developer ID signed"
  archs="$(lipo -archs "$app/Contents/MacOS/Dory")"
  case " $archs " in *' arm64 '*) ;; *) fail "$role app has no arm64 slice" ;; esac
}

select_previous_release_asset() {
  local json="$1" candidate_version="$2" output="$3"
  python3 - "$json" "$candidate_version" "$output" <<'PY'
import json
import re
import sys

source, candidate, output = sys.argv[1:4]
with open(source, encoding="utf-8") as handle:
    releases = json.load(handle)

def version_key(value):
    match = re.fullmatch(r"([0-9]+)\.([0-9]+)\.([0-9]+)(?:[-+][0-9A-Za-z.-]+)?", value)
    if match is None:
        return None
    return tuple(int(part) for part in match.groups())

candidate_key = version_key(candidate)
if candidate_key is None:
    raise SystemExit("candidate version is not semantic x.y.z")

def priority(name, version):
    lower = name.lower()
    if not lower.endswith(".zip") or "lite" in lower:
        return None
    if "app-update" in lower:
        return 0
    if "universal" in lower:
        return 1
    if "selfcontained" in lower or "self-contained" in lower:
        return 2
    if name == f"Dory-{version}.zip":
        return 3
    return None

eligible = []
newer = []
for release in releases:
    if release.get("draft") or release.get("prerelease"):
        continue
    tag = release.get("tag_name", "")
    version = tag[1:] if tag.startswith("v") else tag
    release_key = version_key(version)
    if release_key is None:
        continue
    if release_key > candidate_key:
        newer.append(version)
        continue
    if release_key == candidate_key:
        continue
    candidates = []
    for asset in release.get("assets", []):
        rank = priority(asset.get("name", ""), version)
        digest = asset.get("digest", "")
        url = asset.get("browser_download_url", "")
        if rank is None or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            continue
        expected_prefix = f"https://github.com/Augani/dory/releases/download/{tag}/"
        if not url.startswith(expected_prefix) or asset.get("size", 0) <= 0:
            continue
        candidates.append((rank, asset["name"], url, digest.split(":", 1)[1], str(asset["size"])))
    if candidates:
        candidates.sort()
        rank, name, url, digest, size = candidates[0]
        eligible.append((release_key, (tag, version, name, url, digest, size)))

if newer:
    raise SystemExit(f"candidate {candidate} is older than public release(s): {', '.join(sorted(newer))}")
if not eligible:
    raise SystemExit("no older public full-app ZIP has a GitHub sha256 digest")
selection = max(eligible, key=lambda item: item[0])[1]
with open(output, "w", encoding="utf-8") as handle:
    handle.write("\t".join(selection) + "\n")
PY
}

acquire_previous_public_app() {
  local releases selection tag asset url digest size actual apps app_count
  mkdir -p "$DOWNLOAD_ROOT" "$PREVIOUS_ROOT" "$LOG_ROOT"
  releases="$DOWNLOAD_ROOT/releases.json"
  selection="$DOWNLOAD_ROOT/selection.tsv"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    'https://api.github.com/repos/Augani/dory/releases?per_page=20' \
    -o "$releases"
  select_previous_release_asset "$releases" "$CANDIDATE_VERSION" "$selection"
  IFS=$'\t' read -r tag PREVIOUS_VERSION asset url digest size < "$selection"
  case "$url" in https://github.com/Augani/dory/releases/download/*) ;; *) fail "unsafe previous-release URL" ;; esac
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
    "$url" -o "$DOWNLOAD_ROOT/$asset"
  [ "$(wc -c < "$DOWNLOAD_ROOT/$asset" | tr -d '[:space:]')" = "$size" ] \
    || fail "previous public asset size does not match GitHub metadata"
  actual="$(sha256_file "$DOWNLOAD_ROOT/$asset")"
  [ "$actual" = "$digest" ] || fail "previous public asset sha256 does not match GitHub metadata"
  python3 - "$DOWNLOAD_ROOT/$asset" <<'PY'
import pathlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    for name in archive.namelist():
        path = pathlib.PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe ZIP member: {name}")
PY
  ditto -x -k "$DOWNLOAD_ROOT/$asset" "$PREVIOUS_ROOT/extracted"
  apps="$(find "$PREVIOUS_ROOT/extracted" -maxdepth 3 -type d -name Dory.app -print)"
  app_count="$(printf '%s\n' "$apps" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$app_count" -eq 1 ] || fail "previous public ZIP must contain exactly one Dory.app"
  PREVIOUS_APP="$(printf '%s\n' "$apps" | awk 'NF { print; exit }')"
  PREVIOUS_BUILD="$(plist_value "$PREVIOUS_APP" CFBundleVersion)"
  [ "$(plist_value "$PREVIOUS_APP" CFBundleShortVersionString)" = "$PREVIOUS_VERSION" ] \
    || fail "previous app version does not match its public release tag"
  printf 'tag=%s\nasset=%s\nurl=%s\nsha256=%s\nbytes=%s\n' \
    "$tag" "$asset" "$url" "$digest" "$size" > "$LOG_ROOT/previous-release.txt"
}

preflight_apps() {
  local name candidate_public_key previous_public_key
  validate_trusted_app "$CANDIDATE_APP" candidate
  CANDIDATE_VERSION="$(plist_value "$CANDIDATE_APP" CFBundleShortVersionString)"
  CANDIDATE_BUILD="$(plist_value "$CANDIDATE_APP" CFBundleVersion)"
  [ -n "${DORY_SPARKLE_PRIVATE_KEY:-}" ] \
    || fail "DORY_SPARKLE_PRIVATE_KEY is required to bind the install test to Dory's update key"
  DORY_SPARKLE_PRIVATE_KEY="$DORY_SPARKLE_PRIVATE_KEY" \
    scripts/verify-sparkle-update.sh \
      "$CANDIDATE_APP" "$SPARKLE_UPDATE_ZIP" "$SPARKLE_APPCAST" \
      > "$LOG_ROOT/sparkle-signature-verification.txt"
  for name in dory doryd dory-hv docker dory-doctor; do
    [ -x "$CANDIDATE_APP/Contents/Helpers/$name" ] \
      || fail "candidate app is missing required helper $name"
  done
  acquire_previous_public_app
  validate_trusted_app "$PREVIOUS_APP" previous
  candidate_public_key="$(plist_value "$CANDIDATE_APP" SUPublicEDKey)"
  previous_public_key="$(plist_value "$PREVIOUS_APP" SUPublicEDKey)"
  [ -n "$candidate_public_key" ] && [ "$previous_public_key" = "$candidate_public_key" ] \
    || fail "previous and candidate apps do not trust the same Sparkle Ed25519 key"
  case "$CANDIDATE_BUILD:$PREVIOUS_BUILD" in
    *[!0-9:]*|:*|*:) fail "candidate and previous build numbers must be numeric" ;;
  esac
  [ "$CANDIDATE_BUILD" -gt "$PREVIOUS_BUILD" ] \
    || fail "candidate build $CANDIDATE_BUILD is not newer than previous build $PREVIOUS_BUILD"
  if [ -x "$PREVIOUS_APP/Contents/Helpers/doryd" ]; then
    PREVIOUS_KIND=modern
  elif [ -x "$PREVIOUS_APP/Contents/Helpers/dory-vm" ]; then
    PREVIOUS_KIND=legacy
  else
    fail "previous public app has no built-in engine helper"
  fi
}

find_container_cli() {
  local candidate
  for candidate in /opt/homebrew/bin/container /usr/local/bin/container "$(command -v container 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

preflight_previous_engine_state() {
  [ "$PREVIOUS_KIND" = legacy ] || return 0
  CONTAINER_CLI="$(find_container_cli)" \
    || fail "the previous public legacy build needs Apple's container CLI on the dedicated release host"
  "$CONTAINER_CLI" system status >/dev/null 2>&1 \
    || fail "Apple container system must already be provisioned and running; the gate will not install a kernel or change system state"
  "$CONTAINER_CLI" inspect dory-engine >/dev/null 2>&1 \
    && fail "pre-existing legacy Dory engine would be touched"
  "$CONTAINER_CLI" volume inspect dory-engine-data >/dev/null 2>&1 \
    && fail "pre-existing legacy Dory engine volume would be touched"
  LEGACY_OUTER_OWNED=1
}

install_exact_app() {
  local source="$1" next="$INSTALL_ROOT/Dory.app.next" old="$INSTALL_ROOT/Dory.app.old"
  mkdir -p "$INSTALL_ROOT"
  rm -rf "$next" "$old"
  ditto "$source" "$next"
  xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");DoryReleaseGate;" "$next"
  xattr -p com.apple.quarantine "$next" >/dev/null \
    || fail "installed copy did not retain the simulated download quarantine"
  validate_trusted_app "$next" installed-copy
  [ "$(app_cdhash "$next")" = "$(app_cdhash "$source")" ] \
    || fail "installed copy is not the exact signed source app"
  if [ -e "$INSTALLED_APP" ]; then mv "$INSTALLED_APP" "$old"; fi
  mv "$next" "$INSTALLED_APP"
  rm -rf "$old"
}

configure_persisted_settings() {
  defaults write "$PREF_DOMAIN" dory.hasCompletedOnboarding -bool true
  defaults write "$PREF_DOMAIN" dory.keepDorydRunningAfterQuit -bool false
  defaults write "$PREF_DOMAIN" dory.enginePreference -string dory
  defaults write "$PREF_DOMAIN" dory.appearance -string dark
  defaults write "$PREF_DOMAIN" dory.autoUpdate -bool false
  defaults write "$PREF_DOMAIN" dory.domainSuffix -string upgrade-gate.dory.local
  defaults write "$PREF_DOMAIN" dory.experimentalGPU -bool false
  defaults write "$PREF_DOMAIN" dory.rosettaX86Enabled -bool true
  defaults write "$PREF_DOMAIN" dory.routeDockerCLI -bool false
  defaults write "$PREF_DOMAIN" dory.releaseUpgradeGateSentinel -string "$RUN_ID"
}

assert_persisted_settings() {
  local stage="$1"
  [ "$(defaults read "$PREF_DOMAIN" dory.releaseUpgradeGateSentinel)" = "$RUN_ID" ] \
    || fail "$stage lost the upgrade-gate preference sentinel"
  [ "$(defaults read "$PREF_DOMAIN" dory.appearance)" = dark ] \
    || fail "$stage changed the persisted appearance setting"
  [ "$(defaults read "$PREF_DOMAIN" dory.domainSuffix)" = upgrade-gate.dory.local ] \
    || fail "$stage changed the persisted domain suffix"
  [ "$(defaults read "$PREF_DOMAIN" dory.autoUpdate)" = 0 ] \
    || fail "$stage changed the persisted update preference"
  [ "$(defaults read "$PREF_DOMAIN" dory.hasCompletedOnboarding)" = 1 ] \
    || fail "$stage changed the persisted onboarding setting"
  [ "$(defaults read "$PREF_DOMAIN" dory.keepDorydRunningAfterQuit)" = 0 ] \
    || fail "$stage changed the persisted keep-running setting"
  [ "$(defaults read "$PREF_DOMAIN" dory.enginePreference)" = dory ] \
    || fail "$stage changed the persisted engine preference"
  [ "$(defaults read "$PREF_DOMAIN" dory.experimentalGPU)" = 0 ] \
    || fail "$stage changed the persisted GPU setting"
  [ "$(defaults read "$PREF_DOMAIN" dory.rosettaX86Enabled)" = 1 ] \
    || fail "$stage changed the persisted amd64/Rosetta setting"
  [ "$(defaults read "$PREF_DOMAIN" dory.routeDockerCLI)" = 0 ] \
    || fail "$stage changed the persisted host-CLI routing setting"
}

mark_owned_paths() {
  mkdir -p "$STATE"
  printf '%s\n' "$RUN_ID" > "$STATE_OWNER"
  if [ -d "$APP_SUPPORT" ]; then
    printf '%s\n' "$RUN_ID" > "$SUPPORT_OWNER"
  fi
  if [ "$DOCKER_CONFIG_EXISTED" = 0 ] && [ -d "$HOME/.docker" ]; then
    printf '%s\n' "$RUN_ID" > "$DOCKER_OWNER"
  fi
}

launch_installed_app() {
  local stage="$1" preferred_socket="$2" alternate_socket="${3:-}" ready=0 socket=""
  mkdir -p "$LOG_ROOT"
  "$INSTALLED_APP/Contents/MacOS/Dory" \
    >"$LOG_ROOT/$stage-app.stdout.log" 2>"$LOG_ROOT/$stage-app.stderr.log" &
  CURRENT_APP_PID=$!
  for _ in $(seq 1 720); do
    kill -0 "$CURRENT_APP_PID" 2>/dev/null || {
      tail -100 "$LOG_ROOT/$stage-app.stderr.log" >&2 || true
      fail "$stage app exited before its engine became ready"
    }
    if socket_ready "$preferred_socket"; then
      socket="$preferred_socket"; ready=1; break
    fi
    if [ -n "$alternate_socket" ] && socket_ready "$alternate_socket"; then
      socket="$alternate_socket"; ready=1; break
    fi
    sleep 0.5
  done
  [ "$ready" = 1 ] || fail "$stage app did not expose a Docker-compatible engine within 360 seconds"
  CURRENT_SOCKET="$socket"
  mark_owned_paths
  printf '%s\n' "$socket" > "$LOG_ROOT/$stage-socket.txt"
}

seed_persistent_state() {
  local socket="$1"
  docker_on "$socket" pull "$IMAGE_REF" >/dev/null
  IMAGE_ID="$(docker_on "$socket" image inspect --format '{{.Id}}' "$IMAGE_REF")"
  [ -n "$IMAGE_ID" ] || fail "could not record the upgrade fixture image ID"
  NETWORK_ID="$(docker_on "$socket" network create --label "$LABEL_KEY=$RUN_ID" "$NETWORK_NAME")"
  [ -n "$NETWORK_ID" ] || fail "could not create the upgrade fixture network"
  docker_on "$socket" volume create --label "$LABEL_KEY=$RUN_ID" "$STOPPED_VOLUME" >/dev/null
  docker_on "$socket" volume create --label "$LABEL_KEY=$RUN_ID" "$RUNNING_VOLUME" >/dev/null
  STOPPED_ID="$(docker_on "$socket" create --name "$STOPPED_NAME" \
    --label "$LABEL_KEY=$RUN_ID" --network "$NETWORK_NAME" -v "$STOPPED_VOLUME:/state" "$IMAGE_REF" \
    sh -c "printf '%s' '$RUN_ID-stopped-volume' >/state/value; printf '%s' '$RUN_ID-stopped-container' >/container-value")"
  [ -n "$STOPPED_ID" ] || fail "could not create stopped upgrade fixture"
  docker_on "$socket" start -a "$STOPPED_NAME" >/dev/null
  RUNNING_ID="$(docker_on "$socket" run -d --name "$RUNNING_NAME" --restart always \
    --label "$LABEL_KEY=$RUN_ID" --network "$NETWORK_NAME" -v "$RUNNING_VOLUME:/state" "$IMAGE_REF" \
    sh -c "printf '%s' '$RUN_ID-running-volume' >/state/value; printf '%s' '$RUN_ID-running-container' >/container-value; while :; do sleep 60; done")"
  [ -n "$RUNNING_ID" ] || fail "could not create running upgrade fixture"
  printf 'image_id=%s\nnetwork_id=%s\nstopped_id=%s\nrunning_id=%s\nstopped_volume=%s\nrunning_volume=%s\n' \
    "$IMAGE_ID" "$NETWORK_ID" "$STOPPED_ID" "$RUNNING_ID" "$STOPPED_VOLUME" "$RUNNING_VOLUME" \
    > "$LOG_ROOT/seeded-state.txt"
}

assert_persisted_resources() {
  local stage="$1" socket="$2" running_expected="$3" stopped running label value layer_copy
  socket_ready "$socket" || fail "$stage Docker API is not healthy"
  [ "$(docker_on "$socket" image inspect --format '{{.Id}}' "$IMAGE_REF")" = "$IMAGE_ID" ] \
    || fail "$stage changed or lost the pulled image ID"
  [ "$(docker_on "$socket" network inspect --format '{{.Id}}' "$NETWORK_NAME")" = "$NETWORK_ID" ] \
    || fail "$stage changed or lost the custom network ID"
  [ "$(owned_network_label "$socket" "$NETWORK_NAME")" = "$RUN_ID" ] \
    || fail "$stage lost the custom network ownership label"
  stopped="$(docker_on "$socket" inspect --format '{{.Id}}' "$STOPPED_NAME")"
  running="$(docker_on "$socket" inspect --format '{{.Id}}' "$RUNNING_NAME")"
  [ "$stopped" = "$STOPPED_ID" ] || fail "$stage changed the stopped container ID"
  [ "$running" = "$RUNNING_ID" ] || fail "$stage changed the running container ID"
  [ "$(owned_container_label "$socket" "$STOPPED_NAME")" = "$RUN_ID" ] \
    || fail "$stage lost the stopped container ownership label"
  [ "$(owned_container_label "$socket" "$RUNNING_NAME")" = "$RUN_ID" ] \
    || fail "$stage lost the running container ownership label"
  [ "$(owned_volume_label "$socket" "$STOPPED_VOLUME")" = "$RUN_ID" ] \
    || fail "$stage lost the stopped volume ownership label"
  [ "$(owned_volume_label "$socket" "$RUNNING_VOLUME")" = "$RUN_ID" ] \
    || fail "$stage lost the running volume ownership label"
  [ "$(docker_on "$socket" inspect --format '{{.State.Running}}' "$STOPPED_NAME")" = false ] \
    || fail "$stage unexpectedly started the stopped container"
  for _ in $(seq 1 120); do
    [ "$(docker_on "$socket" inspect --format '{{.State.Running}}' "$RUNNING_NAME" 2>/dev/null || true)" = "$running_expected" ] \
      && break
    sleep 0.5
  done
  [ "$(docker_on "$socket" inspect --format '{{.State.Running}}' "$RUNNING_NAME")" = "$running_expected" ] \
    || fail "$stage running-container state is not $running_expected"
  value="$(docker_on "$socket" run --rm --label "$LABEL_KEY=$RUN_ID" \
    -v "$STOPPED_VOLUME:/state:ro" "$IMAGE_REF" cat /state/value)"
  [ "$value" = "$RUN_ID-stopped-volume" ] || fail "$stage lost stopped-volume data"
  value="$(docker_on "$socket" run --rm --label "$LABEL_KEY=$RUN_ID" \
    -v "$RUNNING_VOLUME:/state:ro" "$IMAGE_REF" cat /state/value)"
  [ "$value" = "$RUN_ID-running-volume" ] || fail "$stage lost running-volume data"
  layer_copy="$TEST_ROOT/$stage-stopped-container-value"
  rm -f "$layer_copy"
  docker_on "$socket" cp "$STOPPED_NAME:/container-value" "$layer_copy"
  [ "$(cat "$layer_copy")" = "$RUN_ID-stopped-container" ] \
    || fail "$stage lost stopped-container writable-layer data"
  rm -f "$layer_copy"
  layer_copy="$TEST_ROOT/$stage-running-container-value"
  rm -f "$layer_copy"
  docker_on "$socket" cp "$RUNNING_NAME:/container-value" "$layer_copy"
  [ "$(cat "$layer_copy")" = "$RUN_ID-running-container" ] \
    || fail "$stage lost running-container writable-layer data"
  rm -f "$layer_copy"
  assert_persisted_settings "$stage"
}

assert_exact_candidate_running() {
  local name launch_state
  [ "$(plist_value "$INSTALLED_APP" CFBundleVersion)" = "$CANDIDATE_BUILD" ] \
    || fail "installed candidate build does not match the exact release candidate"
  for name in Dory; do
    [ "$(sha256_file "$INSTALLED_APP/Contents/MacOS/$name")" = \
      "$(sha256_file "$CANDIDATE_APP/Contents/MacOS/$name")" ] \
      || fail "installed candidate executable differs from the release candidate"
  done
  for name in doryd dory-hv docker dory-doctor; do
    [ "$(sha256_file "$INSTALLED_APP/Contents/Helpers/$name")" = \
      "$(sha256_file "$CANDIDATE_APP/Contents/Helpers/$name")" ] \
      || fail "installed candidate helper differs: $name"
  done
  launch_state="$(launchctl print "$SERVICE")" || fail "candidate did not load its LaunchAgent"
  grep -Fq "program = $INSTALLED_APP/Contents/Helpers/doryd" <<< "$launch_state" \
    || fail "candidate daemon does not run from the exact installed candidate copy"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:DORYD_DOMAIN_SUFFIX' "$PLIST")" = \
    upgrade-gate.dory.local ] || fail "candidate daemon did not apply the preserved domain setting"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:DORYD_HOST_CLI' "$PLIST")" = 0 ] \
    || fail "candidate daemon did not preserve disabled host-CLI routing"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:DORYD_GPU' "$PLIST")" = off ] \
    || fail "candidate daemon did not preserve disabled GPU mode"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:DORYD_AMD64' "$PLIST")" = 1 ] \
    || fail "candidate daemon did not preserve amd64/Rosetta mode"
  grep -Eq 'DORYD_HOST_CLI[^[:alnum:]_]+0([^[:alnum:]_]|$)' <<< "$launch_state" \
    || fail "loaded candidate daemon did not apply disabled host-CLI routing"
  grep -Eq 'DORYD_GPU[^[:alnum:]_]+off([^[:alnum:]_]|$)' <<< "$launch_state" \
    || fail "loaded candidate daemon did not apply disabled GPU mode"
  grep -Eq 'DORYD_AMD64[^[:alnum:]_]+1([^[:alnum:]_]|$)' <<< "$launch_state" \
    || fail "loaded candidate daemon did not apply amd64/Rosetta mode"
  printf '%s\n' "$launch_state" > "$LOG_ROOT/candidate-launchctl.txt"
}

exercise_exact_candidate() {
  local socket="$1"
  docker_on "$socket" stop "$RUNNING_NAME" >/dev/null
  assert_persisted_resources candidate-stopped "$socket" false
  DORY_APP="$INSTALLED_APP" \
  DORY_CLI_BIN="$INSTALLED_APP/Contents/Helpers/dory" \
  DORY_DOCTOR_BIN="$INSTALLED_APP/Contents/Helpers/dory-doctor" \
  DORY_DOCKER_BIN="$INSTALLED_APP/Contents/Helpers/docker" \
  DORY_SOCK="$socket" \
  DORY_ENGINE_SOCK="$STATE/hv/engine.sock" \
  DORY_P0_STOP_WAKE=1 \
    scripts/p0-smoke.sh
  assert_persisted_resources candidate-after-p0 "$socket" false
  docker_on "$socket" start "$RUNNING_NAME" >/dev/null
  assert_persisted_resources candidate-restored-running "$socket" true
}

assert_exact_previous_installed() {
  [ "$(plist_value "$INSTALLED_APP" CFBundleVersion)" = "$PREVIOUS_BUILD" ] \
    || fail "rollback did not restore the previous public build"
  [ "$(app_cdhash "$INSTALLED_APP")" = "$(app_cdhash "$PREVIOUS_APP")" ] \
    || fail "rollback app is not the exact signed previous public app"
}

build_pinned_sparkle_cli() {
  local resolved="$ROOT/Dory.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  local expected checkout project derived product actual_version actual_revision
  expected="$(python3 - "$resolved" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    pins = json.load(handle)["pins"]
pin = next((value for value in pins if value["identity"] == "sparkle"), None)
if pin is None:
    raise SystemExit("Sparkle is not pinned in Package.resolved")
print(f'{pin["state"]["revision"]}\t{pin["state"]["version"]}')
PY
)"
  IFS=$'\t' read -r actual_revision actual_version <<< "$expected"
  [ -n "$actual_revision" ] && [ -n "$actual_version" ] \
    || fail "could not read the pinned Sparkle revision/version"

  checkout="${DORY_SPARKLE_SOURCE_CHECKOUT:-}"
  if [ -z "$checkout" ]; then
    while IFS= read -r project; do
      checkout="$(dirname "$project")"
      [ "$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)" = "$actual_revision" ] \
        && break
      checkout=""
    done < <(find "$HOME/Library/Developer/Xcode/DerivedData" \
      -path '*/SourcePackages/checkouts/Sparkle/Sparkle.xcodeproj' -print 2>/dev/null | sort)
  fi
  [ -n "$checkout" ] && [ -d "$checkout/Sparkle.xcodeproj" ] \
    || fail "the Package.resolved-pinned Sparkle source checkout is unavailable"
  [ "$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)" = "$actual_revision" ] \
    || fail "Sparkle source checkout does not match Package.resolved revision $actual_revision"
  [ "$(git -C "$checkout" describe --tags --exact-match HEAD 2>/dev/null || true)" = "$actual_version" ] \
    || fail "Sparkle source checkout is not exact tag $actual_version"
  [ -z "$(git -C "$checkout" status --porcelain)" ] \
    || fail "Sparkle source checkout has local changes"

  derived="$TEST_ROOT/sparkle-cli-derived"
  rm -rf "$derived"
  if ! xcodebuild -project "$checkout/Sparkle.xcodeproj" -scheme sparkle-cli \
      -configuration Release -derivedDataPath "$derived" build \
      > "$LOG_ROOT/sparkle-cli-build.log" 2>&1; then
    tail -100 "$LOG_ROOT/sparkle-cli-build.log" >&2 || true
    fail "could not build the Package.resolved-pinned Sparkle CLI"
  fi
  product="$derived/Build/Products/Release/sparkle.app"
  SPARKLE_CLI="$product/Contents/MacOS/sparkle"
  [ -x "$SPARKLE_CLI" ] || fail "Sparkle CLI build produced no executable"
  codesign --verify --strict --deep "$product" || fail "built Sparkle CLI signature is invalid"
  [ "$(plist_value "$product" CFBundleShortVersionString)" = "$actual_version" ] \
    || fail "built Sparkle CLI version differs from Package.resolved"
  printf 'version=%s\nrevision=%s\nsource=%s\nsha256=%s\n' \
    "$actual_version" "$actual_revision" "$checkout" "$(sha256_file "$SPARKLE_CLI")" \
    > "$LOG_ROOT/sparkle-cli.txt"
}

start_local_sparkle_feed() {
  local serve_root="$TEST_ROOT/sparkle-feed" port_file="$TEST_ROOT/sparkle-feed.port"
  local archive_name port
  archive_name="$(basename "$SPARKLE_UPDATE_ZIP")"
  rm -rf "$serve_root" "$port_file"
  mkdir -p "$serve_root"
  cp "$SPARKLE_UPDATE_ZIP" "$serve_root/$archive_name"
  [ "$(sha256_file "$serve_root/$archive_name")" = "$(sha256_file "$SPARKLE_UPDATE_ZIP")" ] \
    || fail "served Sparkle archive is not byte-identical to the release artifact"

  python3 -u - "$serve_root" "$port_file" \
    > "$LOG_ROOT/sparkle-feed-server.log" 2>&1 <<'PY' &
import functools
import http.server
import os
import sys

root, port_file = sys.argv[1:3]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
fd = os.open(port_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_port))
server.serve_forever()
PY
  SPARKLE_FEED_PID=$!
  for _ in $(seq 1 100); do
    [ -s "$port_file" ] && break
    kill -0 "$SPARKLE_FEED_PID" 2>/dev/null \
      || fail "local Sparkle feed server exited before publishing its port"
    sleep 0.1
  done
  [ -s "$port_file" ] || fail "local Sparkle feed server did not become ready"
  port="$(cat "$port_file")"
  case "$port" in *[!0-9]*|'') fail "local Sparkle feed selected an invalid port" ;; esac
  SPARKLE_FEED_URL="http://127.0.0.1:$port/appcast.xml"

  python3 - "$SPARKLE_APPCAST" "$serve_root/appcast.xml" \
    "http://127.0.0.1:$port/$archive_name" "$CANDIDATE_VERSION" "$CANDIDATE_BUILD" <<'PY'
import sys
import xml.etree.ElementTree as ET

source, destination, archive_url, version, build = sys.argv[1:6]
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", namespace)
tree = ET.parse(source)
matches = []
for enclosure in tree.findall(".//enclosure"):
    short_version = enclosure.attrib.get(f"{{{namespace}}}shortVersionString")
    build_version = enclosure.attrib.get(f"{{{namespace}}}version")
    if short_version == version and build_version == build:
        matches.append(enclosure)
if len(matches) != 1:
    raise SystemExit(f"expected one Sparkle enclosure for {version}/{build}, found {len(matches)}")
matches[0].set("url", archive_url)
tree.write(destination, encoding="utf-8", xml_declaration=True)
PY
  curl -fsS --max-time 5 "$SPARKLE_FEED_URL" >/dev/null \
    || fail "rewritten local Sparkle appcast is not reachable"
  curl -fsS --max-time 5 "http://127.0.0.1:$port/$archive_name" \
    -o "$TEST_ROOT/sparkle-feed-probe.zip" \
    || fail "exact local Sparkle update archive is not reachable"
  [ "$(sha256_file "$TEST_ROOT/sparkle-feed-probe.zip")" = "$(sha256_file "$SPARKLE_UPDATE_ZIP")" ] \
    || fail "local Sparkle download changed the update archive"
  printf 'feed=%s\narchive_sha256=%s\n' \
    "$SPARKLE_FEED_URL" "$(sha256_file "$SPARKLE_UPDATE_ZIP")" \
    > "$LOG_ROOT/sparkle-feed.txt"
}

adopt_sparkle_relaunch() {
  local old_pid="$1" pid="" command="" ready=0
  CURRENT_APP_PID=""
  for _ in $(seq 1 720); do
    pid="$(pgrep -u "$(id -u)" -x Dory 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ] && [ "$pid" != "$old_pid" ]; then
      command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      if [ "$command" = "$INSTALLED_APP/Contents/MacOS/Dory" ] \
         && [ "$(plist_value "$INSTALLED_APP" CFBundleVersion 2>/dev/null || true)" = "$CANDIDATE_BUILD" ] \
         && socket_ready "$STATE/dory.sock"; then
        ready=1
        break
      fi
    fi
    sleep 0.5
  done
  [ "$ready" = 1 ] || fail "Sparkle did not relaunch the exact candidate with a healthy engine"
  CURRENT_APP_PID="$pid"
  CURRENT_SOCKET="$STATE/dory.sock"
  mark_owned_paths
  printf 'old_pid=%s\nnew_pid=%s\ncommand=%s\n' "$old_pid" "$pid" "$command" \
    > "$LOG_ROOT/sparkle-relaunch.txt"
}

transition_to_candidate_via_sparkle() {
  local old_pid="$CURRENT_APP_PID" installed_digest candidate_digest
  [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null \
    || fail "previous app is not running before the Sparkle update"
  build_pinned_sparkle_cli
  start_local_sparkle_feed
  "$SPARKLE_CLI" \
    --application "$INSTALLED_APP" \
    --feed-url "$SPARKLE_FEED_URL" \
    --check-immediately \
    --allow-major-upgrades \
    --user-agent-name DoryReleaseGate \
    --verbose \
    "$INSTALLED_APP" \
    > "$LOG_ROOT/sparkle-install.stdout.log" \
    2> "$LOG_ROOT/sparkle-install.stderr.log" \
    || fail "Sparkle failed to install the exact update archive"
  stop_sparkle_feed
  for _ in $(seq 1 80); do
    kill -0 "$old_pid" 2>/dev/null || break
    sleep 0.25
  done
  kill -0 "$old_pid" 2>/dev/null \
    && fail "Sparkle reported success without terminating the previous app"
  wait "$old_pid" 2>/dev/null || true
  adopt_sparkle_relaunch "$old_pid"
  validate_trusted_app "$INSTALLED_APP" sparkle-installed
  candidate_digest="$(app_tree_digest "$CANDIDATE_APP")"
  installed_digest="$(app_tree_digest "$INSTALLED_APP")"
  [ "$installed_digest" = "$candidate_digest" ] \
    || fail "Sparkle-installed app tree differs from the exact candidate archive"
  printf 'candidate_tree_sha256=%s\ninstalled_tree_sha256=%s\n' \
    "$candidate_digest" "$installed_digest" > "$LOG_ROOT/sparkle-installed-tree.txt"
  assert_exact_candidate_running
}

transition_to_candidate() {
  transition_to_candidate_via_sparkle
}

transition_to_previous() {
  stop_current_phase "$CURRENT_SOCKET"
  rm -f "$PLIST"
  install_exact_app "$PREVIOUS_APP"
  if [ "$PREVIOUS_KIND" = modern ]; then
    launch_installed_app rollback "$STATE/dory.sock" "$STATE/engine.sock"
  else
    launch_installed_app rollback "$STATE/engine.sock" "$STATE/dory.sock"
  fi
  assert_exact_previous_installed
}

run_upgrade_rollback_gate() {
  preflight_clean_user
  initialize_test_root
  mkdir -p "$TEST_ROOT" "$LOG_ROOT"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  preflight_apps
  preflight_previous_engine_state
  configure_persisted_settings
  install_exact_app "$PREVIOUS_APP"
  if [ "$PREVIOUS_KIND" = modern ]; then
    launch_installed_app previous "$STATE/dory.sock" "$STATE/engine.sock"
  else
    launch_installed_app previous "$STATE/engine.sock" "$STATE/dory.sock"
  fi
  seed_persistent_state "$CURRENT_SOCKET"
  assert_persisted_resources previous "$CURRENT_SOCKET" true

  transition_to_candidate
  assert_persisted_resources candidate "$CURRENT_SOCKET" true
  exercise_exact_candidate "$CURRENT_SOCKET"

  transition_to_previous
  assert_persisted_resources rollback "$CURRENT_SOCKET" true

  remove_owned_resources_on_socket "$CURRENT_SOCKET"
  echo "release upgrade/rollback smoke: PASS ($PREVIOUS_VERSION/$PREVIOUS_BUILD -> $CANDIDATE_VERSION/$CANDIDATE_BUILD -> $PREVIOUS_VERSION/$PREVIOUS_BUILD)"
}

if [ "${DORY_RELEASE_UPGRADE_SOURCE_ONLY:-0}" != 1 ]; then
  run_upgrade_rollback_gate
fi

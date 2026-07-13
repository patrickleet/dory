#!/bin/bash
# Offline regression tests for the destructive release upgrade/rollback harness.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-upgrade-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

DORY_RELEASE_UPGRADE_SOURCE_ONLY=1
# shellcheck source=release-upgrade-rollback-smoke.sh
source scripts/release-upgrade-rollback-smoke.sh

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [ "$expected" = "$actual" ] || {
    echo "test-release-upgrade-rollback-smoke: $label: expected '$expected', got '$actual'" >&2
    exit 1
  }
}

# Asset selection must skip the candidate itself, reject lite/undigested artifacts, and choose the
# strongest older full-app artifact with an exact GitHub SHA-256 digest.
cat > "$TMP/releases.json" <<'JSON'
[
  {
    "tag_name": "v0.1.0", "draft": false, "prerelease": false,
    "assets": [{
      "name": "Dory-0.1.0-app-update.zip", "size": 10,
      "digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "browser_download_url": "https://github.com/Augani/dory/releases/download/v0.1.0/Dory-0.1.0-app-update.zip"
    }]
  },
  {
    "tag_name": "v0.3.0", "draft": false, "prerelease": false,
    "assets": [{
      "name": "Dory-0.3.0-app-update.zip", "size": 10,
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "browser_download_url": "https://github.com/Augani/dory/releases/download/v0.3.0/Dory-0.3.0-app-update.zip"
    }]
  },
  {
    "tag_name": "v0.2.0", "draft": false, "prerelease": false,
    "assets": [
      {
        "name": "Dory-0.2.0-lite.zip", "size": 10,
        "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "browser_download_url": "https://github.com/Augani/dory/releases/download/v0.2.0/Dory-0.2.0-lite.zip"
      },
      {
        "name": "Dory-0.2.0-universal.zip", "size": 20,
        "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "browser_download_url": "https://github.com/Augani/dory/releases/download/v0.2.0/Dory-0.2.0-universal.zip"
      },
      {
        "name": "Dory-0.2.0-app-update.zip", "size": 30,
        "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "browser_download_url": "https://github.com/Augani/dory/releases/download/v0.2.0/Dory-0.2.0-app-update.zip"
      }
    ]
  }
]
JSON
select_previous_release_asset "$TMP/releases.json" 0.3.0 "$TMP/selection.tsv"
IFS=$'\t' read -r tag version asset url digest size < "$TMP/selection.tsv"
assert_eq v0.2.0 "$tag" "older tag selection"
assert_eq 0.2.0 "$version" "older version selection"
assert_eq Dory-0.2.0-app-update.zip "$asset" "full-app priority"
assert_eq dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd "$digest" "GitHub digest"
assert_eq 30 "$size" "GitHub size"

cat > "$TMP/newer-public-release.json" <<'JSON'
[
  {"tag_name":"v0.4.0","draft":false,"prerelease":false,"assets":[]},
  {"tag_name":"v0.2.0","draft":false,"prerelease":false,"assets":[{
    "name":"Dory-0.2.0-app-update.zip","size":20,
    "digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "browser_download_url":"https://github.com/Augani/dory/releases/download/v0.2.0/Dory-0.2.0-app-update.zip"
  }]}
]
JSON
if select_previous_release_asset "$TMP/newer-public-release.json" 0.3.0 "$TMP/downgrade.tsv" 2>/dev/null; then
  echo "test-release-upgrade-rollback-smoke: accepted a candidate older than a public release" >&2
  exit 1
fi

grep -Fq 'existing Docker Compose plugin would be replaced by Dory' \
  scripts/release-upgrade-rollback-smoke.sh || {
    echo "test-release-upgrade-rollback-smoke: missing non-owned Compose plugin refusal" >&2
    exit 1
  }

cat > "$TMP/no-trusted-release.json" <<'JSON'
[{"tag_name":"v0.2.0","draft":false,"prerelease":false,"assets":[{
  "name":"Dory-0.2.0-lite.zip","size":10,"digest":null,
  "browser_download_url":"https://attacker.invalid/Dory.zip"
}]}]
JSON
if select_previous_release_asset "$TMP/no-trusted-release.json" 0.3.0 "$TMP/rejected.tsv" 2>/dev/null; then
  echo "test-release-upgrade-rollback-smoke: accepted an untrusted previous asset" >&2
  exit 1
fi

# The exact-tree proof must cover every regular file, mode, directory and symlink, and the local
# appcast server must preserve the update ZIP bytes while rewriting only the selected enclosure.
mkdir -p "$TMP/tree-a/Contents/MacOS" "$TMP/tree-b"
printf 'fixture\n' > "$TMP/tree-a/Contents/MacOS/Dory"
chmod 755 "$TMP/tree-a/Contents/MacOS/Dory"
ln -s MacOS "$TMP/tree-a/Contents/Current"
ditto "$TMP/tree-a" "$TMP/tree-b"
assert_eq "$(app_tree_digest "$TMP/tree-a")" "$(app_tree_digest "$TMP/tree-b")" \
  "identical app-tree digest"
chmod 644 "$TMP/tree-b/Contents/MacOS/Dory"
if [ "$(app_tree_digest "$TMP/tree-a")" = "$(app_tree_digest "$TMP/tree-b")" ]; then
  echo "test-release-upgrade-rollback-smoke: app-tree digest ignored executable mode" >&2
  exit 1
fi

TEST_ROOT="$TMP/sparkle-feed-fixture"
LOG_ROOT="$TEST_ROOT/evidence"
SPARKLE_UPDATE_ZIP="$TEST_ROOT/Dory-0.3.0-app-update.zip"
SPARKLE_APPCAST="$TEST_ROOT/source-appcast.xml"
CANDIDATE_VERSION=0.3.0
CANDIDATE_BUILD=42
mkdir -p "$LOG_ROOT"
printf 'exact archive bytes\n' > "$SPARKLE_UPDATE_ZIP"
cat > "$SPARKLE_APPCAST" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><item><enclosure url="https://example.invalid/Dory-0.3.0-app-update.zip"
    sparkle:version="42" sparkle:shortVersionString="0.3.0"
    sparkle:edSignature="fixture" length="20" type="application/octet-stream" /></item></channel>
</rss>
XML
start_local_sparkle_feed
curl -fsS --max-time 5 "$SPARKLE_FEED_URL" > "$TEST_ROOT/fetched-appcast.xml"
python3 - "$TEST_ROOT/fetched-appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
enclosure = ET.parse(sys.argv[1]).find(".//enclosure")
assert enclosure is not None
assert enclosure.attrib["url"].startswith("http://127.0.0.1:")
assert enclosure.attrib["url"].endswith("/Dory-0.3.0-app-update.zip")
assert enclosure.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"] == "fixture"
PY
stop_sparkle_feed

for required in \
  'build_pinned_sparkle_cli' \
  '--check-immediately' \
  '--allow-major-upgrades' \
  'Sparkle-installed app tree differs from the exact candidate archive' \
  'Sparkle reported success without terminating the previous app'; do
  grep -Fq -- "$required" scripts/release-upgrade-rollback-smoke.sh || {
    echo "test-release-upgrade-rollback-smoke: missing true updater proof: $required" >&2
    exit 1
  }
done
grep -Fq 'steps.build.outputs.app_update' .github/workflows/release.yml || {
  echo "test-release-upgrade-rollback-smoke: release workflow does not pass the exact update ZIP" >&2
  exit 1
}
grep -Fq 'release-build/appcast.xml' .github/workflows/release.yml || {
  echo "test-release-upgrade-rollback-smoke: release workflow does not pass the exact appcast" >&2
  exit 1
}

# Exercise the state assertions against a fake Docker API. The check must bind both exact IDs,
# both ownership labels, running/stopped state, both volume labels, and both data sentinels.
RUN_ID=fixture-run
LABEL_KEY=dev.dory.release-upgrade
STOPPED_NAME=dory-upgrade-stopped-fixture
RUNNING_NAME=dory-upgrade-running-fixture
STOPPED_VOLUME=dory-upgrade-stopped-volume-fixture
RUNNING_VOLUME=dory-upgrade-running-volume-fixture
NETWORK_NAME=dory-upgrade-network-fixture
IMAGE_REF=alpine:latest
STOPPED_ID=stopped-id-123
RUNNING_ID=running-id-456
NETWORK_ID=network-id-789
IMAGE_ID=sha256:image-id-abc
FAKE_BAD_RUNNING_ID=0
TEST_ROOT="$TMP/state-assertions"
mkdir -p "$TEST_ROOT"

socket_ready() { return 0; }
assert_persisted_settings() { printf 'settings:%s\n' "$1" >> "$TMP/assertions.log"; }
docker_on() {
  local socket="$1"
  shift
  case "$*" in
    "image inspect --format {{.Id}} $IMAGE_REF") printf '%s\n' "$IMAGE_ID" ;;
    "network inspect --format {{.Id}} $NETWORK_NAME") printf '%s\n' "$NETWORK_ID" ;;
    "network inspect --format {{ index .Labels \"$LABEL_KEY\" }} $NETWORK_NAME") printf '%s\n' "$RUN_ID" ;;
    "inspect --format {{.Id}} $STOPPED_NAME") printf '%s\n' "$STOPPED_ID" ;;
    "inspect --format {{.Id}} $RUNNING_NAME")
      [ "$FAKE_BAD_RUNNING_ID" = 1 ] && printf '%s\n' wrong-id || printf '%s\n' "$RUNNING_ID" ;;
    "inspect --format {{ index .Config.Labels \"$LABEL_KEY\" }} $STOPPED_NAME"|\
    "inspect --format {{ index .Config.Labels \"$LABEL_KEY\" }} $RUNNING_NAME") printf '%s\n' "$RUN_ID" ;;
    "volume inspect --format {{ index .Labels \"$LABEL_KEY\" }} $STOPPED_VOLUME"|\
    "volume inspect --format {{ index .Labels \"$LABEL_KEY\" }} $RUNNING_VOLUME") printf '%s\n' "$RUN_ID" ;;
    "inspect --format {{.State.Running}} $STOPPED_NAME") printf 'false\n' ;;
    "inspect --format {{.State.Running}} $RUNNING_NAME") printf 'true\n' ;;
    "cp $STOPPED_NAME:/container-value "*) printf '%s' "$RUN_ID-stopped-container" > "$3" ;;
    "cp $RUNNING_NAME:/container-value "*) printf '%s' "$RUN_ID-running-container" > "$3" ;;
    run\ --rm\ --label\ "$LABEL_KEY=$RUN_ID"\ -v\ "$STOPPED_VOLUME:/state:ro"*) printf '%s\n' "$RUN_ID-stopped-volume" ;;
    run\ --rm\ --label\ "$LABEL_KEY=$RUN_ID"\ -v\ "$RUNNING_VOLUME:/state:ro"*) printf '%s\n' "$RUN_ID-running-volume" ;;
    *) echo "unexpected fake Docker call on $socket: $*" >&2; return 1 ;;
  esac
}
assert_persisted_resources candidate fake.sock true
grep -qx 'settings:candidate' "$TMP/assertions.log"
if (FAKE_BAD_RUNNING_ID=1; assert_persisted_resources candidate fake.sock true) >/dev/null 2>&1; then
  echo "test-release-upgrade-rollback-smoke: accepted a changed running-container ID" >&2
  exit 1
fi

# Fake the high-level driver and pin its order. In particular, rollback is asserted before owned
# cleanup, so the harness cannot claim success by deleting the state it was supposed to preserve.
FAKE_LOG="$TMP/driver.log"
(
  cleanup() { printf 'cleanup\n' >> "$FAKE_LOG"; }
  preflight_clean_user() { printf 'preflight\n' >> "$FAKE_LOG"; }
  preflight_apps() { PREVIOUS_APP=previous.app; printf 'apps\n' >> "$FAKE_LOG"; }
  preflight_previous_engine_state() { printf 'previous-engine\n' >> "$FAKE_LOG"; }
  configure_persisted_settings() { printf 'settings\n' >> "$FAKE_LOG"; }
  install_exact_app() { printf 'install:%s\n' "$1" >> "$FAKE_LOG"; }
  launch_installed_app() { CURRENT_SOCKET="$2"; printf 'launch:%s:%s\n' "$1" "$2" >> "$FAKE_LOG"; }
  seed_persistent_state() { printf 'seed:%s\n' "$1" >> "$FAKE_LOG"; }
  assert_persisted_resources() { printf 'assert:%s:%s:%s\n' "$1" "$2" "$3" >> "$FAKE_LOG"; }
  transition_to_candidate() { CURRENT_SOCKET=candidate.sock; printf 'transition:candidate\n' >> "$FAKE_LOG"; }
  exercise_exact_candidate() { printf 'exercise:%s\n' "$1" >> "$FAKE_LOG"; }
  transition_to_previous() { CURRENT_SOCKET=rollback.sock; printf 'transition:rollback\n' >> "$FAKE_LOG"; }
  remove_owned_resources_on_socket() { printf 'remove:%s\n' "$1" >> "$FAKE_LOG"; }
  PREVIOUS_KIND=modern
  PREVIOUS_VERSION=0.2.0
  PREVIOUS_BUILD=16
  CANDIDATE_VERSION=0.3.0
  CANDIDATE_BUILD=42
  CANDIDATE_APP=candidate.app
  TEST_ROOT="$TMP/fake-driver"
  LOG_ROOT="$TEST_ROOT/evidence"
  run_upgrade_rollback_gate
)
cat > "$TMP/expected-driver.log" <<'EOF'
preflight
apps
previous-engine
settings
install:previous.app
launch:previous:/root/.dory/dory.sock
seed:/root/.dory/dory.sock
assert:previous:/root/.dory/dory.sock:true
transition:candidate
assert:candidate:candidate.sock:true
exercise:candidate.sock
transition:rollback
assert:rollback:rollback.sock:true
remove:rollback.sock
cleanup
EOF
# The fake uses this test process's actual HOME, not necessarily /root.
sed "s#/root#$HOME#g" "$TMP/expected-driver.log" > "$TMP/expected-driver-home.log"
cmp "$TMP/expected-driver-home.log" "$FAKE_LOG"

bash -n scripts/release-upgrade-rollback-smoke.sh
echo "test-release-upgrade-rollback-smoke: PASS"

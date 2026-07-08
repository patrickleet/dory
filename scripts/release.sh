#!/bin/bash
# Dory release pipeline: archive + Developer ID sign -> notarize -> staple -> zip/dmg.
#
# Default release shape:
#   * Dory-<version>-arm64.zip      Apple silicon optimized app
#   * Dory-<version>-x86_64.zip     Intel optimized app
#   * Dory-<version>-universal.zip  Universal app
#   * Dory-<version>.zip            Compatibility alias for the universal app
#
# Requires (one-time, your Apple Developer account -- the external gate):
#   * A "Developer ID Application" certificate in your keychain.
#   * A notarytool keychain profile:  xcrun notarytool store-credentials dory-notary \
#         --apple-id you@example.com --team-id <TEAMID> --password <app-specific-password>
#
# Then:  scripts/release.sh 1.0.0
set -euo pipefail

# Prefer an explicit DEVELOPER_DIR; otherwise pick up a local Xcode install, else fall back to
# the Xcode already selected by xcode-select (CI runners set this themselves).
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for app in /Applications/Xcode.app /Applications/Xcode-*.app "$HOME"/Applications/Xcode*.app; do
    [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$app/Contents/Developer"; break; }
  done
fi
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
# Monotonic build number (CFBundleVersion). Sparkle compares this to detect updates. CI passes
# the run number; locally it defaults to 1.
BUILD="${2:-${DORY_BUILD:-1}}"
BUILD_DIR="${DORY_RELEASE_BUILD_DIR:-release-build}"
NOTARY_PROFILE="${DORY_NOTARY_PROFILE:-dory-notary}"
TEAM="${NOTARY_TEAM_ID:-864H636QW4}"
RELEASE_VARIANTS="${DORY_RELEASE_VARIANTS:-arm64 x86_64 universal}"
SIGN_IDENTITY="${DORY_SIGN_ID:-Developer ID Application}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

notarize() {
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

path_if_exists() {
  [ -f "$1" ] && printf '%s' "$1"
}

copy_alias() {
  local source="$1" destination="$2"
  [ -n "$source" ] && [ -f "$source" ] || return 0
  [ "$source" = "$destination" ] && return 0
  rm -f "$destination"
  ln -f "$source" "$destination" 2>/dev/null || cp -p "$source" "$destination"
}

assert_app_binary_arches() {
  local binary="$1" expected="$2" archs arch
  archs="$(lipo -archs "$binary")"
  for arch in $expected; do
    case " $archs " in
      *" $arch "*) ;;
      *) echo "release error: $binary missing $arch (archs: ${archs:-none})" >&2; exit 1 ;;
    esac
  done
  echo "==> Verified app binary for $expected: $archs"
}

configure_variant() {
  local requested="$1"
  VARIANT="$requested"
  case "$requested" in
    arm64|apple-silicon|silicon)
      VARIANT="arm64"
      VARIANT_SUFFIX="arm64"
      XCODE_ARCHS="arm64"
      BUNDLE_ARCHES="arm64"
      HELPER_ARCHES="arm64"
      HOST_CLI_ARCHES="arm64"
      NATIVE_GUEST_ARCH="arm64"
      ;;
    x86_64|amd64|intel)
      VARIANT="x86_64"
      VARIANT_SUFFIX="x86_64"
      XCODE_ARCHS="x86_64"
      BUNDLE_ARCHES="amd64"
      HELPER_ARCHES="x86_64"
      HOST_CLI_ARCHES="x86_64"
      NATIVE_GUEST_ARCH="amd64"
      ;;
    universal|fat)
      VARIANT="universal"
      VARIANT_SUFFIX="universal"
      XCODE_ARCHS="arm64 x86_64"
      BUNDLE_ARCHES="arm64 amd64"
      HELPER_ARCHES="arm64 x86_64"
      HOST_CLI_ARCHES="arm64 x86_64"
      # Compatibility symlinks inside universal bundles are advisory; doryd selects arch-specific
      # resources at runtime from Contents/Resources.
      NATIVE_GUEST_ARCH="${DORY_UNIVERSAL_NATIVE_GUEST_ARCH:-arm64}"
      ;;
    *)
      echo "release error: unknown DORY_RELEASE_VARIANTS entry '$requested' (use arm64, x86_64, universal)" >&2
      exit 1
      ;;
  esac
}

sign_app() {
  local app="$1"
  echo "==> Signing $(basename "$(dirname "$app")")/Dory.app (Developer ID + hardened runtime)..."
  # NOT --deep: bundle-engine.sh already signed nested helpers with their own entitlements
  # (dory-hv needs com.apple.security.hypervisor, dory-vm/dory-vmm need virtualization), and --deep
  # would re-sign them without those entitlements.
  codesign --force --options runtime --timestamp --entitlements Dory/Dory.entitlements --sign "$SIGN_IDENTITY" "$app"
}

archive_variant() {
  local variant="$1" archive="$2"
  echo "==> Archiving + signing Dory $VERSION $variant (Developer ID, team $TEAM, archs: $XCODE_ARCHS)..."
  xcodebuild -project Dory.xcodeproj -scheme Dory -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    ARCHS="$XCODE_ARCHS" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM" \
    archive
}

zip_app() {
  local app="$1" zip="$2"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
}

finish_app_artifact() {
  local app="$1" zip="$2" dmg="$3"
  zip_app "$app" "$zip"
  if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> Skipping notarization for $zip (DORY_SKIP_NOTARIZE=1)"
  else
    echo "==> Notarizing $zip..."
    notarize "$zip"
    xcrun stapler staple "$app"
    zip_app "$app" "$zip"
  fi

  if [ "${DORY_MAKE_DMG:-1}" = "1" ]; then
    echo "==> Building DMG $dmg..."
    scripts/make-dmg.sh "$app" "$VERSION" "$dmg"
    if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
      echo "==> Skipping notarization for $dmg (DORY_SKIP_NOTARIZE=1)"
    else
      echo "==> Notarizing $dmg..."
      notarize "$dmg"
      xcrun stapler staple "$dmg"
    fi
  fi
}

ZIPS=()
DMGS=()
FIRST_ARCHIVE=""
UNIVERSAL_ARCHIVE=""
UNIVERSAL_ZIP=""
UNIVERSAL_DMG=""
ARM64_APP=""

for requested in $RELEASE_VARIANTS; do
  configure_variant "$requested"
  ARCHIVE="$BUILD_DIR/Dory-$VARIANT_SUFFIX.xcarchive"
  EXPORT_DIR="$BUILD_DIR/export-$VARIANT_SUFFIX"
  APP="$EXPORT_DIR/Dory.app"
  ZIP="$BUILD_DIR/Dory-$VERSION-$VARIANT_SUFFIX.zip"
  DMG="$BUILD_DIR/Dory-$VERSION-$VARIANT_SUFFIX.dmg"

  archive_variant "$VARIANT" "$ARCHIVE"
  [ -n "$FIRST_ARCHIVE" ] || FIRST_ARCHIVE="$ARCHIVE"
  [ "$VARIANT" = "universal" ] && UNIVERSAL_ARCHIVE="$ARCHIVE"

  rm -rf "$EXPORT_DIR"
  mkdir -p "$EXPORT_DIR"
  cp -R "$ARCHIVE/Products/Applications/Dory.app" "$EXPORT_DIR/"
  assert_app_binary_arches "$APP/Contents/MacOS/Dory" "$XCODE_ARCHS"

  # Engine bundling is the full-release default: users should be able to install Dory.app on a clean
  # Mac without Docker Desktop, Colima, OrbStack, Homebrew, or Apple `container`.
  if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ]; then
    echo "==> Bundling the self-contained engine for $VARIANT..."
    DORY_BUNDLE_ARCHES="$BUNDLE_ARCHES" \
    DORY_SWIFTPM_HELPER_ARCHES="$HELPER_ARCHES" \
    DORY_HOST_CLI_ARCHES="$HOST_CLI_ARCHES" \
    DORY_BUNDLE_NATIVE_ARCH="$NATIVE_GUEST_ARCH" \
    DORY_REQUIRE_BUNDLE_ASSETS="${DORY_REQUIRE_BUNDLE_ASSETS:-1}" \
      scripts/bundle-engine.sh "$APP"
  else
    echo "==> WARNING: producing a development app without bundled engine assets for $VARIANT."
  fi

  sign_app "$APP"
  finish_app_artifact "$APP" "$ZIP" "$DMG"
  ZIPS+=("$ZIP")
  [ -f "$DMG" ] && DMGS+=("$DMG")

  case "$VARIANT" in
    arm64) ARM64_APP="$APP" ;;
    universal)
      UNIVERSAL_ZIP="$ZIP"
      [ -f "$DMG" ] && UNIVERSAL_DMG="$DMG"
      ;;
  esac
done

# Keep the historic cask/download filenames pointed at the universal artifact.
COMPAT_ZIP=""
COMPAT_DMG=""
if [ -n "$UNIVERSAL_ZIP" ]; then
  COMPAT_ZIP="$BUILD_DIR/Dory-$VERSION.zip"
  copy_alias "$UNIVERSAL_ZIP" "$COMPAT_ZIP"
  ZIPS+=("$COMPAT_ZIP")
fi
if [ -n "$UNIVERSAL_DMG" ]; then
  COMPAT_DMG="$BUILD_DIR/Dory-$VERSION.dmg"
  copy_alias "$UNIVERSAL_DMG" "$COMPAT_DMG"
  DMGS+=("$COMPAT_DMG")
fi

# ---- Extra release flavors ---------------------------------------------------------------
# lite: app only, universal when the universal variant is built.
LITE_ZIP=""
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && [ "${DORY_BUILD_LITE:-1}" = "1" ]; then
  LITE_ARCHIVE="${UNIVERSAL_ARCHIVE:-$FIRST_ARCHIVE}"
  if [ -n "$LITE_ARCHIVE" ] && [ -d "$LITE_ARCHIVE/Products/Applications/Dory.app" ]; then
    echo "==> Building lite app (no bundled engine)..."
    LITE_DIR="$BUILD_DIR/export-lite"
    LITE_APP="$LITE_DIR/Dory.app"
    rm -rf "$LITE_DIR"
    mkdir -p "$LITE_DIR"
    cp -R "$LITE_ARCHIVE/Products/Applications/Dory.app" "$LITE_DIR/"
    sign_app "$LITE_APP"
    LITE_ZIP="$BUILD_DIR/Dory-$VERSION-lite.zip"
    zip_app "$LITE_APP" "$LITE_ZIP"
    if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
      echo "==> Skipping notarization for $LITE_ZIP (DORY_SKIP_NOTARIZE=1)"
    else
      echo "==> Notarizing lite app..."
      notarize "$LITE_ZIP"
      xcrun stapler staple "$LITE_APP"
      zip_app "$LITE_APP" "$LITE_ZIP"
    fi
  fi
fi

# Headless runtime stays arm64 for now because scripts/runtime/dory-engine is currently the
# Apple-silicon CLI runtime. The platform-optimized app artifacts above are the primary download
# surface for Intel + universal distribution.
RUNTIME_TAR=""
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && [ "${DORY_BUILD_RUNTIME:-1}" = "1" ] && [ -n "$ARM64_APP" ]; then
  echo "==> Packaging standalone engine runtime..."
  RUNTIME_NAME="dory-engine-$VERSION-arm64"
  RUNTIME_DIR="$BUILD_DIR/runtime/$RUNTIME_NAME"
  rm -rf "$BUILD_DIR/runtime"
  mkdir -p "$RUNTIME_DIR/bin" "$RUNTIME_DIR/share/dory"
  cp "$ARM64_APP/Contents/Helpers/dory-hv" "$RUNTIME_DIR/bin/"
  cp "$ARM64_APP/Contents/Helpers/gvproxy" "$RUNTIME_DIR/bin/"
  cp "$ARM64_APP/Contents/Resources/dory-hv-kernel-arm64.lzfse" "$RUNTIME_DIR/share/dory/"
  [ -f "$ARM64_APP/Contents/Resources/dory-agent-linux-arm64" ] && cp "$ARM64_APP/Contents/Resources/dory-agent-linux-arm64" "$RUNTIME_DIR/share/dory/"
  [ -f "$ARM64_APP/Contents/Resources/dory-engine-rootfs.ext4.lzfse" ] && cp "$ARM64_APP/Contents/Resources/dory-engine-rootfs.ext4.lzfse" "$RUNTIME_DIR/share/dory/"
  cp scripts/runtime/dory-engine "$RUNTIME_DIR/dory-engine"
  chmod 0755 "$RUNTIME_DIR/dory-engine"
  cat > "$RUNTIME_DIR/README.md" <<EOF
# dory-engine $VERSION (arm64)

Dory's container engine as a standalone, Colima-style runtime: one shared Linux VM running
dockerd, with memory returned to macOS as workloads idle.

    ./dory-engine start          # boots the engine, publishes ~/.dory/engine.sock
    ./dory-engine start --amd64  # also enable x86/amd64 images via QEMU emulation
    docker context use dory-engine
    docker run --rm alpine echo hello

\`dory-engine stop|status|env\` manage it. Requires macOS 15+ on Apple silicon.
EOF
  tar -czf "$BUILD_DIR/$RUNTIME_NAME.tar.gz" -C "$BUILD_DIR/runtime" "$RUNTIME_NAME"
  RUNTIME_TAR="$BUILD_DIR/$RUNTIME_NAME.tar.gz"
fi

DEFAULT_ZIP="${COMPAT_ZIP:-${UNIVERSAL_ZIP:-${ZIPS[0]:-}}}"
DEFAULT_DMG="${COMPAT_DMG:-${UNIVERSAL_DMG:-}}"
DEFAULT_SHA256=""
[ -n "$DEFAULT_ZIP" ] && DEFAULT_SHA256="$(sha256_file "$DEFAULT_ZIP")"

echo "==> Done."
if [ "${#ZIPS[@]}" -gt 0 ]; then
  for artifact in "${ZIPS[@]}"; do
    [ -n "$artifact" ] && [ -f "$artifact" ] || continue
    echo "    $artifact  (sha256: $(sha256_file "$artifact"))"
  done
fi
if [ "${#DMGS[@]}" -gt 0 ]; then
  for artifact in "${DMGS[@]}"; do
    [ -n "$artifact" ] && [ -f "$artifact" ] || continue
    echo "    $artifact  (sha256: $(sha256_file "$artifact"))"
  done
fi
for artifact in "$LITE_ZIP" "$RUNTIME_TAR"; do
  [ -n "$artifact" ] && [ -f "$artifact" ] || continue
  echo "    $artifact  (sha256: $(sha256_file "$artifact"))"
done

# Expose outputs to a GitHub Actions step when running in CI.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "zip=$DEFAULT_ZIP"
    echo "sha256=$DEFAULT_SHA256"
    echo "version=$VERSION"
    echo "build=$BUILD"
    echo "dmg=$DEFAULT_DMG"
    echo "lite=$LITE_ZIP"
    echo "runtime=$RUNTIME_TAR"
    echo "zip_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-arm64.zip")"
    echo "zip_x86_64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-x86_64.zip")"
    echo "zip_universal=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-universal.zip")"
    echo "dmg_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-arm64.dmg")"
    echo "dmg_x86_64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-x86_64.dmg")"
    echo "dmg_universal=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-universal.dmg")"
  } >> "$GITHUB_OUTPUT"
fi

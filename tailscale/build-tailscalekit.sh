#!/bin/bash
# ci/build-tailscalekit.sh
# Build TailscaleKit.xcframework from libtailscale (iOS device + iOS Simulator + macOS arm64).
# Usage: bash ci/build-tailscalekit.sh
# Requires: Go 1.24.x in PATH, Xcode active (DEVELOPER_DIR set by caller)
# Notes:
#   - macOS slice requires macOS 15.0+ (MACOS_TARGET=15.0 in libtailscale Makefile)
#   - macOS slice is arm64 only (Apple Silicon); no Intel x86_64 support
#   - TailscaleKit (macOS) target exists in libtailscale/swift/TailscaleKit.xcodeproj
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBTAILSCALE_DIR="$REPO_ROOT/vendor/libtailscale"
SWIFT_DIR="$LIBTAILSCALE_DIR/swift"
OUTPUT_DIR="$REPO_ROOT/vendor"
OUTPUT_XCFW="$OUTPUT_DIR/TailscaleKit.xcframework"
PRIVACY_PLIST="$SCRIPT_DIR/PrivacyInfo.xcprivacy"

echo "=== Building TailscaleKit xcframework (iOS + iOS Simulator + macOS arm64) ==="
echo "libtailscale: $LIBTAILSCALE_DIR"
echo "Go version: $(go version)"
echo "Xcode: $(xcodebuild -version | head -1)"

# Verify submodule is present
if [ ! -f "$SWIFT_DIR/Makefile" ]; then
  echo "ERROR: vendor/libtailscale/swift/Makefile not found"
  echo "Run: git submodule update --init --recursive"
  exit 1
fi

# Clean previous build artifacts
rm -rf "$SWIFT_DIR/build/"

# --------------------------------------------------------------------------
# vendor/libtailscale tracks UPSTREAM tailscale/libtailscale.
#
# Upstream is slow-moving — it pinned tailscale.com v1.94.1 for six months
# while Tailscale shipped through v1.102.3 — so this repo used to carry a fork
# (indiagrams/libtailscale) purely to bump that pin and add nine lines of
# NSLog tracing. A whole second repository, plus a cross-repo PAT, for nine
# lines and a `go get`.
#
# Both are now reproduced here at build time instead:
#   1. the version comes from tailscale/TAILSCALE_VERSION (this repo)
#   2. local changes live in tailscale/patches/*.patch (this repo)
#
# Everything that made the fork necessary is visible and reviewable in one
# place, and there is no second repo to keep in sync.
# --------------------------------------------------------------------------
TSNET_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/TAILSCALE_VERSION")"
if [ -z "$TSNET_VERSION" ]; then
  echo "ERROR: tailscale/TAILSCALE_VERSION is empty"
  exit 1
fi
case "$TSNET_VERSION" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "ERROR: TAILSCALE_VERSION must look like v1.102.3 (got '$TSNET_VERSION')"; exit 1 ;;
esac
echo "--- tailscale.com ${TSNET_VERSION} (from tailscale/TAILSCALE_VERSION) ---"

# Apply local patches to the submodule working tree.
#
# `git apply --check` first so a patch that no longer applies is a hard error
# rather than a half-patched tree. This is the same discipline as the
# module-cache patches below: never build silently from a source that is not
# what we think it is.
if [ -d "$SCRIPT_DIR/patches" ]; then
  for patch in "$SCRIPT_DIR"/patches/*.patch; do
    [ -e "$patch" ] || continue
    name="$(basename "$patch")"
    if git -C "$LIBTAILSCALE_DIR" apply --check "$patch" 2>/dev/null; then
      git -C "$LIBTAILSCALE_DIR" apply "$patch"
      echo "--- Applied patch: $name ---"
    elif git -C "$LIBTAILSCALE_DIR" apply --reverse --check "$patch" 2>/dev/null; then
      echo "--- Patch already applied, skipping: $name ---"
    else
      echo "ERROR: patch does not apply to vendor/libtailscale: $name"
      echo "Upstream libtailscale has changed underneath it. Rebase the patch;"
      echo "do NOT drop it — macos-sandbox-check.yml greps for the tracing it adds."
      exit 1
    fi
  done
fi

# Move the submodule's go.mod onto the version we actually want to build.
# Upstream's pin is only a starting point; TAILSCALE_VERSION above is the
# source of truth. This edits the submodule working tree, which is why
# vendor/libtailscale is expected to be dirty during a build.
echo "--- go get tailscale.com@${TSNET_VERSION} ---"
( cd "$LIBTAILSCALE_DIR" \
    && go get "tailscale.com@${TSNET_VERSION}" \
    && go mod tidy ) || {
  echo "ERROR: could not move libtailscale onto tailscale.com@${TSNET_VERSION}"
  echo "The bindings may not compile against this version."
  exit 1
}

cd "$SWIFT_DIR"

# Both module-cache patches target the same file — define the path once here.
#
# The path is derived from TSNET_VERSION rather than hardcoded. It used to be
# pinned to v1.96.4, which silently rotted the moment the dependency was bumped: the
# path stopped resolving, both patches below hit their "not found" WARNING branch, and
# the build produced an xcframework missing the Bus nil guard — a crash fix — with no
# error. Deriving it keeps the patches attached to whatever version is actually built.
TSNET_GO="$(go env GOMODCACHE)/tailscale.com@${TSNET_VERSION}/tsnet/tsnet.go"
if [ ! -f "$TSNET_GO" ]; then
  echo "ERROR: $TSNET_GO not found — run 'go mod download' in $LIBTAILSCALE_DIR first"
  exit 1
fi

# Patch 1: darwin os.Executable fallback in tsnet.start().
# Our PR #19052 (prakashrj:tsnet-darwin-executable-fallback) merged into tailscale:main
# on 2026-03-21 and first SHIPPED in v1.98.0 — it is NOT in v1.96.4, whose release branch
# was cut before the merge. When TailscaleKit runs as a macOS framework and the fallback
# is absent, os.Executable() returns an error and the default: branch propagates it,
# failing TailscaleNode.init() with "tsnet: cannot find executable path".
# On v1.98.0+ this is upstream and the check below reports "already applied" — the block
# is kept only so the build still works if the dependency is ever pinned back below v1.98.
if [ -f "$TSNET_GO" ]; then
  chmod u+w "$TSNET_GO" 2>/dev/null || true
  if grep -q '"ios", "darwin"' "$TSNET_GO"; then
    echo "--- darwin os.Executable fallback already applied ---"
  elif grep -q '"ios":' "$TSNET_GO"; then
    python3 -c "
p = '$TSNET_GO'
with open(p, 'r') as f:
    c = f.read()
old = 'case \"ios\":\n\t\t\t// When compiled as a framework (via TailscaleKit in libtailscale),\n\t\t\t// os.Executable() returns an error, so fall back to \"tsnet\" there\n\t\t\t// too.\n\t\t\texe = \"tsnet\"'
new = 'case \"ios\", \"darwin\":\n\t\t\t// When compiled as a framework (via TailscaleKit in libtailscale),\n\t\t\t// os.Executable() returns an error on both iOS and macOS, so fall\n\t\t\t// back to \"tsnet\" there too.\n\t\t\texe = \"tsnet\"'
if old in c:
    with open(p, 'w') as f:
        f.write(c.replace(old, new))
    print('--- Applied darwin os.Executable fallback patch ---')
else:
    print('WARNING: darwin fallback pattern not found in tsnet.go')
"
  else
    echo "WARNING: darwin os.Executable fallback — tsnet.go pattern unexpected"
  fi
else
  echo "WARNING: $TSNET_GO not found — run 'go mod download' in vendor/libtailscale first"
fi

# Patch 2: Bus nil guard in tsnet.close().
# STILL REQUIRED — this one is NOT upstream. Verified present in unpatched form
# (`s.sys.Bus.Get().Close()`) in v1.102.3. Unlike Patch 1 it has no upstream PR, so it
# must be re-applied on every dependency bump until it is contributed and released.
# s.sys.Bus.Get().Close() crashes (EXC_BAD_ACCESS) if close() runs while Bus
# hasn't been initialised. SubSystem.Get() panics (→ EXC_BAD_ACCESS at 0x0 via
# Go runtime nil-deref) when the subsystem value hasn't been Set().
# Fix: use GetOK() which returns (value, bool) without panicking, guarded by
# s.sys != nil so we only attempt Bus access when s.start() completed.
if [ -f "$TSNET_GO" ]; then
  chmod u+w "$TSNET_GO" 2>/dev/null || true
  if grep -q 'Bus.GetOK()' "$TSNET_GO"; then
    echo "--- Bus nil guard (GetOK) already applied ---"
  elif grep -q 'if s.sys != nil' "$TSNET_GO" || grep -q 's.sys.Bus.Get().Close()' "$TSNET_GO"; then
    # Rewrite in place with python3, NOT `sed -i`. The Go module cache directory is
    # read-only, and `sed -i` writes a temp file into the target's directory, so it fails
    # with "Permission denied" even after chmod u+w on the file itself. python3 opens the
    # existing file for writing, which only needs the file bit. (Patch 1 above always used
    # python3 and worked; Patch 2 used sed and silently did nothing.)
    python3 -c "
import sys
p = '$TSNET_GO'
with open(p) as f:
    c = f.read()

intermediate = 'if bus := s.sys.Bus.Get(); bus != nil {'
original = '\to.sys.Bus.Get().Close()'.replace('o.', 's.')
guard = ('\tif s.sys != nil {\n'
         '\t\tif bus, ok := s.sys.Bus.GetOK(); ok && bus != nil {\n'
         '\t\t\tbus.Close()\n'
         '\t\t}\n'
         '\t}')

if intermediate in c:
    c = c.replace(intermediate, 'if bus, ok := s.sys.Bus.GetOK(); ok && bus != nil {')
    label = 'Upgraded Bus nil guard to GetOK()'
elif original in c:
    c = c.replace(original, guard)
    label = 'Applied Bus nil guard (GetOK) patch'
else:
    sys.exit('ERROR: Bus nil guard — no known pattern matched in tsnet.go')

with open(p, 'w') as f:
    f.write(c)
print('--- ' + label + ' ---')
"
  else
    echo "ERROR: could not apply Bus nil guard — tsnet.go structure unexpected"
    exit 1
  fi

  # Fail loudly if the guard is not present. This patch is a crash fix
  # (EXC_BAD_ACCESS in tsnet.close()) and is NOT upstream, so shipping an
  # xcframework without it must never be silent.
  if ! grep -q 'Bus.GetOK()' "$TSNET_GO"; then
    echo "ERROR: Bus nil guard missing from $TSNET_GO after patching — refusing to build"
    exit 1
  fi
else
  echo "WARNING: $TSNET_GO not found — run 'go mod download' in vendor/libtailscale first"
fi

echo "--- Running make ios (iOS device arm64, ~2-3 min) ---"
make ios

echo "--- Running make ios-sim (iOS Simulator arm64+x86_64, ~2-3 min) ---"
make ios-sim

echo "--- Running make macos (macOS arm64, requires macOS 15.0+, ~2-3 min) ---"
make macos

# Framework paths after build
IOS_FW="./build/Build/Products/Release-iphoneos/TailscaleKit.framework"
SIM_FW="./build/Build/Products/Release-iphonesimulator/TailscaleKit.framework"
MACOS_FW="./build/Build/Products/Release/TailscaleKit.framework"

# Verify all three frameworks were produced
for fw in "$IOS_FW" "$SIM_FW" "$MACOS_FW"; do
  if [ ! -d "$fw" ]; then
    echo "ERROR: expected framework not found: $fw"
    ls -la "./build/Build/Products/" || true
    exit 1
  fi
done
echo "--- All three slices verified ---"

# Re-sign the macOS framework with a fresh ad-hoc signature (no linker-signed flag).
# Must be done AFTER PrivacyInfo.xcprivacy is injected into Versions/A/Resources/ below
# (see deferred injection note), but we sign the FRAMEWORK (not just the binary) so that
# Versions/A/_CodeSignature/CodeResources covers all content including PrivacyInfo.xcprivacy.
# Done at the end of this script after all injections are complete.

# Inject PrivacyInfo.xcprivacy into each slice.
# iOS/Simulator: flat bundles — PrivacyInfo.xcprivacy goes at the bundle root.
# macOS: versioned bundle — PrivacyInfo.xcprivacy must be in Versions/A/Resources/ so that
# it is covered by the Versions/A/_CodeSignature/CodeResources seal. Placing it at the
# versioned bundle root (outside Versions/) leaves it unsealed, causing App Store error 90238.
echo "--- Injecting PrivacyInfo.xcprivacy into all slices ---"
cp "$PRIVACY_PLIST" "$IOS_FW/PrivacyInfo.xcprivacy"
cp "$PRIVACY_PLIST" "$SIM_FW/PrivacyInfo.xcprivacy"
cp "$PRIVACY_PLIST" "$MACOS_FW/Versions/A/Resources/PrivacyInfo.xcprivacy"
# Also remove Info.plist from the macOS versioned bundle root if present.
# It is a duplicate (canonical copy: Versions/A/Resources/Info.plist accessible via Resources->
# symlink) and its presence at the versioned bundle root triggers the same 90238 unsealed error.
rm -f "$MACOS_FW/Info.plist"

# Create 3-slice xcframework (xcodebuild auto-generates Info.plist with all platform metadata)
echo "--- Creating xcframework with iOS + Simulator + macOS ---"
mkdir -p "./build/Build/Products/Release-all"
xcodebuild -create-xcframework \
  -framework "$IOS_FW" \
  -framework "$SIM_FW" \
  -framework "$MACOS_FW" \
  -output "./build/Build/Products/Release-all/TailscaleKit.xcframework"

# Copy to vendor/ for Xcode to consume
echo "--- Copying to $OUTPUT_XCFW ---"
rm -rf "$OUTPUT_XCFW"
cp -R "./build/Build/Products/Release-all/TailscaleKit.xcframework" "$OUTPUT_XCFW"

# Re-sign the macOS slice in vendor/ with a fresh ad-hoc (no linker-signed flag).
# The Go linker embeds adhoc,linker-signed; without --force Xcode's archive step can't
# replace the signature. Signing the FRAMEWORK (not just the binary) ensures the seal
# covers Versions/A/Resources/PrivacyInfo.xcprivacy.
#
# CRITICAL: Sign from a temp copy that has Headers/ and Modules/ removed (mirroring
# what Xcode's builtin-copy -exclude Headers -exclude Modules does when embedding).
# If we seal the full vendor (including Headers/Modules), the _CodeSignature/CodeResources
# references those files, but Xcode strips them on embed → "invalid resource directory".
# By signing the stripped copy, the resulting CodeResources covers exactly the same set
# of files that will survive the Xcode embed step, so codesign --verify passes on the
# embedded framework and macOS can load it.
VENDOR_MACOS_FW="$OUTPUT_XCFW/macos-arm64/TailscaleKit.framework"
echo "--- Re-signing macOS framework (from embed-equivalent temp copy) ---"
SIGN_TEMP=$(mktemp -d)
cp -R "$VENDOR_MACOS_FW" "$SIGN_TEMP/TailscaleKit.framework"
rm -rf "$SIGN_TEMP/TailscaleKit.framework/Versions/A/Headers"
rm -rf "$SIGN_TEMP/TailscaleKit.framework/Versions/A/Modules"
rm -f  "$SIGN_TEMP/TailscaleKit.framework/Headers"
rm -f  "$SIGN_TEMP/TailscaleKit.framework/Modules"
codesign --force --sign - "$SIGN_TEMP/TailscaleKit.framework"
# Copy _CodeSignature and re-signed binary back to vendor
mkdir -p "$VENDOR_MACOS_FW/Versions/A/_CodeSignature"
cp "$SIGN_TEMP/TailscaleKit.framework/Versions/A/_CodeSignature/CodeResources" \
   "$VENDOR_MACOS_FW/Versions/A/_CodeSignature/CodeResources"
cp "$SIGN_TEMP/TailscaleKit.framework/Versions/A/TailscaleKit" \
   "$VENDOR_MACOS_FW/Versions/A/TailscaleKit"
rm -rf "$SIGN_TEMP"
echo "--- Verification (vendor verifies as-is; embedded copy verifies after Headers/Modules stripped) ---"

echo "=== TailscaleKit.xcframework built successfully ==="
echo "Slices:"
ls "$OUTPUT_XCFW/"

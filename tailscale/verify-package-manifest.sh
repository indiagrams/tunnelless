#!/bin/bash
# Asserts Package.swift points at the release for the currently pinned version.
#
# Why this exists: a version bump changes tailscale/TAILSCALE_VERSION, and the
# release URL and checksum in Package.swift must move with it. Nothing else
# would notice if they did not — SwiftPM would keep resolving the OLD binary
# perfectly happily, so consumers would silently sit on a stale tsnet while
# everything here reported green.
#
# Checks:
#   1. the pinned URL names the release for TAILSCALE_VERSION
#   2. the checksum in the manifest matches the published asset
#
# Usage: bash tailscale/verify-package-manifest.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/TAILSCALE_VERSION")"
[ -n "$VERSION" ] || { echo "ERROR: tailscale/TAILSCALE_VERSION is empty"; exit 1; }
TAG="tailscalekit-${VERSION}"

URL="$(grep -oE 'https://github.com/[^"]+TailscaleKit\.xcframework\.zip' "$REPO_ROOT/Package.swift" | head -1)"
SUM="$(grep -oE 'checksum: "[a-f0-9]{64}"' "$REPO_ROOT/Package.swift" | grep -oE '[a-f0-9]{64}' | head -1)"

[ -n "$URL" ] || { echo "ERROR: no binaryTarget URL found in Package.swift"; exit 1; }
[ -n "$SUM" ] || { echo "ERROR: no checksum found in Package.swift"; exit 1; }

echo "pinned version : $VERSION"
echo "manifest URL   : $URL"
echo "manifest sum   : $SUM"

# 1. URL must name the release for the pinned version.
case "$URL" in
  *"/download/${TAG}/"*) echo "OK: URL matches $TAG" ;;
  *)
    echo "ERROR: Package.swift points at a different release than tailscale/TAILSCALE_VERSION"
    echo "       expected a URL containing /download/${TAG}/"
    echo "       SwiftPM consumers would resolve the wrong tsnet version."
    exit 1
    ;;
esac

# 2. Checksum must match what is actually published.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if ! curl -fsSL "$URL" -o "$TMP/asset.zip"; then
  echo "ERROR: could not download $URL"
  echo "       Either the release is missing or the asset was renamed."
  exit 1
fi
ACTUAL="$(shasum -a 256 "$TMP/asset.zip" | awk '{print $1}')"
if [ "$ACTUAL" = "$SUM" ]; then
  echo "OK: checksum matches the published asset"
else
  echo "ERROR: checksum mismatch"
  echo "       manifest:  $SUM"
  echo "       published: $ACTUAL"
  echo "       Update Package.swift — SwiftPM resolution will fail for everyone until you do."
  exit 1
fi

echo "==="
echo "Package.swift is consistent with $TAG"

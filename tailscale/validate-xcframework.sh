#!/bin/bash
# ci/validate-xcframework.sh
# Validates TailscaleKit.xcframework meets App Store upload requirements.
# Usage: bash ci/validate-xcframework.sh
# Exit 0 = valid; Exit 1 = validation failed (build blocked)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XCFW="$SCRIPT_DIR/../vendor/TailscaleKit.xcframework"

if [ ! -d "$XCFW" ]; then
  echo "SKIP: $XCFW not found -- run ci/build-tailscalekit.sh first"
  exit 0
fi

FAIL=0

echo "=== Validating $XCFW ==="

# Check 1: No symlinks in iOS slices (App Store rejects xcframeworks with symlinks in iOS slices)
# macOS framework bundles legitimately use symlinks (Versions/Current, etc.) — exclude macos-* slices.
SYMLINKS=$(find "$XCFW" -type l | grep -v '/macos-' || true)
if [ -n "$SYMLINKS" ]; then
  echo "FAIL: symlinks found in iOS xcframework slices:"
  echo "$SYMLINKS"
  FAIL=1
else
  echo "OK: no symlinks in iOS slices (macOS framework symlinks are expected)"
fi

# Check 2: PrivacyInfo.xcprivacy present in iOS device slice (ITMS-91053)
DEVICE_PRIVACY="$XCFW/ios-arm64/TailscaleKit.framework/PrivacyInfo.xcprivacy"
if [ ! -f "$DEVICE_PRIVACY" ]; then
  echo "FAIL: PrivacyInfo.xcprivacy missing from ios-arm64 slice"
  FAIL=1
else
  echo "OK: PrivacyInfo.xcprivacy present in ios-arm64 slice"
fi

# Check 3: PrivacyInfo.xcprivacy present in iOS simulator slice (ITMS-91053)
SIM_PRIVACY="$XCFW/ios-arm64_x86_64-simulator/TailscaleKit.framework/PrivacyInfo.xcprivacy"
if [ ! -f "$SIM_PRIVACY" ]; then
  echo "FAIL: PrivacyInfo.xcprivacy missing from ios-arm64_x86_64-simulator slice"
  FAIL=1
else
  echo "OK: PrivacyInfo.xcprivacy present in ios-arm64_x86_64-simulator slice"
fi

# Check 4: Simulator slice exists (required for XCUITest and Simulator.app)
if [ ! -d "$XCFW/ios-arm64_x86_64-simulator" ]; then
  echo "FAIL: simulator slice missing -- XCUITest will fail"
  FAIL=1
else
  echo "OK: ios-arm64_x86_64-simulator slice present"
fi

# Check 5: Issue #15802 regression -- no Tailscale team ID in binary signing
DEVICE_BIN="$XCFW/ios-arm64/TailscaleKit.framework/TailscaleKit"
if [ -f "$DEVICE_BIN" ]; then
  SIGN_INFO=$(codesign -dv "$DEVICE_BIN" 2>&1 || true)
  if echo "$SIGN_INFO" | grep -q "W5364U7YZB"; then
    echo "FAIL: TailscaleKit binary signed with Tailscale team ID W5364U7YZB (Issue #15802 regression)"
    FAIL=1
  else
    echo "OK: Issue #15802 not regressed (no Tailscale team ID in binary signing)"
  fi
else
  echo "WARN: device binary not found at $DEVICE_BIN -- skipping signing check"
fi

# Check 6: Info.plist exists (xcframework structural requirement)
if [ ! -f "$XCFW/Info.plist" ]; then
  echo "FAIL: Info.plist missing from xcframework root"
  FAIL=1
else
  echo "OK: Info.plist present at xcframework root"
fi

echo "==="
if [ "$FAIL" -eq 0 ]; then
  echo "xcframework validation PASSED"
else
  echo "xcframework validation FAILED -- $FAIL check(s) failed"
  exit 1
fi

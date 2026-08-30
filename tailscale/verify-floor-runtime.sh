#!/bin/bash
# tailscale/verify-floor-runtime.sh
# Prove the declared iOS floor at RUNTIME by making dyld load the framework on
# an OS below the previous floor.
# Usage: bash tailscale/verify-floor-runtime.sh [--control-tag <release-tag>] [--keep]
# Exit 0 = the floor holds; 1 = it does not; 2 = cannot run; 3 = inconclusive.
#
# WHY THIS EXISTS
#
# `ci/check-platform-floors.sh` compares declared floors against the `minos` a
# slice REPORTS. That catches a declaration drifting from its binary, and it is
# the check that should run on every PR. It cannot catch a binary that is wrong
# about itself, and it never loads anything.
#
# The gap it leaves is the one that has actually shipped here: a floor is only
# a promise about OS versions nobody in CI is running. Every machine that
# builds this repo runs an OS above every floor it declares, so the failure the
# floor exists to prevent is invisible to every green check.
#
# This script closes it for iOS, and it is deliberately picky about WHERE it
# runs. A simulator whose version is above the PREVIOUS floor proves nothing:
# it clears the old floor and the new one alike, so it cannot tell "the floor
# was lowered" from "the floor was never lowered". The runtime has to fall in
# [declared floor, previous floor) — the only interval where those two
# hypotheses disagree. Rather than trust that a human picked such a runtime,
# the script computes the interval and refuses to run outside it.
#
# It also runs a NEGATIVE CONTROL first, because a test that cannot fail is not
# evidence. The control is this same app with only its embedded TailscaleKit
# swapped for the pre-lowering build from an earlier release. dyld must refuse
# it. If the control LOADS, the test is blind and the subject's pass is
# discarded rather than reported.
#
# NOT WIRED INTO CI, on purpose: it needs a multi-GB simulator runtime that
# GitHub's macOS images do not carry, and it is a release-time check, not a
# per-PR one. Run it whenever a floor moves or the xcframework is republished.
#
# macOS is NOT covered. There is no macOS simulator, so proving the macOS floor
# needs a real machine or VM running macOS 14–15.5. That remains structural.
set -uo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
WORK="$(mktemp -d)"
KEEP=0
CONTROL_TAG=""
DEV_NAME="floor-runtime-check"

while [ $# -gt 0 ]; do
  case "$1" in
    --control-tag) CONTROL_TAG="${2:-}"; shift 2 ;;
    --keep)        KEEP=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

cleanup() {
  [ "$KEEP" -eq 1 ] || xcrun simctl delete "$DEV_NAME" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "  FAIL $*" >&2; exit 1; }
cannot() { echo "  CANNOT RUN: $*" >&2; exit 2; }

# minos of a slice, read from the Mach-O load command.
slice_minos() {
  otool -l "$1" 2>/dev/null | awk '/LC_BUILD_VERSION/ { f=1 } f && /minos/ { print $2; exit }'
}

# "17.5" -> 17005000, so shell arithmetic can order versions.
vnum() { echo "$1" | awk -F. '{ printf "%d%03d%03d", $1, ($2==""?0:$2), ($3==""?0:$3) }'; }

echo "==> Platform floor runtime check (iOS)"

XCF="$REPO_ROOT/vendor/TailscaleKit.xcframework"
SUBJECT_FW="$XCF/ios-arm64_x86_64-simulator/TailscaleKit.framework/TailscaleKit"
[ -f "$SUBJECT_FW" ] || cannot "$XCF simulator slice not found — run make bootstrap first."

DECLARED="$(slice_minos "$SUBJECT_FW")"
[ -n "$DECLARED" ] || cannot "could not read minos from the simulator slice."
echo "  current simulator slice: minos $DECLARED"

# ─── The control: the previous published framework ───────────────────────────
# Default to the newest xcframework release that is not the one we ship now.
if [ -z "$CONTROL_TAG" ]; then
  CONTROL_TAG="$(gh release list --limit 30 --json tagName --jq \
    '[.[] | select(.tagName | startswith("tailscalekit-"))] | .[1].tagName' 2>/dev/null)"
fi
[ -n "$CONTROL_TAG" ] && [ "$CONTROL_TAG" != "null" ] \
  || cannot "no earlier tailscalekit-* release to use as a control (pass --control-tag)."
echo "  control release:         $CONTROL_TAG"

gh release download "$CONTROL_TAG" -D "$WORK" --clobber >/dev/null 2>&1 \
  || cannot "could not download $CONTROL_TAG."
(cd "$WORK" && unzip -q -o TailscaleKit.xcframework.zip) \
  || cannot "could not unpack the control xcframework."

CONTROL_FW="$WORK/TailscaleKit.xcframework/ios-arm64_x86_64-simulator/TailscaleKit.framework/TailscaleKit"
[ -f "$CONTROL_FW" ] || cannot "$CONTROL_TAG has no simulator slice."
CONTROL_MINOS="$(slice_minos "$CONTROL_FW")"
echo "  control slice:           minos $CONTROL_MINOS"

if [ "$(vnum "$CONTROL_MINOS")" -le "$(vnum "$DECLARED")" ]; then
  cannot "control ($CONTROL_MINOS) is not above the current floor ($DECLARED), so it cannot discriminate.
       Pass --control-tag for a release built before the floor was lowered."
fi

# ─── Pick a runtime inside [DECLARED, CONTROL_MINOS) ─────────────────────────
# Anything at or above CONTROL_MINOS clears BOTH floors and would pass whether
# or not the floor was ever lowered. That is the trap this check exists to
# avoid, so it is enforced rather than documented.
RUNTIME_ID=""
RUNTIME_VER=""
while read -r ver id; do
  [ -n "$ver" ] || continue
  if [ "$(vnum "$ver")" -ge "$(vnum "$DECLARED")" ] && [ "$(vnum "$ver")" -lt "$(vnum "$CONTROL_MINOS")" ]; then
    RUNTIME_VER="$ver"; RUNTIME_ID="$id"; break
  fi
done < <(xcrun simctl list runtimes 2>/dev/null \
         | awk '/^iOS /{ for (i=1;i<=NF;i++) if ($i ~ /SimRuntime\.iOS-/) print $2, $i }' \
         | sort -V)

if [ -z "$RUNTIME_ID" ]; then
  echo "  installed iOS runtimes:  $(xcrun simctl list runtimes 2>/dev/null | awk '/^iOS /{printf "%s ", $2}')"
  cannot "no installed iOS runtime in [$DECLARED, $CONTROL_MINOS).
       Every installed runtime clears the OLD floor too, so none can tell a
       lowered floor from an unlowered one. Install one with:
         xcodebuild -downloadPlatform iOS -buildVersion $DECLARED"
fi
echo "  using runtime:           iOS $RUNTIME_VER (discriminates: >= $DECLARED, < $CONTROL_MINOS)"

# ─── Build the app for the simulator ─────────────────────────────────────────
echo
echo "==> Building Tunnelless-iOS for the simulator"
(cd app && xcodegen generate >/dev/null 2>&1)
xcodebuild build \
  -project app/Tunnelless.xcodeproj -scheme Tunnelless-iOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$WORK/dd" CODE_SIGNING_ALLOWED=NO \
  > "$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; fail "simulator build failed."; }

APP="$WORK/dd/Build/Products/Debug-iphonesimulator/Tunnelless.app"
[ -d "$APP" ] || fail "no .app produced."
BID="$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")"
echo "  built $BID (MinimumOSVersion $(plutil -extract MinimumOSVersion raw "$APP/Info.plist"))"

# The control differs from the subject in exactly one file: the framework
# binary. Same code, same Info.plist floor, different slice.
CONTROL_APP="$WORK/control.app"
CONTROL_BID="$BID.floorcontrol"
cp -R "$APP" "$CONTROL_APP"
cp "$CONTROL_FW" "$CONTROL_APP/Frameworks/TailscaleKit.framework/TailscaleKit"
plutil -replace CFBundleIdentifier -string "$CONTROL_BID" "$CONTROL_APP/Info.plist"

# ─── Boot ────────────────────────────────────────────────────────────────────
echo
echo "==> Booting iOS $RUNTIME_VER simulator"
xcrun simctl delete "$DEV_NAME" >/dev/null 2>&1
UDID="$(xcrun simctl create "$DEV_NAME" "iPhone 15" "$RUNTIME_ID" 2>/dev/null)" \
  || UDID="$(xcrun simctl create "$DEV_NAME" "iPhone SE (3rd generation)" "$RUNTIME_ID" 2>/dev/null)"
[ -n "$UDID" ] || cannot "could not create a simulator on $RUNTIME_ID."
xcrun simctl boot "$UDID" >/dev/null 2>&1
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1

# Returns 0 iff dyld maps TailscaleKit into the launched process.
run_one() {
  local label="$1" app="$2" bid="$3"
  echo
  echo "==> $label"
  echo "  embedded slice: minos $(slice_minos "$app/Frameworks/TailscaleKit.framework/TailscaleKit")"
  xcrun simctl uninstall "$UDID" "$bid" >/dev/null 2>&1
  xcrun simctl install "$UDID" "$app" >/dev/null 2>&1 || { echo "  install failed"; return 1; }

  local out pid i
  out="$(xcrun simctl launch "$UDID" "$bid" 2>&1)"
  pid="$(echo "$out" | grep -oE '[0-9]+$' | head -1)"
  if [ -z "$pid" ]; then echo "  did not start: $out"; return 1; fi

  for i in $(seq 1 20); do
    if ! ps -p "$pid" >/dev/null 2>&1; then
      echo "  process exited after ${i}s"
      xcrun simctl spawn "$UDID" log show --last 60s \
        --predicate 'eventMessage CONTAINS "newer than running OS"' 2>/dev/null \
        | grep -o "built for iOS-sim [0-9.]* which is newer than running OS" | head -1 | sed 's/^/  dyld: /'
      return 1
    fi
    # lsof, not vmmap: vmmap resolves paths via coresymbolicationd and silently
    # drops them when that connection is unavailable, which reports a mapped
    # framework as unmapped. lsof reads the mapping itself and lists it as txt.
    if lsof -p "$pid" 2>/dev/null | grep -q "TailscaleKit.framework/TailscaleKit"; then
      echo "  RUNNING (pid $pid) — TailscaleKit mapped after ${i}s; dyld accepted the slice"
      xcrun simctl terminate "$UDID" "$bid" >/dev/null 2>&1
      return 0
    fi
    sleep 1
  done
  echo "  alive after 20s but TailscaleKit never mapped"
  xcrun simctl terminate "$UDID" "$bid" >/dev/null 2>&1
  return 1
}

# The control is expected to crash. On a Mac with Crash Reporter enabled this
# raises a "Tunnelless cannot be opened" dialog — that dialog IS the pass.
run_one "NEGATIVE CONTROL — $CONTROL_TAG framework (minos $CONTROL_MINOS) on iOS $RUNTIME_VER" \
        "$CONTROL_APP" "$CONTROL_BID"
CONTROL_RC=$?

run_one "SUBJECT — current framework (minos $DECLARED) on iOS $RUNTIME_VER" \
        "$APP" "$BID"
SUBJECT_RC=$?

echo
if [ $CONTROL_RC -eq 0 ]; then
  echo "  INCONCLUSIVE: the control LOADED on iOS $RUNTIME_VER."
  echo "  This check cannot detect a framework built above the floor, so the"
  echo "  subject's result is not evidence and is discarded."
  exit 3
elif [ $SUBJECT_RC -ne 0 ]; then
  echo "  FAIL: the app did not load TailscaleKit on iOS $RUNTIME_VER, which is"
  echo "  at or above the declared floor of $DECLARED. The floor is a false promise."
  exit 1
fi
echo "  passed — control refused by dyld, subject loaded."
echo "  The iOS floor of $DECLARED is verified at runtime, not just declared."
exit 0

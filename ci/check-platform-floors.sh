#!/bin/bash
# ci/check-platform-floors.sh — every declared platform floor must be >= the
# `minos` of the framework slice it will load.
#
# WHY THIS EXISTS
#
# Declaring a deployment target lower than the binary you embed is legal, builds
# clean, ships, and installs — then dyld refuses the framework and the app dies
# at launch on exactly the OS versions you claimed to support. Nothing in the
# toolchain objects: at most a single `ld: warning` in an otherwise green build,
# and SwiftPM does not check `platforms:` against a binaryTarget at all.
#
# This repo has already shipped it twice, and neither instance was caught by a
# build:
#
#   - macOS declared 14.0 against a slice built minos 15.6. Found by reading an
#     ld warning, fixed in app/project.yml — but the fix never reached
#     app/Project.swift (Tuist), which still said 14.0, or Package.swift.
#   - iOS declared 17.0 against a slice built minos 18.1, in every one of the
#     three places, including the build submitted to App Review.
#
# CI stayed green throughout, because CI runs current OSes where the floor never
# matters. The failure only exists on the old OS versions the floor exists to
# promise.
#
# So this compares the numbers directly, in all three declaration sites:
#
#   app/project.yml    xcodegen deploymentTarget
#   app/Project.swift  Tuist deploymentTargets
#   Package.swift      SwiftPM platforms  (what OTHER people resolve)
#
# The xcframework must be present. If it is missing this FAILS rather than
# skipping — a floor check that quietly does nothing is how the macOS fix went
# un-propagated for a week.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

XCF="vendor/TailscaleKit.xcframework"
fail=0

if [ ! -d "$XCF" ]; then
  echo "  FAIL $XCF not found. Get it with ONE of:" >&2
  echo "         bash tailscale/build-tailscalekit.sh        # build it (~5 min, needs Go)" >&2
  echo "         gh release download \"\$(grep -oE 'download/tailscalekit-[^/]+/' Package.swift \\" >&2
  echo "           | head -1 | sed 's|download/||; s|/\$||')\" \\" >&2
  echo "           --pattern 'TailscaleKit.xcframework.zip' && unzip -q TailscaleKit.xcframework.zip -d vendor/" >&2
  echo "       NOT \`make bootstrap\` — that installs xcodegen/tuist/bundler and does not fetch or build the framework." >&2
  echo "       Not skipping: an inert floor check is why the macOS floor stayed wrong in two of three files." >&2
  exit 1
fi

# Every minos in a slice, one per line. A slice can be FAT -- the simulator one
# carries x86_64 and arm64 -- and each arch has its own LC_BUILD_VERSION, so the
# arches can disagree. The previous version stopped at the first (`exit`), which
# would have read a correct arm64 floor and never looked at x86_64.
slice_minos_all() {
  local bin
  bin="$(find "$XCF/$1" -name TailscaleKit -type f 2>/dev/null | head -1)"
  [ -n "$bin" ] || return 1
  otool -l "$bin" 2>/dev/null |
    awk '/LC_BUILD_VERSION/ { f=1; next } f && /minos/ { print $2; f=0 }'
}

# The highest minos across a slice's arches: that is the number every
# declaration has to clear, because dyld refuses on whichever arch actually runs.
slice_minos() {
  slice_minos_all "$1" | sort -V | tail -1
}

IOS_MINOS="$(slice_minos ios-arm64)"
SIM_MINOS="$(slice_minos ios-arm64_x86_64-simulator)"
MAC_MINOS="$(slice_minos macos-arm64)"

[ -n "$IOS_MINOS" ] || { echo "  FAIL could not read minos from $XCF/ios-arm64" >&2; exit 1; }
[ -n "$MAC_MINOS" ] || { echo "  FAIL could not read minos from $XCF/macos-arm64" >&2; exit 1; }
# Not optional and not skipped: see the simulator-slice note below.
[ -n "$SIM_MINOS" ] || {
  echo "  FAIL could not read minos from $XCF/ios-arm64_x86_64-simulator" >&2
  echo "       The simulator slice is the one tailscale/verify-floor-runtime.sh loads to" >&2
  echo "       prove the floor. If it is missing or unreadable, that proof has no subject." >&2
  exit 1
}

echo "==> Platform floor check"
echo "  slice minos: ios-arm64 $IOS_MINOS, ios-simulator $SIM_MINOS, macos-arm64 $MAC_MINOS"
echo "  (simulator arches: $(slice_minos_all ios-arm64_x86_64-simulator | tr '\n' ' '))"

# The device and simulator slices are built by separate invocations against
# separate SDKs, and nothing but this makes them agree. They MUST, for a reason
# specific to this repo: tailscale/verify-floor-runtime.sh proves the declared
# iOS floor is real by launching the app on an OLD SIMULATOR, so the binary that
# proof exercises is the simulator slice -- while the floor that proof is taken
# to establish is the one shipped to devices. If the two slices carry different
# floors, the runtime proof does not transfer, which is exactly the trap
# REQ-V03-4 fell into once already (a proof against +2 was assumed to hold for
# +3, and did not -- the floors came from different mechanisms).
if [ "$IOS_MINOS" != "$SIM_MINOS" ]; then
  echo "  FAIL ios-arm64 is minos $IOS_MINOS but the simulator slice is $SIM_MINOS." >&2
  echo "       These come from one source and must match. While they differ, a runtime" >&2
  echo "       proof run on the simulator says nothing about the device binary." >&2
  fail=1
fi

# check <label> <declared> <required>
check() {
  local label="$1" declared="$2" required="$3"
  if [ -z "$declared" ]; then
    echo "  FAIL $label: no floor found — the declaration moved, and this check went blind" >&2
    fail=1
    return
  fi
  # Sort-based compare: lowest first, so if `declared` sorts first and differs,
  # it is below the slice minimum.
  local lowest
  lowest="$(printf '%s\n%s\n' "$declared" "$required" | sort -V | head -1)"
  if [ "$lowest" = "$required" ] || [ "$declared" = "$required" ]; then
    echo "  ok   $label declares $declared >= $required"
  else
    echo "  FAIL $label declares $declared, but the slice it loads needs $required." >&2
    echo "       This builds, ships and installs, then dyld refuses the framework at launch" >&2
    echo "       on every OS between $declared and $required." >&2
    fail=1
  fi
}

# iOS declarations cover device AND simulator builds -- there is only one
# IPHONEOS_DEPLOYMENT_TARGET -- so they must clear whichever slice is higher.
IOS_REQUIRED="$(printf '%s\n%s\n' "$IOS_MINOS" "$SIM_MINOS" | sort -V | tail -1)"

# 1. xcodegen — app/project.yml
Y_IOS="$(grep -oE '^ +iOS: *"[0-9]+(\.[0-9]+)*"' app/project.yml | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)"
Y_MAC="$(grep -oE '^ +macOS: *"[0-9]+(\.[0-9]+)*"' app/project.yml | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)"
check "app/project.yml    iOS  " "$Y_IOS" "$IOS_REQUIRED"
check "app/project.yml    macOS" "$Y_MAC" "$MAC_MINOS"

# 2. Tuist — app/Project.swift. Every occurrence, not just the first: the macOS
#    floor was wrong in all three targets here while project.yml was right.
for v in $(grep -oE 'deploymentTargets: \.iOS\("[0-9]+(\.[0-9]+)*"\)' app/Project.swift | grep -oE '[0-9]+(\.[0-9]+)*'); do
  check "app/Project.swift  iOS  " "$v" "$IOS_REQUIRED"
done
for v in $(grep -oE 'deploymentTargets: \.macOS\("[0-9]+(\.[0-9]+)*"\)' app/Project.swift | grep -oE '[0-9]+(\.[0-9]+)*'); do
  check "app/Project.swift  macOS" "$v" "$MAC_MINOS"
done

# 3. SwiftPM — Package.swift. This one is what other people resolve, so a wrong
#    floor here breaks consumers rather than us.
P_IOS="$(grep -oE '\.iOS\("[0-9]+(\.[0-9]+)*"\)' Package.swift | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)"
P_MAC="$(grep -oE '\.macOS\("[0-9]+(\.[0-9]+)*"\)' Package.swift | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)"
check "Package.swift      iOS  " "$P_IOS" "$IOS_REQUIRED"
check "Package.swift      macOS" "$P_MAC" "$MAC_MINOS"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: a declared floor is below the binary it loads. This is a launch crash" >&2
  echo "on the OS versions you are promising to support, and no build will catch it." >&2
  exit 1
fi
echo "passed"
exit 0

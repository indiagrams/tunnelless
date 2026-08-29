#!/bin/bash
# ci/check-review-notes.sh — pre-submission guard against automated App Review
# rejections.
#
# WHY THIS EXISTS
#
# Every App Review rejection this project has taken was an AUTOMATED pre-review
# scan, not a human reviewer. Both of Tunnelless 0.1.0's rejections opened with
# "This is an automated message ... An automated analysis indicates":
#
#   - com.apple.security.network.server present -> "does not appear to have
#     matching functionality"
#   - embedded WireGuard/tsnet -> "the app contains VPN functionality"
#
# Neither needed a code change. Both were answered with an explanation, and
# Apple's own message says where that explanation belongs: "add this information
# to the App Review Information section of App Store Connect."
#
# The cost of learning this after the fact is a full review cycle per rejection.
# PrivateClaw (same author, same domain) took 10 submissions to ship, and its
# notes.txt is a fossil record of that: it carries pre-emptive sections for
# NEPacketTunnelProvider, biometrics, camera, and export encryption, each added
# after a rejection. That knowledge never left one app's notes file, so
# Tunnelless repeated the VPN question anyway.
#
# So: these triggers are statically detectable from the app's own manifest. If a
# trigger is present, the explanation must already be in notes.txt BEFORE the
# first submission — not after Apple asks.
#
# This checks presence of an explanation, not its quality. It cannot know whether
# the wording will satisfy a reviewer; it only prevents submitting with nothing
# said at all.

set -uo pipefail
cd "$(dirname "$0")/.."

NOTES="fastlane/metadata/review_information/notes.txt"
fail=0; warn=0

[ -f "$NOTES" ] || { echo "error: $NOTES not found" >&2; exit 1; }
notes=$(tr '[:upper:]' '[:lower:]' < "$NOTES")

# trigger_present <description> <grep-pattern> <files...>
found() { grep -rqi "$1" "${@:2}" 2>/dev/null; }
# notes_cover <keyword>
covers() { echo "$notes" | grep -qi "$1"; }

echo "==> App Review trigger scan"

# 1. macOS sandbox server entitlement.
if found "com.apple.security.network.server" app/macOS/*.entitlements; then
  if covers "network.server"; then
    echo "  ok   network.server entitlement -> explained in notes"
  else
    echo "  FAIL network.server entitlement present, but notes.txt does not explain it." >&2
    echo "       Apple's automated scan flags this as 'no matching functionality'." >&2
    fail=1
  fi
fi

# 2. VPN / WireGuard. tsnet embeds WireGuard, which trips the VPN scan even with
#    no NetworkExtension anywhere in the project.
if found "tsnet\|TailscaleKit\|WireGuard\|NEPacketTunnelProvider" app/ Package.swift 2>/dev/null; then
  if covers "vpn"; then
    echo "  ok   embedded WireGuard/tsnet -> VPN question pre-answered in notes"
  else
    echo "  FAIL app embeds WireGuard/tsnet but notes.txt never addresses VPN." >&2
    echo "       Apple's automated scan asks: what data is collected, why, and" >&2
    echo "       is it shared. Answer all three before submitting." >&2
    fail=1
  fi
fi

# 3. Export compliance. Declaring encryption without saying which exemption
#    applies is what draws the follow-up question.
if grep -rqi "ITSAppUsesNonExemptEncryption" app/ 2>/dev/null; then
  if covers "encryption"; then
    echo "  ok   encryption declared -> notes mention it"
  else
    echo "  warn ITSAppUsesNonExemptEncryption is declared but notes.txt does not" >&2
    echo "       mention encryption. PrivateClaw was asked about this; naming the" >&2
    echo "       EAR exemption up front costs nothing." >&2
    warn=1
  fi
fi

# 4. Any claim in the notes about a plist value must match the plist. PrivateClaw
#    currently tells Apple "ITSAppUsesNonExemptEncryption is set to true" while
#    both of its plists say false — a false statement in a live submission.
# Newline-tolerant: notes are hard-wrapped prose, so the claim routinely spans a
# line break ("... is set to\nfalse in Info.plist"). grep is line-based, so the
# line-by-line form silently matched nothing here and this guard never ran --
# the exact failure it exists to catch would have sailed through.
claimed=$(tr '\n' ' ' < "$NOTES" | tr -s ' ' | grep -oiE "ITSAppUsesNonExemptEncryption is set to (true|false)" | grep -oiE "(true|false)$" | tr '[:upper:]' '[:lower:]' | head -1)
if [ -n "$claimed" ]; then
  actual=$(grep -h -A1 "ITSAppUsesNonExemptEncryption" app/*/Generated-Info.plist 2>/dev/null \
           | grep -oE "<(true|false)/>" | head -1 | tr -d '<>/')
  if [ -n "$actual" ] && [ "$claimed" != "$actual" ]; then
    echo "  FAIL notes.txt claims ITSAppUsesNonExemptEncryption is '$claimed'," >&2
    echo "       but the Info.plist says '$actual'. Do not tell App Review" >&2
    echo "       something the build does not do." >&2
    fail=1
  elif [ -n "$actual" ]; then
    echo "  ok   encryption claim in notes matches the plist ($actual)"
  fi
fi

# 5. Usage-description permissions a reviewer will see prompted.
for key in NSCameraUsageDescription NSMicrophoneUsageDescription \
           NSLocationWhenInUseUsageDescription NSLocalNetworkUsageDescription; do
  if grep -rq "$key" app/ 2>/dev/null; then
    # NSLocalNetworkUsageDescription -> "localnetwork"; also try "local network",
    # since notes are written in prose, not camel case. Matching only the camel
    # form produced a false positive against notes that did explain the prompt.
    short=$(echo "$key" | sed 's/^NS//; s/UsageDescription$//')
    spaced=$(echo "$short" | sed 's/\([a-z]\)\([A-Z]\)/\1 \2/g')
    if covers "$short" || covers "$spaced"; then
      echo "  ok   $short permission -> explained in notes"
    else
      echo "  warn $key is declared but notes.txt does not explain why the app" >&2
      echo "       asks for it. Reviewers ask about unexplained prompts." >&2
      warn=1
    fi
  fi
done

# 7. Account deletion (Guideline 5.1.1(v)). Tunnelless took this rejection on
#    macOS build 4. Unlike the scans above, NO BUILD ANSWERS IT: the app creates
#    no account, so there is nothing to add to the binary and nothing a reviewer
#    can be shown. The notes are the only durable place the answer can live -- a
#    Resolution Center reply is not, because that thread closes the moment you
#    resubmit. If the app has an interactive sign-in, say what signing in
#    creates and how each part is removed, before Apple asks again.
if found "ASWebAuthenticationSession" app/; then
  if covers "account deletion"; then
    echo "  ok   interactive sign-in -> account deletion addressed in notes"
  else
    echo "  FAIL the app signs in via ASWebAuthenticationSession, but notes.txt" >&2
    echo "       never addresses account deletion. Guideline 5.1.1(v) has already" >&2
    echo "       cost this app one review cycle, and no build change can answer it." >&2
    fail=1
  fi
fi

# 6. ASC hard limit. Exceeding it means the notes silently fail to upload.
n=$(wc -c < "$NOTES" | tr -d ' ')
if [ "$n" -gt 4000 ]; then
  echo "  FAIL notes.txt is ${n} bytes; App Store Connect caps review notes at 4000." >&2
  fail=1
elif [ "$n" -gt 3800 ]; then
  echo "  warn notes.txt is ${n}/4000 bytes — little headroom left."
  warn=1
else
  echo "  ok   notes.txt ${n}/4000 bytes"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: submitting like this invites an automated rejection and costs a" >&2
  echo "review cycle. Explain the trigger in $NOTES first." >&2
  exit 1
fi
[ "$warn" -ne 0 ] && echo "passed with warnings" || echo "passed"
exit 0

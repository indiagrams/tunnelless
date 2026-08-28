#!/bin/bash
# ci/check-demo-account.sh — verify the App Review demo tailnet is actually
# reviewable before submitting.
#
# WHY THIS EXISTS
#
# fastlane/metadata/review_information/notes.txt tells App Review:
#
#   "Browse tailnet lists the demo account's devices. Offline devices are
#    expected -- they are simply not powered on. At least one should be online."
#
# Nothing verified that. It is a promise about the runtime state of a shared
# Tailscale account, made to a reviewer who will act on it. If every peer is
# offline when they sign in, the app looks broken and the rejection is Guideline
# 2.1 (app incomplete / reviewer could not evaluate).
#
# This is the rejection class that static checks cannot reach.
# ci/check-review-notes.sh confirms an explanation EXISTS; it cannot confirm the
# explanation is TRUE. PrivateClaw's history is the warning: its 10 submissions
# were driven far more by "the reviewer could not see it work" than by anything
# in a manifest, and its notes carry whole sections
# ("WHY THERE IS NO DEMO ACCOUNT FOR PAIRING", "HOW TO REVIEW") that exist only
# because a reviewer got stuck.
#
# SETUP
#
# Needs an API access token for the DEMO account's tailnet (not the developer's
# own). Create one while signed in as the demo user:
#
#   https://login.tailscale.com/admin/settings/keys  ->  Generate access token
#   export TS_DEMO_API_KEY='tskey-api-...'
#
# Without it this warns rather than fails: an unverifiable promise is a risk, but
# it should not block a developer who has not set the token up yet.

set -uo pipefail
cd "$(dirname "$0")/.."

NOTES="fastlane/metadata/review_information/notes.txt"
# Only enforce the claim if the notes actually make it.
if ! grep -qi "at least one should be online" "$NOTES" 2>/dev/null; then
  echo "  ok   notes make no claim about online demo devices; nothing to verify"
  exit 0
fi

if [ -z "${TS_DEMO_API_KEY:-}" ]; then
  echo "  warn TS_DEMO_API_KEY is not set, so the demo tailnet was NOT checked." >&2
  echo "       notes.txt promises App Review 'at least one should be online'." >&2
  echo "       If that is false when a reviewer signs in, the app reads as broken." >&2
  echo "       Verify by hand, or see this script's header to set the token." >&2
  exit 0
fi

resp=$(curl -sS -u "${TS_DEMO_API_KEY}:" \
  "https://api.tailscale.com/api/v2/tailnet/-/devices" 2>/dev/null)

if [ -z "$resp" ] || echo "$resp" | grep -q '"message"'; then
  echo "  FAIL could not read the demo tailnet (bad or expired TS_DEMO_API_KEY?)." >&2
  echo "       ${resp:0:200}" >&2
  exit 1
fi

echo "$resp" | python3 -c '
import json, sys, datetime
d = json.load(sys.stdin)
devs = d.get("devices", [])
now = datetime.datetime.now(datetime.timezone.utc)

def seen(dev):
    ts = dev.get("lastSeen") or ""
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None

# The devices API has no reliable "online" boolean across versions, so treat
# "seen within 10 minutes" as online. A reviewer signing in now needs a peer that
# is up now, not one that was up last week.
fresh = []
for x in devs:
    t = seen(x)
    if t and (now - t).total_seconds() < 600:
        fresh.append((x.get("hostname", "?"), int((now - t).total_seconds())))

print(f"  demo tailnet: {len(devs)} device(s), {len(fresh)} online in the last 10 min")
for h, age in sorted(fresh, key=lambda y: y[1])[:5]:
    print(f"    online: {h} (seen {age}s ago)")

if not devs:
    print("  FAIL the demo tailnet has NO devices. A reviewer will see an empty list",
          file=sys.stderr)
    print("       and the app will look broken.", file=sys.stderr)
    sys.exit(1)
if not fresh:
    print("  FAIL no demo device has been seen in the last 10 minutes, but notes.txt",
          file=sys.stderr)
    print("       promises App Review at least one will be online. Bring one up", file=sys.stderr)
    print("       before submitting, or change the claim in notes.txt.", file=sys.stderr)
    sys.exit(1)
print("  ok   the claim in notes.txt holds")
'

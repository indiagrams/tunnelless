#!/usr/bin/env bash
#
# FORK-OWNED GUARD (see AGENTS.md "Accepted divergence: fork-owned preflight
# checks").
#
# Refuse to cut a release tag on a commit that origin/main does not contain.
#
# WHY THIS EXISTS
#
# The release tag names a COMMIT, and for an app tag that commit is what gets
# built and shipped. It is also what a SwiftPM consumer resolves -- but only
# while the tag is SwiftPM-visible. Since RELEASE_TAG_PREFIX=app/v (backlog
# 999.2) the app tags are prefixed out of SwiftPM's namespace, so the double duty
# applies to bare `X.Y.Z` package tags rather than to every ship. The guard below
# is unchanged either way: a release must come from a commit origin/main
# contains, because only main's required checks verify that Package.swift's
# declared platforms match the xcframework it actually pins -- and never anything
# sitting in the local vendor/ directory.
#
# main's branch protection requires the six `app (...)` jobs. Those jobs fetch
# the xcframework that Package.swift PINS and then run ci/check-platform-floors.sh
# against it, so a commit contained in main has had its declared floors checked
# against the asset it actually pins. A commit that is not contained in main has
# had no such check.
#
# This is the guard that was missing when tags v0.0.1+1, 0.1.0 and v0.1.0+1..+5
# were cut
# declaring iOS 17 / macOS 14 while pinning an xcframework whose slices were
# built at 18.1 / 15.6. SwiftPM resolves that happily -- the checksum is genuine
# -- and dyld then refuses the framework at launch on iOS 17.0-18.0 and macOS
# 14.0-15.5. See .planning/v0.2-MILESTONE-AUDIT.md, BLOCKER-1.
#
# Escape hatch: ALLOW_UNMERGED_RELEASE=1 make ship
# Deliberately an env var and not a flag -- it should be awkward and it should
# appear in the shell history of whoever used it.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ "${ALLOW_UNMERGED_RELEASE:-0}" = "1" ]; then
  echo "  WARN ALLOW_UNMERGED_RELEASE=1 -- shipping a commit origin/main may not contain."
  echo "       The tag you push comes from a commit whose Package.swift nothing verified."
  exit 0
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "  FAIL not a git repository" >&2
  exit 1
fi

# Refresh origin/main. A stale ref would let a commit look unmerged when it is
# merged, or -- worse -- merged when main has moved on.
if ! git fetch -q origin main 2>/dev/null; then
  echo "  FAIL could not fetch origin/main. Releases are gated on it; refusing to guess." >&2
  exit 1
fi

HEAD_SHA="$(git rev-parse HEAD)"
if git merge-base --is-ancestor "$HEAD_SHA" origin/main 2>/dev/null; then
  echo "  ok   HEAD ${HEAD_SHA:0:8} is contained in origin/main"

  # ── W-1: say out loud what else this tag does ──────────────────────────────
  # The `v*` tag is ALSO the SwiftPM version adopters resolve. That coupling has
  # already caused one incident: e166466 bumped MARKETING_VERSION for an App
  # Store submission and thereby published a new package version. Nothing in
  # that commit mentioned SwiftPM, and nobody decided to publish a package.
  #
  # This gates nothing -- main's required `app (...)` checks already verify that
  # the asset Package.swift pins really has the floors it declares. What was
  # missing is that the side effect was SILENT. Now it is stated, at the moment
  # it happens, to the person who can still stop.
  PKG_TAG="$(grep -oE 'download/tailscalekit-[^/]+/' Package.swift 2>/dev/null | head -1 | sed 's|download/||; s|/$||')"
  PKG_IOS="$(grep -oE '\.iOS\((\.v[0-9]+|"[0-9.]+")\)' Package.swift 2>/dev/null | head -1)"
  PKG_MAC="$(grep -oE '\.macOS\((\.v[0-9]+|"[0-9.]+")\)' Package.swift 2>/dev/null | head -1)"
  # Whether this tag is ALSO a package version now depends on the prefix.
  # SwiftPM only claims tags that parse as a version, so anything with a
  # non-version prefix (app/v...) is invisible to it -- measured, see 999.2.
  RELEASE_TAG_PREFIX="${RELEASE_TAG_PREFIX-v}"
  if [ -z "$RELEASE_TAG_PREFIX" ] || [ "$RELEASE_TAG_PREFIX" = "v" ]; then
    echo "  note This tag is ALSO a SwiftPM package version."
    echo "       Adopters resolving this repo get Package.swift as it stands at ${HEAD_SHA:0:8}:"
    echo "         pins     ${PKG_TAG:-<none found>}"
    echo "         declares ${PKG_IOS:-?} ${PKG_MAC:-?}"
    echo "       Bumping MARKETING_VERSION for the App Store publishes a package"
    echo "       version too. That is correct only if the above is what you want"
    echo "       adopters to resolve. See .planning/v0.2-MILESTONE-AUDIT.md, W-1."
  else
    echo "  note This tag is an APP release only (prefix '${RELEASE_TAG_PREFIX}')."
    echo "       SwiftPM ignores tags that do not parse as a version, so this ship"
    echo "       publishes NO package version — adopters stay where they are until"
    echo "       somebody cuts a bare X.Y.Z tag on purpose. That separation is"
    echo "       backlog 999.2; W-1's silent-publish incident cannot recur here."
    echo "       Package.swift at ${HEAD_SHA:0:8} pins ${PKG_TAG:-<none found>}, declares ${PKG_IOS:-?} ${PKG_MAC:-?}."
  fi
  exit 0
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
cat >&2 <<MSG
  FAIL HEAD ${HEAD_SHA:0:8} (${BRANCH}) is NOT contained in origin/main.

       The tag this would push names this commit, and what gets built and
       shipped is decided by it -- its declared platforms and its pinned
       xcframework URL. Only main's required checks verify that the pinned
       asset's actual floors match what Package.swift declares.

       Open a PR and merge it, then ship from main.
       Override (and own the consequence): ALLOW_UNMERGED_RELEASE=1 make ship
MSG
exit 1

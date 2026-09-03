#!/usr/bin/env bash
#
# ci/check-patch-registry.sh — FORK-OWNED GUARD (AGENTS.md "Accepted divergence").
#
# Every patch this repo carries against upstream must have a row in
# tailscale/patches/REGISTRY, and every row must still describe something
# carried. Both directions, on every PR.
#
# WHY THIS EXISTS (audit W-5)
#
# The registry already existed, and so did a completeness check — but it lived
# inside tailscale-upstream-watch.yml, which is `schedule` + `workflow_dispatch`
# only. So a PR that added an unwatched patch merged clean and the complaint
# arrived up to SEVEN DAYS later, addressed to whoever happened to read the
# Monday issue. A guard that fires a week after the mistake is a report, not a
# gate.
#
# It was also blind in a specific way: it enumerated `tailscale/patches/*.patch`
# and nothing else. The Bus-guard patch is applied INLINE by
# build-tailscalekit.sh against the Go module cache — there is no .patch file for
# it — so it was watched only because somebody hand-wrote its `@` row. A second
# inline patch would have been carried with nothing to notice it.
#
# Inline patches are found here by their marker:
#
#     # PATCH-REGISTRY: @some-id
#     SOME_PATH="$(go env GOMODCACHE)/..."
#
# and the count of markers is required to equal the count of module-cache targets
# the script derives. That is what makes a NEW inline patch impossible to add
# silently: write to the module cache without a marker and the counts disagree.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REGISTRY="tailscale/patches/REGISTRY"
BUILDER="tailscale/build-tailscalekit.sh"
fail=0

[ -f "$REGISTRY" ] || { echo "  FAIL $REGISTRY not found — the registry this guard reads is gone" >&2; exit 1; }
[ -f "$BUILDER" ]  || { echo "  FAIL $BUILDER not found" >&2; exit 1; }

# Registry ids, comments and blanks stripped.
# sed, not `tr -d '[:space:]'`: tr would strip the NEWLINES too and collapse
# every row into one string, making each has_row lookup fail. sed is line-wise.
ROW_IDS="$(grep -vE '^[[:space:]]*(#|$)' "$REGISTRY" | cut -d'|' -f1 | sed 's/[[:space:]]//g' | grep -v '^$')"
[ -n "$ROW_IDS" ] || { echo "  FAIL $REGISTRY has no rows — this guard would pass vacuously" >&2; exit 1; }

echo "==> Patch registry check"
echo "  rows: $(echo "$ROW_IDS" | tr '\n' ' ')"

has_row() {
  printf '%s\n' "$ROW_IDS" | grep -qxF "$1"
}

# 1. Every .patch file on disk has a row.
PATCH_FILES=""
for f in tailscale/patches/*.patch; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  PATCH_FILES="$PATCH_FILES$b"$'\n'
  if has_row "$b"; then
    echo "  ok   $b has a row"
  else
    echo "  FAIL $b is carried but has no row in $REGISTRY." >&2
    echo "       Add one, or it retires only when somebody remembers." >&2
    fail=1
  fi
done

# 2. Every inline patch marker has a row.
MARKER_IDS="$(grep -oE '^[[:space:]]*#[[:space:]]*PATCH-REGISTRY:[[:space:]]*@[A-Za-z0-9._-]+' "$BUILDER" \
                | grep -oE '@[A-Za-z0-9._-]+' || true)"
for id in $MARKER_IDS; do
  if has_row "$id"; then
    echo "  ok   $id (inline) has a row"
  else
    echo "  FAIL $BUILDER applies inline patch $id, which has no row in $REGISTRY." >&2
    fail=1
  fi
done

# 3. Every module-cache target the builder derives is marked. This is the half
#    that makes a NEW inline patch impossible to add unnoticed: writing into the
#    module cache without a marker makes these counts disagree.
TARGETS=$(grep -cE '\$\(go env GOMODCACHE\)' "$BUILDER" || true)
MARKERS=$(printf '%s\n' "$MARKER_IDS" | grep -c '@' || true)
if [ "$TARGETS" -ne "$MARKERS" ]; then
  echo "  FAIL $BUILDER derives $TARGETS module-cache path(s) but carries $MARKERS" >&2
  echo "       '# PATCH-REGISTRY: @id' marker(s). Every inline patch needs one," >&2
  echo "       or it is carried with nothing watching it (W-5)." >&2
  fail=1
else
  echo "  ok   $TARGETS module-cache target(s), $MARKERS marker(s)"
fi

# 4. No stale rows. A row for a patch that was deleted makes the weekly report
#    describe a patch nobody carries, which is how a registry quietly stops
#    meaning anything.
while IFS= read -r id; do
  [ -n "$id" ] || continue
  case "$id" in
    @*)
      printf '%s\n' "$MARKER_IDS" | grep -qxF "$id" && continue
      echo "  FAIL $REGISTRY has a row for inline patch $id, but $BUILDER has no" >&2
      echo "       '# PATCH-REGISTRY: $id' marker. Delete the row, or restore the patch." >&2
      fail=1
      ;;
    *)
      [ -f "tailscale/patches/$id" ] && continue
      echo "  FAIL $REGISTRY has a row for $id, which is not in tailscale/patches/." >&2
      echo "       Retired patches lose their row — see the header of $REGISTRY." >&2
      fail=1
      ;;
  esac
done <<< "$ROW_IDS"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: the patch registry and the patches actually carried are out of step." >&2
  exit 1
fi
echo "passed"
exit 0

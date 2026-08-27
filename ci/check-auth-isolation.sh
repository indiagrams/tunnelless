#!/bin/bash
# ci/check-auth-isolation.sh — guard the macOS sign-in crash fix.
#
# WHAT THIS CATCHES
#
# ASWebAuthenticationSession's completion handler is NOT delivered on the main
# thread on macOS; it arrives on the XPC reply queue of Safari's launch agent.
# `ASWebAuthenticationSessionCompletionHandler` is a plain ObjC block with no
# NS_SWIFT_SENDABLE, so under Swift 6 a closure literal written inside a
# @MainActor type INHERITS that isolation and the compiler plants an executor
# precondition in the block thunk. It trips the moment the block runs off-main:
#
#   swift_task_isCurrentExecutorWithFlags -> dispatch_assert_queue
#     -> EXC_BREAKPOINT (SIGTRAP)
#
# killing the app exactly when sign-in succeeds. See TAILSCALE.md, "The six
# things that will bite you" #6.
#
# WHY A GREP AND NOT A TEST
#
# The compiler will not catch this. Touching main-actor state from a closure
# that inherited main-actor isolation is legal, so the broken form builds clean
# and fails only at runtime, only on macOS, and only after a real login — which
# no unit test can reach without a Tailscale account and an interactive sheet.
# The one reliable signal is structural: WHERE the closure is written.
#
# So this asserts the session is constructed inside a `nonisolated` function and
# nowhere else. If someone inlines it back into `present` (or any other
# @MainActor member) it compiles, ships, and crashes — this check is what stops
# that.

set -euo pipefail
cd "$(dirname "$0")/.."

FILE="app/Shared/Tailscale/WebAuthLogin.swift"
fail() { echo "error: $*" >&2; exit 1; }

[ -f "$FILE" ] || fail "$FILE not found (renamed? update this check)"

# 1. The session must be constructed exactly once.
count=$(grep -c "ASWebAuthenticationSession(url:" "$FILE" || true)
[ "$count" -eq 1 ] || fail \
  "expected exactly 1 ASWebAuthenticationSession(url:...) construction in $FILE, found $count.
   Each one needs its completion handler in a nonisolated context — see TAILSCALE.md #6."

# 2. It must live inside a `nonisolated` function.
#    Walk back from the construction to the nearest enclosing func declaration.
ctor_line=$(grep -n "ASWebAuthenticationSession(url:" "$FILE" | cut -d: -f1)
enclosing=$(head -n "$ctor_line" "$FILE" | grep -nE "^[[:space:]]*(private |public |internal )*(nonisolated )?(static )?func " | tail -1)
[ -n "$enclosing" ] || fail "could not find the function enclosing the session construction in $FILE"

echo "$enclosing" | grep -q "nonisolated" || fail \
  "the ASWebAuthenticationSession completion handler is NOT in a nonisolated function.

   Enclosing declaration:
     ${enclosing#*:}

   A closure literal written inside a @MainActor type inherits that isolation, and
   AuthenticationServices calls it off-main on macOS -> EXC_BREAKPOINT at sign-in.
   This compiles cleanly and crashes only at runtime. Keep the construction in a
   nonisolated function and hop to the main actor for state.
   See TAILSCALE.md, 'The six things that will bite you' #6."

echo "ok: ASWebAuthenticationSession completion handler is in a nonisolated context"

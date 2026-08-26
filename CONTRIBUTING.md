# Contributing

Thanks for looking. This is a **reference implementation**, not a library, and
that shapes what changes make sense here.

## What this project is trying to be

A small, readable, working demonstration that an iOS or macOS app can join a
Tailscale network in userspace — no `NEPacketTunnelProvider`, no NetworkExtension
entitlement, no VPN profile. The valuable parts are:

1. `tailscale/build-tailscalekit.sh` + `validate-xcframework.sh` — the pipeline
   that turns libtailscale into an xcframework Apple will actually accept.
2. `app/Shared/Tailscale/` — roughly 250 lines of Swift showing the node
   lifecycle and the workarounds that are not obvious.

It is pinned to a known-good Tailscale version. Read it, copy from it, don't
depend on it.

## The scope test

> Does this change make the Tailscale integration easier to understand, build,
> or trust?

- **Yes** → in scope. Please open an issue or PR.
- **No** → probably out of scope, however good the idea is.

**In scope:** fixes to the xcframework pipeline; new validator checks for things
Apple rejects; clearer `WHY:` comments; corrections to `TAILSCALE.md`; making the
demo work on a platform or OS version where it currently doesn't; reducing the
Swift needed to integrate.

**Out of scope:** turning this into a distributable Swift package; adding app
features unrelated to Tailscale; networking/persistence/auth/analytics libraries;
UI framework opinions. Those belong in *your* app, not in a reference.

The release-engineering scaffolding (signing, fastlane, TestFlight, App Store) comes
from [apple-shipkit](https://github.com/indiagrams/apple-shipkit). Improvements to
it belong upstream there, not here — see "Relationship to apple-shipkit" in
[AGENTS.md](AGENTS.md).

## Before you open a PR

```bash
# 1. Get the xcframework (see README "Adding this to an existing app")
gh release download tailscalekit-v1.102.3 -p 'TailscaleKit.xcframework.zip' -D /tmp
unzip -q /tmp/TailscaleKit.xcframework.zip -d vendor/

# 2. Generate + build + lint
cd app && xcodegen generate && cd ..
make check
make format-check
```

If you touched `app/macOS/*.entitlements`, also verify against a **signed** build —
the App Sandbox is not enforced on unsigned builds, so an unsigned build can pass
while the signed one fails to start. The command is in
[TAILSCALE.md](TAILSCALE.md#macos-the-app-sandbox-needs-networkserver).

If you touched a dependency or target setting, change **both** `app/project.yml`
(XcodeGen) and `app/Project.swift` (Tuist) — the CI matrix builds both and will
fail on drift.

## Conventions

- **Branches**: `feat/...`, `fix/...`, `docs/...`, `refactor/...`, `chore/...`, `test/...`
- **Commits**: [Conventional Commits](https://www.conventionalcommits.org/). The
  body should explain root cause, fix mechanism, and how you validated it.
- **CHANGELOG.md**: add an entry under `[Unreleased]` for anything user-visible.
- **PRs**: say what changed, why, and what you ran to verify. Tables beat prose.
- **Merges**: squash.

## Reporting a bug

Include the platform (iOS device / iOS Simulator / macOS), whether the build was
signed, the `tailscale.com` version from `vendor/libtailscale/go.mod`, and the
relevant `[TailscaleKit]` log lines. `tailscale_start` / `tailscale_up` return
codes are especially useful — `res=-1` with no further output usually means the
node never got far enough to log anything.

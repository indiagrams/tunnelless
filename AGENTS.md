# AGENTS.md

> Context for AI coding agents (Claude Code, Cursor, Codex, Aider, Gemini CLI, Devin, Windsurf, Junie, etc.).
> Read this before making any changes to the repo. README.md is for humans; this file is for you.

## What this project is

A **reference implementation**: an iOS + macOS app that joins a Tailscale network
in userspace by linking `tsnet` as a library, with no `NEPacketTunnelProvider`,
no NetworkExtension entitlement, and no VPN profile. Traffic reaches peers
through the SOCKS5 proxy tsnet exposes on loopback.

It is **not a library and not a template**. It is pinned to a known-good Tailscale
version and meant to be read and copied from, not depended on. The demo app is
deliberately small; the valuable parts are the xcframework build pipeline and
roughly 250 lines of Swift.

The release-engineering scaffolding underneath (signing, CI, fastlane, TestFlight)
comes from [apple-shipkit](https://github.com/indiagrams/apple-shipkit), which is
this repo's upstream. See "Relationship to apple-shipkit" below.

| Path | What |
|---|---|
| `app/Shared/Tailscale/TailscaleNodeManager.swift` | Node lifecycle. Every `WHY:` comment is a bug that cost real time — do not "clean them up". |
| `app/Shared/Tailscale/WebAuthLogin.swift` | Interactive browser login. |
| `app/Shared/ContentView.swift` | Demo UI: connect, show tailnet IP + SOCKS5 proxy, sign out. |
| `tailscale/build-tailscalekit.sh` | Builds all three slices, injects privacy manifests, re-signs. |
| `tailscale/validate-xcframework.sh` | Asserts the things Apple rejects for. Run before any upload. |
| `tailscale/PrivacyInfo.xcprivacy` | The manifest injected into both iOS slices. |
| `vendor/libtailscale` | Submodule, pinned to a known-good commit. |

`TAILSCALE.md` is the deep reference — read it before touching anything under
`app/Shared/Tailscale/` or `tailscale/`.

## Getting the xcframework

`vendor/TailscaleKit.xcframework` is **gitignored** (~94 MB). Nothing builds
without it. Two ways to get it:

```bash
# A. Download the prebuilt release (what CI does, ~20 s)
gh release download tailscalekit-v1.102.3 -p 'TailscaleKit.xcframework.zip' -D /tmp
unzip -q /tmp/TailscaleKit.xcframework.zip -d vendor/

# B. Build it (~5 min, needs Go + Xcode)
git submodule update --init --recursive
bash tailscale/build-tailscalekit.sh
bash tailscale/validate-xcframework.sh
```

Then generate and build:

```bash
cd app && xcodegen generate && cd ..
make check
```

## Critical invariants (do NOT break)

### Tailscale-specific

These are load-bearing. Each corresponds to a failure that has actually happened;
`TAILSCALE.md` has the full account.

| Rule | Why |
|---|---|
| Never hardcode the `tailscale.com` version | It must be read from `vendor/libtailscale/go.mod`. A hardcoded `v1.96.4` once meant both patch steps took their "not found" branch and an xcframework shipped **without its crash fix**, silently. |
| Never `sed -i` against the Go module cache | The cache is read-only; `sed -i` fails with `Permission denied` while the build continues. Rewrite with `python3`, then assert the patched symbol exists. |
| Never hand-roll `xcodebuild` for the xcframework | Use `build-tailscalekit.sh`, then `validate-xcframework.sh`. Bypassing them shipped an xcframework missing the crash guard and all privacy manifests. |
| Never trust a release tag's date | `v1.96.4` was tagged four days *after* the PR it lacks was merged — the release branch was cut earlier. `curl` the source at the tag and grep. |
| Never pipe a build to `tail` | `cmd \| tail -35` reports *tail's* exit code, so a failed build looks like exit 0. Redirect to a file, capture `$?`, then grep. |
| Cache `loopback()` before calling `up()` | `up()` is a blocking C call that holds the actor for the whole login flow. |
| Weak-capture the node in the up-task | A strong capture keeps the Go server alive past a reset, holding the state-directory lock. |
| Sign-out must delete the state directory | Otherwise tsnet reuses persisted auth and never re-logs `AuthURL is`. |

### Both project manifests must stay in sync

`app/project.yml` (XcodeGen) and `app/Project.swift` (Tuist) are 1:1 equivalents,
and the CI matrix builds both. When you touch a dependency or target setting,
change it in **both**. A missing `.xcframework(...)` in the Tuist manifest
compiles as `no such module 'TailscaleKit'`, which reads like a missing binary
rather than manifest drift.

### Template-owned paths

`bin/`, `ci/`, `.github/workflows/`, `Makefile`, and `fastlane/Fastfile` come from
apple-shipkit. Editing them causes conflicts on every upstream sync. Prefer
`fastlane/Fastfile.local` (fork-owned; the template imports it at EOF) and repo
variables over edits. The one accepted exception is documented under
"Accepted divergence" below.

Do **not** commit secrets. `.bootstrap.env` and `.p8` files are gitignored; real
values live in GitHub Secrets and `~/.config/secrets/`.

## Where code goes

| What | Where |
|---|---|
| Cross-platform app code | `app/Shared/` |
| Tailscale integration | `app/Shared/Tailscale/` |
| iOS-only resources | `app/iOS/` |
| macOS-only resources | `app/macOS/` |
| Unit tests | `app/Tests/` (iOS), `app/MacOSTests/` (macOS) |
| UI / screenshot tests | `app/UITests/`, `app/MacOSUITests/` |
| Accessibility identifiers | `app/Shared/AccessibilityIdentifiers.swift` |
| xcframework build tooling | `tailscale/` — deliberately **not** `ci/`, which is template-owned |

## Daily workflow

| Task | Command |
|---|---|
| Local build, no signing (same signal CI runs) | `make check` |
| Auto-fix formatting | `make format` |
| Lint without writing | `make format-check` |
| Regenerate the Xcode project | `cd app && xcodegen generate` |
| Validate the xcframework | `bash tailscale/validate-xcframework.sh` |

Test selectors: leaf SwiftUI elements only (Text/Button/Image/TextField/Toggle/Picker).
`VStack`/`HStack`/`ZStack` without `.accessibilityElement(children: .contain)` do
not surface in XCUITest queries.

## Commit + PR conventions

- **Branch naming**: `feat/...`, `fix/...`, `docs/...`, `refactor/...`, `chore/...`, `test/...`
- **Commit messages**: Conventional commits (`feat(scope): short summary`). The body
  explains root cause, fix mechanism, and validation. Multi-paragraph is normal.
- **CHANGELOG.md**: append to `[Unreleased]` under `### Added` / `### Fixed` / `### Changed`
  on every user-visible change.
- **PR descriptions**: what changed, why, validation. Tables beat prose.
- **Merges**: squash.

## Relationship to apple-shipkit

This repo is a fork of [`indiagrams/apple-shipkit`](https://github.com/indiagrams/apple-shipkit).
To pull in upstream template fixes:

```bash
git remote add upstream https://github.com/indiagrams/apple-shipkit.git  # one-time
git fetch upstream
git merge upstream/main
```

`bin/rename.sh` rewrote `indiagrams/apple-shipkit` to this repo's slug when the
fork was created. That is correct for a fork that becomes its own template, but
wrong here — this project credits apple-shipkit as upstream. References meaning
"the upstream template" have been restored; references meaning "this repository"
(such as where to file an issue) point here.

For the scaffolding's own documentation — bootstrapping a fork, the release
pipeline, TestFlight, App Store submission, Tuist migration — see
[apple-shipkit](https://github.com/indiagrams/apple-shipkit). Those docs were
removed from this repo rather than maintained in duplicate; a visitor here is
looking for Tailscale, not release engineering.

## Maintenance automation

Four workflows keep this pinned-by-design project from drifting silently. None
of them publishes anything without a human merge.

| Workflow | Trigger | What it does |
|---|---|---|
| `tailscale-upstream-watch.yml` | Mondays 06:17 UTC | Compares the pinned `tailscale.com` version against the latest stable release, and checks whether the patches `build-tailscalekit.sh` carries have merged upstream. Maintains **one** self-updating issue; closes it when there is nothing to do. |
| `tailscale-bump.yml` | manual | Prepares a bump: edits `go.mod` in the libtailscale fork, verifies the bindings compile, rebuilds and validates the xcframework, builds the app on both generators, then opens a PR. Never merges. |
| `release-xcframework.yml` | push to `main` touching `vendor/libtailscale` | Builds, validates, and publishes the release for the pinned version. Idempotent — skips if the tag exists. |
| `macos-sandbox-check.yml` | PRs touching macOS/Tailscale paths | Signs ad-hoc, launches, and asserts `tailscale_start ... res=0`. The only job that exercises an enforced App Sandbox. |

Dependabot additionally watches `gitsubmodule`, so the submodule pin cannot fall
behind the fork unnoticed. It does **not** see new `tailscale.com` releases —
those land in the fork's `go.mod`, one repo upstream, which is what
`tailscale-upstream-watch.yml` is for.

**`tailscale-bump.yml` needs a credential.** Pushing to the libtailscale fork is
a cross-repo write that `GITHUB_TOKEN` cannot do. Store a fine-grained PAT with
`contents:write` on that repo as `LIBTAILSCALE_PAT`. Without it the workflow
stops immediately and says so rather than half-finishing; `dry_run: true` builds
and validates without needing it.

**Why bumping is not one line.** The version lives in a different repository, and
that fork carries local patches — including the `[TailscaleKit]` NSLog tracing
(`b50094a`) that `macos-sandbox-check.yml` greps for. The bump workflow asserts
that patch survived, because losing it would silently blind the sandbox guard
rather than fail.

## Fork conventions

### Accepted divergence: the TailscaleKit fetch step in `pr.yml`

`.github/workflows/pr.yml` is template-owned, and this fork edits it anyway —
one step, `fetch TailscaleKit.xcframework`, plus `submodules: true` on the
`app` job's checkout.

**Why it can't live anywhere else.** `pr.yml` has no fork-owned seam: the `app`
job goes straight from "regenerate Xcode project" to "build iOS device", with no
`local-check.sh` hook to attach to, and nothing in `Fastfile.local` runs during a
PR check. Without a fetch step, every app job fails at
`There is no XCFramework found`.

**Cost.** `git merge upstream/main` will conflict on `pr.yml` whenever
apple-shipkit touches the `app` job. The step is self-contained and marked
`FORK-OWNED STEP` in-file, so the resolution is always "keep both".

**Invariants it respects:** no hardcoded `APP_NAME`/`BUNDLE_ID`, no hardcoded
Tailscale version (derived from `vendor/libtailscale/go.mod`), and the release
slug is overridable via the `TSKIT_RELEASE_REPO` repo variable.

### Stale pointers in template-owned files

Some template-owned scripts mention docs that were removed here (for example
`bin/lib/bootstrap.rb` refers to `docs/BOOTSTRAP.md`). These are message strings
and comments with no functional effect. They are deliberately left unedited:
rewriting them would deepen divergence from upstream for no behavioural gain.
Follow such pointers to
[apple-shipkit](https://github.com/indiagrams/apple-shipkit) instead.

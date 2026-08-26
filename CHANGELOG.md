# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Note on history.** This repository began as a fork of
> [apple-shipkit](https://github.com/indiagrams/apple-shipkit) and inherited that
> project's changelog. Those entries described apple-shipkit's releases and
> referenced its PR numbers, which do not exist here, so they were removed rather
> than left to read as this project's history. For the release engineering
> scaffolding's own changelog, see
> [apple-shipkit's CHANGELOG](https://github.com/indiagrams/apple-shipkit/blob/main/CHANGELOG.md).

## [Unreleased]

### Added

- `TailscaleKit.xcframework` fetch step in `.github/workflows/pr.yml`, plus
  `submodules: true` on the `app` job's checkout. The xcframework is gitignored
  (~94 MB), so every `app` matrix cell previously failed at
  `There is no XCFramework found`. CI now downloads the published release asset
  (~20 s, no Go toolchain needed) and runs `tailscale/validate-xcframework.sh`
  against it. The release tag is derived from `vendor/libtailscale/go.mod` rather
  than hardcoded, so the binary CI links always matches the pinned submodule.
- `.xcframework` dependency declarations for both app targets in
  `app/Project.swift`. `app/project.yml` (XcodeGen) had always declared them;
  the Tuist manifest had not, so the Tuist cells failed with
  `no such module 'TailscaleKit'` even once the binary was present.

### Changed

- Renamed the app from `TailnetDemo` to **Tunnelless**, and the bundle
  identifier from `com.indiagram.tailnetdemo` to `com.indiagram.tunnelless`, in
  preparation for an App Store release under Indiagram LLC. The old name put
  Tailscale's coined term "tailnet" in the product name; the new one names what
  the app actually demonstrates — reaching a tailnet with no tunnel interface,
  no `NEPacketTunnelProvider`, and no VPN profile. Tailscale is now referenced
  only as a compatibility statement in store copy, never in the app's name.
  `.github/workflows/` was deliberately left untouched: it already resolves the
  name through `vars.APP_NAME`, so the GitHub repo variable carries the change
  and the template-owned workflows stay conflict-free on upstream sync.
- `.gitignore` now covers `vendor/README.txt` and
  `vendor/LICENSE-tailscale-BSD-3-Clause.txt`, which ship inside
  `TailscaleKit.xcframework.zip` and land in `vendor/` on every unzip.

### Fixed

- Ran `make format` over `ContentView.swift`, `TailscaleNodeManager.swift`, and
  `WebAuthLogin.swift`. These were written after the last formatter run, so the
  required `swiftformat` check had failed on every commit since the repo was
  created.

## [0.1.0] - 2026-08-26

First working reference implementation: an iOS/macOS app that joins a Tailscale
network in userspace via `tsnet`, with no `NEPacketTunnelProvider`, no
NetworkExtension entitlement, and no VPN profile. Verified on a physical iPhone
(iOS 26.5) and on macOS.

### Added

- `app/Shared/Tailscale/TailscaleNodeManager.swift` — the node lifecycle, including
  the `LogPipeLogger` workaround for `LocalAPIClient` hanging indefinitely on
  physical iOS devices.
- `app/Shared/Tailscale/WebAuthLogin.swift` — interactive browser login, dismissed
  by observing the node reaching `Running` rather than by browser redirect.
- `tailscale/build-tailscalekit.sh` — builds all three slices, injects
  `PrivacyInfo.xcprivacy` into both iOS slices, and re-signs. Reads the
  `tailscale.com` version from `go.mod`; hard-fails if a patch does not apply.
- `tailscale/validate-xcframework.sh` — six checks for the failures Apple rejects
  at upload rather than at build: missing privacy manifests (ITMS-91053), symlinks
  in iOS slices, and a vendor team ID left in the signature
  ([tailscale#15802](https://github.com/tailscale/tailscale/issues/15802)).
- Release `tailscalekit-v1.102.3` — a prebuilt, validated xcframework. Upstream
  libtailscale ships no prebuilt binary.
- `-autoconnect` launch argument for the demo app.
- `Package.swift` — distributes the xcframework as a SwiftPM `.binaryTarget`,
  pinned by SHA-256 so a moved or rewritten release asset fails resolution
  instead of silently swapping the binary.
- `tailscale/verify-package-manifest.sh` + `swiftpm-manifest-check.yml` — assert
  the pinned URL names the release for `tailscale/TAILSCALE_VERSION` and that
  the checksum matches what is actually published. Without this the manifest
  could go stale on a bump and SwiftPM would keep resolving the old binary
  while every other check stayed green.

**Versioning.** Package versions are independent of the Tailscale version they
vend: this tag carries `tailscale.com v1.102.3`, but `0.2.0` may carry a
different one — or the same one with only packaging changes. `0.x` is
deliberate; the packaging is new and may change shape. Two tag series live in
this repo: `0.x` are SwiftPM package versions (what `from:` resolves), and
`tailscalekit-vX.Y.Z` are xcframework binary releases (what the package
downloads).

The inherited apple-shipkit tags (`v1.0.0`–`v1.9.0`) were deleted from the
working clone before tagging; they were never pushed. They point at
apple-shipkit trees with no `Package.swift`, so publishing them would have made
`from:` resolve to an unrelated project.

### Upstream contributions

- [tailscale#19052](https://github.com/tailscale/tailscale/pull/19052) — darwin
  `os.Executable` fallback. Merged; shipped in v1.98.0.
- [tailscale#20985](https://github.com/tailscale/tailscale/pull/20985) — `Close()`
  nil-deref when `Start()` failed early, which surfaces through TailscaleKit as
  `EXC_BAD_ACCESS` and masks the real startup error. Open.

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

## [0.1.0] - 2026-08-26

First App Store release. Tunnelless joins a Tailscale network from inside the
app — no VPN profile, no NetworkExtension entitlement — and gives that network a
face: a peer dashboard, saved services you can open through the node's SOCKS5
proxy, and Shortcuts actions.

### Added

- **App Store screenshot capture that reaches the screens worth showing.** A
  Simulator has no Tailscale account, so capture previously photographed an idle
  "not connected" screen and never opened the peer list at all. `DemoData`,
  gated on the `-UITestDemoData` launch argument, presents the connected state
  and a representative tailnet through the *same* views and row rendering — only
  the source of the rows differs. Produces 8 screenshots: iPhone 6.7" and iPad
  12.9", home and tailnet, light and dark, at Apple's exact slot dimensions
  (1290×2796 and 2048×2732).
- Memberwise initializer on `TailnetPeer`, for fixtures and demo data.
- **Saved services.** Bookmark things on your tailnet — a NAS page, an internal
  API, a router — and open them from the app. This is the point of a userspace
  node: with no VPN profile, no other app on the device can reach these
  addresses, so this app has to be the client.
- **Save as service from a peer row.** Long-press any device in the tailnet list
  to bookmark it, pre-filled with its MagicDNS name. The dashboard tells you a
  machine is reachable; this turns it into something you can open.
- `ServiceReaderView` — fetches through the SOCKS5 proxy and renders the
  response: JSON pretty-printed with sorted keys, HTML reduced to its text,
  plain text as-is, anything else described. Deliberately a reader and not a web
  view: `WKWebView` cannot use a SOCKS proxy, and a custom scheme handler would
  mean proxying every subresource, redirect, and cookie by hand while WebSockets
  still failed.
- `SOCKS5Client.fetch(...)` returning a parsed status, headers, and body.
- `ServiceRenderingTests` — 16 tests over HTTP parsing and rendering, the layer
  where a saved service degrades silently rather than visibly.

### Changed
- The tailnet screen is now screenshot **01** and home is **02**. `deliver`
  orders by filename and most people only look at the first one; the peer list
  is what distinguishes this app from a connection indicator.
### Added

- **Shortcuts, Siri, and Spotlight support** via App Intents: Connect to Tailnet,
  Get Tailnet Status, Count Online Devices, and Browse Tailnet. The status
  intents answer without launching the app; the two that need the node open it,
  because tsnet runs in the app's process and a first connection needs an
  interactive browser login.
- `TailnetSnapshot` — the last known state, persisted so an intent performed
  while the app is backgrounded has something true to report. Seeded at connect
  and refreshed by the peer list.
- `TailnetSnapshotTests` — 7 tests over the partial-update semantics, including
  a regression for counts being readable without opening the peer list.

### Added

- `NSLocalNetworkUsageDescription` and `NSAppTransportSecurity.NSAllowsLocalNetworking`
  in both manifests. iOS 14+ and macOS 15+ gate local-network access behind the
  usage string, and tsnet does LAN peer discovery. **Not** a fix for relayed
  peers: a control run with the key removed still reports `route=direct` once
  traffic flows. The earlier `relay sfo` readings were a measurement artifact —
  status was sampled immediately after `up()`, before any traffic, and a direct
  path is negotiated during traffic.
- Real App Review notes, adapted from PrivateClaw's review-tested copy. Leads
  with "NO SEPARATE TAILSCALE APP REQUIRED", which pre-empts the reviewer
  assumption that the Tailscale app must be installed alongside.
- Real `copyright.txt` and App Review contact details.

### Changed

- `.gitignore` now covers `fastlane/metadata/review_information/demo_user.txt`
  and `demo_password.txt`. `deliver` uploads those from disk, but that directory
  is tracked and this repo is public — a committed demo account would be a
  working login to the tailnet, published. The credentials belong in
  `.bootstrap.env` as `APP_REVIEW_DEMO_USER` / `APP_REVIEW_DEMO_PASSWORD`.

### Added

- **Tailnet peer dashboard.** The app now enumerates the tailnet it belongs to:
  peers with online state, tailnet IP, MagicDNS name, whether the path is direct
  or via a DERP relay, exit-node availability, ACL tags, and expired keys — plus
  tailnet health warnings and search. This is what a userspace node can show that
  a connection indicator cannot, and it addresses the App Review 4.2 minimum
  functionality risk of shipping connect/IP/sign-out alone.
- `TailnetStatusClient`, reading `/localapi/v0/status` directly and decoding into
  TailscaleKit's own `IpnState.Status`. Deliberately not `LocalAPIClient`: that
  awaits an actor `up()` holds for the whole login, and consumers of the
  published xcframework still have the unpatched wrapper.
- `TailnetPeerTests` — 8 tests over a fixture trimmed from a real status
  response, covering the decode and every presentation rule.
- `-peers` launch argument, which exercises the decode and ordering on device.

### Fixed

- **Corrected the `LocalAPIClient` root cause — twice-wrong, now measured.** The
  previous entry claimed the hang came from `proxyVia(_:)` routing LocalAPI
  requests through the SOCKS5 proxy, and quoted a "stock hangs forever" figure
  that had never actually been measured; stock returns in 8 ms once the node is
  Running. The real cause is an actor deadlock during bring-up: `up()` is a
  blocking C call holding the `TailscaleNode` actor for the entire login, and
  every `LocalAPIClient` request awaits the actor-isolated `node.loopback()` for
  a value that is already memoized. Measured on device with the node in
  `NeedsLogin`: direct HTTP to the LocalAPI answers in 32 ms while
  `backendStatus()` does not return for 53 s. Upstream fix filed as
  [libtailscale#58](https://github.com/tailscale/libtailscale/pull/58) and
  tracked in
  [tailscale#20997](https://github.com/tailscale/tailscale/issues/20997);
  carried locally as
  `tailscale/patches/0002-localapi-nonisolated-loopback.patch` until it lands.

### Added

- `-duringup` launch argument: probes the LocalAPI both directly and through
  `LocalAPIClient` *while `up()` is still in flight*. Measurements taken after
  the node reaches Running cannot see this bug at all, which is how it stayed
  misdiagnosed.
- `tailscale/patches/0002-localapi-nonisolated-loopback.patch`, applied by
  `build-tailscalekit.sh` alongside the existing tracing patch.

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

- **Corrected the `LocalAPIClient` finding in `TAILSCALE.md` and `README.md`.**
  Both previously blamed tsnet's loopback listener for the device hang. Measured
  on a physical iPhone with the node Running, that listener is healthy: a SOCKS5
  `CONNECT` to a tailnet peer returns 200 in 76 ms, and
  `GET /localapi/v0/status` straight at the loopback address returns 200 in
  69 ms with 65 peers. The fault is in TailscaleKit's `proxyVia(_:)`, which
  routes every LocalAPI request through the SOCKS5 proxy at the address that
  proxy is itself listening on, so the `CONNECT` never resolves. Peer and status
  data are therefore reachable on device today, by addressing the LocalAPI
  directly with the `Sec-Tailscale: localapi` header and basic auth.

### Added

- `SOCKS5Client` — a minimal SOCKS5 client over `NWConnection`. Needed because
  `URLSession.connectionProxyDictionary` ignores the SOCKS keys on iOS: a
  URLSession "through the proxy" silently exits over the normal interface and
  appears to work while never touching the tailnet.
- `-probe <host:port>` and `-localapi` launch arguments that reproduce both
  measurements above on a device.

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

# Tunnelless

> **Put an iOS or macOS app on a Tailscale network without a VPN profile.**
> No `NEPacketTunnelProvider`, no NetworkExtension entitlement, no "Allow VPN
> configuration" prompt, and no conflict with the VPN your user already runs.

A working demo app plus the build pipeline that makes it shippable through App
Store review. Verified on a physical iPhone (iOS 26.5) and on macOS.

---

## Why this exists

Ask how to add Tailscale to an iOS app and you get two answers, both wrong for
most apps:

1. **Require the Tailscale app.** Apple rejects apps that depend on it being
   installed.
2. **Ship a VPN.** A `NEPacketTunnelProvider` extension, the NetworkExtension
   entitlement, a system permission prompt, and mutual exclusion with your
   user's corporate VPN.

There's a third option that most developers don't know exists. Your app links
`tsnet` as a library and becomes its own device on the tailnet. Nothing is
routed at the OS level — only the connections your app makes.

|                    | Packet tunnel (VPN)       | Userspace tsnet (this repo) |
| ------------------ | ------------------------- | --------------------------- |
| Mechanism          | `NEPacketTunnelProvider`  | tsnet linked in-process     |
| Scope              | whole device              | your app's connections      |
| Transport          | OS route table            | SOCKS5 on loopback          |
| Entitlement        | NetworkExtension          | **none**                    |
| Extension target   | required                  | **none**                    |
| User prompt        | "Allow VPN configuration" | **none**                    |
| User's own VPN     | mutually exclusive        | unaffected                  |

Tailscale's own iOS client is the left column — correct for a general-purpose
VPN client. If your app only needs to reach *its own* infrastructure (your
server, your user's device, a self-hosted backend), the right column is
dramatically lighter.

The proof: this demo app's iOS entitlements file is **empty** — not one key in
it — and it builds and runs on a real device.

On macOS the app is sandboxed, which does require
`com.apple.security.network.server` (tsnet listens on loopback to expose the
SOCKS5 proxy) and `com.apple.security.network.client`. Those are ordinary App
Sandbox keys, not the NetworkExtension entitlement — no VPN profile, no
extension target, and no special entitlement request to Apple.

---

## Adding this to an existing app

You need two things: the framework, and about 250 lines of Swift.

### 1. Get `TailscaleKit.xcframework`

TailscaleKit is Tailscale's Swift wrapper around `tsnet`. It isn't a separate
project or a SwiftPM package — it lives as
[`swift/TailscaleKit`](https://github.com/tailscale/libtailscale/tree/main/swift/TailscaleKit)
inside [`tailscale/libtailscale`](https://github.com/tailscale/libtailscale),
and there's no published binary, which is why this repo builds one.

**Option A — add it as a SwiftPM dependency** (easiest)

```swift
.package(url: "https://github.com/indiagrams/tunnelless", from: "0.1.0")
```

**Versioning.** The package version is independent of the Tailscale version it
vends — `0.1.0` does not mean tsnet 0.1.0. It is `0.x` deliberately: the
packaging is young and may change. Each tag's release notes state the
`tailscale.com` version it carries, and `tailscale/TAILSCALE_VERSION` is the
source of truth on `main`.

Two separate things share this repo's tags, which is worth knowing:

| Tag | What it is |
| --- | --- |
| `0.1.0`, `0.2.0`, … | SwiftPM package versions — what `from:` resolves |
| `tailscalekit-v1.102.3` | the xcframework binary release the package downloads |

The package vends nothing but the prebuilt `TailscaleKit.xcframework`, pinned
by SHA-256 — a moved or rewritten asset fails resolution rather than silently
swapping the binary. `import TailscaleKit` and you're done; no Embed & Sign
step.

Note the module is named `TailscaleKit`, which is fixed by the binary. An
unrelated package ([mikeydotio/TailscaleKit](https://github.com/mikeydotio/TailscaleKit))
vends a module of the same name, built statically from its own C interface and
iOS-only. The two can't coexist in one dependency graph.

**Option B — download a prebuilt release** (no SwiftPM)

Grab `TailscaleKit.xcframework.zip` from
[Releases](../../releases), unzip, drag into your Xcode project, and set it to
**Embed & Sign**.

The release is built by `tailscale/build-tailscalekit.sh` in this repo and
already contains everything Apple checks for:

- three slices — `ios-arm64`, `ios-arm64_x86_64-simulator`, `macos-arm64`
- `PrivacyInfo.xcprivacy` injected into both iOS slices (ITMS-91053)
- no symlinks in the iOS slices
- no vendor team ID in the signature ([#15802](https://github.com/tailscale/tailscale/issues/15802))

It is **unsigned by design** — your app signs it on embed. Each release states
the exact `tailscale.com` version it was built from.

**Option C — build it yourself**

```bash
git submodule update --init --recursive     # vendor/libtailscale
bash tailscale/build-tailscalekit.sh        # ~5 min, needs Go + Xcode
bash tailscale/validate-xcframework.sh      # 6 checks
```

Do this if you need a different Tailscale version, or if you'd rather not ship
a binary you didn't compile.

### 2. Copy two files

| File | What it does |
| ---- | ------------ |
| [`app/Shared/Tailscale/TailscaleNodeManager.swift`](app/Shared/Tailscale/TailscaleNodeManager.swift) | Node lifecycle: start, browser login, tailnet IP, sign-out |
| [`app/Shared/Tailscale/WebAuthLogin.swift`](app/Shared/Tailscale/WebAuthLogin.swift) | In-app login sheet that dismisses itself when the node comes up |

Both are dependency-free apart from `TailscaleKit`. Every `WHY:` comment in
them records a specific failure — a deadlock, a lock conflict, an
`EXC_BAD_ACCESS` — that is not obvious and not documented upstream. Read them
before deleting anything.

### 3. Start a node

```swift
let manager = TailscaleNodeManager(hostName: "my-app")
try await manager.startForBrowserLogin()

// Where your traffic egresses onto the tailnet.
// Point URLSession or a raw socket here, using lb.proxyCredential.
let lb = await manager.cachedLoopback     // e.g. 127.0.0.1:49405
```

That's the integration. An afternoon's work.

### 4. Before you ship

Run the validator on every build that goes to App Store Connect:

```bash
bash tailscale/validate-xcframework.sh
```

All six failures it checks for happen at **upload or review**, never at build —
which is exactly why a green Xcode build tells you nothing about them.

---

## Run the demo

```bash
git submodule update --init --recursive
bash tailscale/build-tailscalekit.sh
cd app && xcodegen generate && cd ..
make check                     # builds iOS + macOS
```

### On a physical device

`DEVELOPMENT_TEAM` stays as `TEAM_ID_PLACEHOLDER` — pass your own team rather
than committing it:

```bash
xcodebuild build \
  -project app/Tunnelless.xcodeproj -scheme Tunnelless-iOS -configuration Debug \
  -destination 'id=<YOUR-DEVICE-UDID>' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<YOUR-TEAM-ID>

xcrun devicectl device install app --device <UDID> <path>/Tunnelless-iOS.app
xcrun devicectl device process launch --device <UDID> \
  --terminate-existing --console com.indiagram.tunnelless -- -autoconnect
```

Four Apple-side prerequisites, each of which fails with an error that does not
name its own cause:

1. **Trust the Mac** on the device.
2. **Developer Mode** — Settings → Privacy & Security → Developer Mode, then
   restart. Without it `xcodebuild` reports only `Device is busy (Waiting to
   reconnect)`.
3. **Accept the current Program License Agreement** at developer.apple.com, or
   every provisioning call fails with `PLA Update available`.
4. **Register the device UDID.** `-allowProvisioningUpdates` does *not* do this
   for you.

`--console` streams the app's stdout, which is how you watch tsnet come up
without attaching a debugger:

```
[TailscaleKit] init: tailscale_start sd=… returned res=0
[Tunnelless] tsnet SOCKS5 loopback: 127.0.0.1:49405
[TailscaleKit] up(): tailscale_up sd=… returned res=0
```

---

## What's in here

| Path | What |
| ---- | ---- |
| `app/Shared/Tailscale/` | The integration — copy this into your app |
| `app/Shared/ContentView.swift` | Demo UI: connect, tailnet IP, SOCKS5 address, sign out |
| `tailscale/build-tailscalekit.sh` | Builds all three slices, injects manifests, re-signs |
| `tailscale/validate-xcframework.sh` | The six pre-upload checks |
| `vendor/libtailscale` | Submodule, pinned to a known-good commit |
| [`TAILSCALE.md`](TAILSCALE.md) | **The gotchas.** Read this before debugging anything. |

Everything else is [apple-shipkit](https://github.com/indiagrams/apple-shipkit)
scaffolding (signing, CI, TestFlight). Tailscale tooling deliberately lives in
`tailscale/` rather than `ci/`, because shipkit marks `ci/` template-owned and
this fork still merges upstream.

---

## The one that will cost you a week

`LocalAPIClient` — TailscaleKit's documented control interface — **cannot be
used while the node is coming up.** `startLoginInteractive()`,
`backendStatus()`, `watchIPNBus()`: every call blocks until `up()` returns,
which for an interactive login means minutes, and forever if the user never
finishes. `startLoginInteractive()` is the one you most need in that window.

After `up()` returns they all work normally — which is exactly what makes this
expensive. Every measurement taken from the connected state looks healthy.

The cause is an actor deadlock, not the network. `up()` is `tailscale_up`, a
blocking C call holding the `TailscaleNode` actor for the whole login flow, and
every `LocalAPIClient` request awaits `node.loopback()` — actor-isolated, and
already memoized, so the wait buys nothing. Measured on a physical iPhone with
the node stuck in `NeedsLogin`: a direct `GET /localapi/v0/status` using a
loopback config captured beforehand answers in **32 ms**, while
`LocalAPIClient.backendStatus()` on the same run does not return for **53 s** —
until `up()` finishes. The listener was never the problem.

Fixed upstream in
[libtailscale#58](https://github.com/tailscale/libtailscale/pull/58); until it
lands this repo carries it as a build-time patch.

For the login flow the workaround is `LogPipeLogger`: attach a `LogSink`, read
tsnet's own log stream, and match on the state transitions. Full explanation,
the measurements, and four more traps in [TAILSCALE.md](TAILSCALE.md).

---

## Upstream

Work found here that has gone upstream:

- [tailscale#19052](https://github.com/tailscale/tailscale/pull/19052) — darwin
  `os.Executable` fallback. **Merged, shipped in v1.98.0.**
- [tailscale#20985](https://github.com/tailscale/tailscale/pull/20985) —
  `Close()` nil-deref when `Start()` failed early. Surfaces through TailscaleKit
  as `EXC_BAD_ACCESS`, masking the real startup error. **Open, approved.**
- [libtailscale#57](https://github.com/tailscale/libtailscale/pull/57) — makes
  the built xcframework shippable: privacy manifests for the iOS slices
  (ITMS-91053), a macOS slice, and a validator for the failures that only
  appear at upload. **Open** ([tailscale#20992](https://github.com/tailscale/tailscale/issues/20992)).
  If it lands, most of `tailscale/build-tailscalekit.sh` becomes unnecessary
  and you can take the xcframework straight from upstream.
- [libtailscale#58](https://github.com/tailscale/libtailscale/pull/58) — runs the
  blocking `tailscale_up` off the actor, so `LocalAPIClient` stops awaiting an
  actor that `up()` holds for the entire login. **Open**
  ([tailscale#20997](https://github.com/tailscale/tailscale/issues/20997)).
  Until it lands this repo carries it as
  `tailscale/patches/0002-up-off-actor.patch`.

### Why this repo still exists

Both of the obvious upstream issues —
[#13937](https://github.com/tailscale/tailscale/issues/13937) (first-class Swift
support) and
[#15410](https://github.com/tailscale/tailscale/issues/15410) (libtailscale on
iDevices) — are **closed as completed**. TailscaleKit is the result of the
first, and this project is built on it.

Closed is not the same as finished, though. Both the App Sandbox requirement
(`com.apple.security.network.server`, without which a signed macOS build never
starts tsnet) and the bring-up deadlock that makes `LocalAPIClient` unusable
during login were found *after* those issues were closed — which is a fair sign of how much this
particular path is currently exercised.

#15410 ends with a maintainer noting *"The HelloTailscale sample should get
ported over to iOS."* That is, more or less, what this repo is.

---

## Status and licence

**Reference implementation, not a supported library.** Pinned to a known-good
Tailscale version. Read it, copy from it, don't take a dependency on it.

This repo is MIT.

[`tailscale/libtailscale`](https://github.com/tailscale/libtailscale) is
BSD-3-Clause, © Tailscale & AUTHORS. TailscaleKit is the Swift layer within it
rather than a separate project, so it carries the same licence — and the
binaries in every release here are built from that source. A copy of the
licence ships inside each release archive.

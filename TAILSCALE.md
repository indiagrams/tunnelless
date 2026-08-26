# Embedded Tailscale on iOS — reference implementation

> **Reference implementation, not a supported library.** Pinned to a known-good
> Tailscale version. Read it, copy from it, don't depend on it.

This app puts itself on a Tailscale network **without a VPN profile**:

- no `NEPacketTunnelProvider`
- no NetworkExtension entitlement
- no "Allow VPN configuration" prompt
- no conflict with whatever VPN the user already runs

The app links `tsnet` as a library and becomes its own device on the tailnet.
Traffic reaches peers through the SOCKS5 proxy tsnet exposes on loopback.

## Two ways to speak Tailscale

|                        | Packet tunnel (VPN)         | Userspace tsnet (this repo) |
| ---------------------- | --------------------------- | --------------------------- |
| Mechanism              | `NEPacketTunnelProvider`    | tsnet linked in-process     |
| Scope                  | whole device                | this app's connections      |
| Transport              | OS route table              | SOCKS5 on loopback          |
| Entitlement            | NetworkExtension            | **none**                    |
| Extension target       | required                    | **none**                    |
| User prompt            | "Allow VPN configuration"   | **none**                    |
| User's own VPN         | mutually exclusive          | unaffected                  |

Tailscale's own iOS client is the left column, and that's correct for a
general-purpose VPN client. If your app only needs to reach *its own*
infrastructure, the right column is dramatically lighter.

## Build it

Requires Go, Xcode, and `xcodegen` (`make bootstrap` installs the rest).

```bash
git submodule update --init --recursive     # vendor/libtailscale
bash tailscale/build-tailscalekit.sh        # ~5 min: 3 slices, manifests, signing
bash tailscale/validate-xcframework.sh      # 6 checks — run before any upload
cd app && xcodegen generate && cd ..
make check                                  # builds iOS + macOS
```

The xcframework (~94 MB) is **not** committed. The pipeline that produces it is
the actual contribution here, so building it is part of using this repo.

## What's where

| Path                                       | What                                                     |
| ------------------------------------------ | -------------------------------------------------------- |
| `app/Shared/Tailscale/TailscaleNodeManager.swift` | The node lifecycle. Every `WHY:` comment is a bug that cost real time. |
| `app/Shared/ContentView.swift`             | Demo UI — connect, show tailnet IP + SOCKS5 proxy, sign out. |
| `tailscale/build-tailscalekit.sh`          | Builds all three slices, injects privacy manifests, re-signs. |
| `tailscale/validate-xcframework.sh`        | Asserts the things Apple rejects for. Run before uploading. |
| `tailscale/PrivacyInfo.xcprivacy`          | The manifest injected into both iOS slices.               |
| `vendor/libtailscale`                      | Submodule, pinned to a known-good commit.                 |

Everything else is [apple-shipkit](https://github.com/indiagrams/apple-shipkit)
scaffolding. Per its `AGENTS.md`, `bin/`, `ci/`, `.github/workflows/`, `Makefile`
and `fastlane/Fastfile` are template-owned — **Tailscale tooling deliberately
lives in `tailscale/`, not `ci/`, so the fork can still merge upstream.**

## The five things that will bite you

**1. `LocalAPIClient` hangs forever on physical iOS devices.** Every HTTP call
through it — `startLoginInteractive()`, `backendStatus()`, `watchIPNBus()` —
blocks and never returns. Works in the simulator. The SOCKS5 proxy accepts the
TCP connection but never delivers an HTTP response; no error, no timeout.

The workaround is `LogPipeLogger`: attach a `LogSink`, read tsnet's own log
stream, and match on

```
control: AuthURL is https://…        → first run, open this URL
Switching ipn state … -> Running     → already authorised, skip the browser
```

Do **not** match on the friendlier `"To start this tsnet server… go to:"`
banner — it goes to a different file descriptor and never reaches your pipe.

**2. Cache `loopback()` before calling `up()`.** `up()` is a blocking C call
that holds the `TailscaleNode` actor for the whole login flow. Any
`await node.loopback()` issued afterwards queues behind it forever.

**3. Weak-capture the node in the up-task.** A strong capture keeps the Go
server alive past a reset, holding the state-directory lock, so the next login
fails with `TailscaleError(3)`.

**4. Sign-out must delete the state directory.** Otherwise tsnet reuses
persisted auth, never re-logs `AuthURL is`, and a login flow waiting on that
line waits forever.

**5. A release tag's date says nothing about its contents.** `v1.96.4` was
tagged four days *after* [#19052](https://github.com/tailscale/tailscale/pull/19052)
merged and does not contain it — the release branch was cut earlier. Check the
source at the tag, never the date.

## What Apple rejects

| Rejection | Cause | Caught by |
| --- | --- | --- |
| **ITMS-91053** | no `PrivacyInfo.xcprivacy` in an iOS slice | `validate-xcframework.sh` |
| symlinks in iOS slices | copying framework dirs naively | `validate-xcframework.sh` |
| vendor team ID in signature | prebuilt binary signed by Tailscale ([#15802](https://github.com/tailscale/tailscale/issues/15802)) | `validate-xcframework.sh` |

Every one of these fails at **upload**, not at build. That's the whole reason
the validator exists.

## Upstream

- [#19052](https://github.com/tailscale/tailscale/pull/19052) — darwin
  `os.Executable` fallback. Merged, shipped in **v1.98.0**.
- [#20985](https://github.com/tailscale/tailscale/pull/20985) — `Close()`
  nil-deref when `Start()` failed early. Surfaces through TailscaleKit as
  `EXC_BAD_ACCESS`, masking the real startup error. Open.
- [#13937](https://github.com/tailscale/tailscale/issues/13937) — first-class
  Swift support. Open.

While #20985 is unmerged, `build-tailscalekit.sh` patches the fix into the Go
module cache and **hard-fails if the patch doesn't apply** — an xcframework
missing a crash fix should never build silently.

## macOS: the App Sandbox needs `network.server`

A sandboxed macOS build fails to start tsnet at all unless
`com.apple.security.network.server` is granted. tsnet listens on loopback — that
is where the SOCKS5 proxy lives — and a listening socket under App Sandbox
requires that entitlement.

Measured on a signed build, same binary, varying only the entitlements:

| Entitlements | `tailscale_start` |
| --- | --- |
| `app-sandbox` alone | `res=-1` |
| `app-sandbox` + `network.client` | `res=-1` |
| `app-sandbox` + `network.server` | `res=0` |
| `app-sandbox` + both | `res=0` |

`network.client` is granted too, for outbound connections to the control plane,
DERP, and peers. The `network.server`-only run above reused an
already-authenticated state directory, so it never exercised a cold
control-plane dial.

**Why CI missed it.** The `app` matrix builds unsigned
(`CODE_SIGNING_ALLOWED=NO`), and without a signature the sandbox is not
enforced — so an unsigned build connects happily while the signed one it
ships never starts. Any change to `app/macOS/*.entitlements` should be checked
against a *signed* build:

```bash
xcodebuild build -project app/TailnetDemo.xcodeproj -scheme TailnetDemo-macOS \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/dd-mac \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
timeout 45 /tmp/dd-mac/Build/Products/Debug/TailnetDemo-macOS.app/Contents/MacOS/TailnetDemo-macOS \
  -autoconnect 2>&1 | grep tailscale_start
```

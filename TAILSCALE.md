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
| `tailscale/TAILSCALE_VERSION`              | The `tailscale.com` version to build. Single source of truth. |
| `tailscale/patches/`                       | Local changes applied to the submodule at build time.     |
| `vendor/libtailscale`                      | Submodule tracking **upstream** `tailscale/libtailscale`. Expected to be dirty after a build — the script moves its `go.mod` and applies patches in place. |

Everything else is [apple-shipkit](https://github.com/indiagrams/apple-shipkit)
scaffolding. Per its `AGENTS.md`, `bin/`, `ci/`, `.github/workflows/`, `Makefile`
and `fastlane/Fastfile` are template-owned — **Tailscale tooling deliberately
lives in `tailscale/`, not `ci/`, so the fork can still merge upstream.**

## The five things that will bite you

**1. `LocalAPIClient` is unusable *during bring-up*, because `up()` holds the
actor every request awaits.** `startLoginInteractive()`, `backendStatus()` and
`watchIPNBus()` all block until `up()` returns — minutes for an interactive
login, forever if the user never finishes. After `up()` returns they work
normally, which is what makes this so easy to misread as a dead LocalAPI.

*Corrected twice; the history matters more than the conclusion.* This entry
first blamed tsnet's loopback listener. It was then rewritten to blame SOCKS5
proxy routing in `proxyVia(_:)` — also wrong, and worse, that revision quoted a
"stock hangs forever" figure that had never been measured. Both are recorded
here because the wrong turns are instructive: every measurement taken *after*
`up()` returned looked healthy, so the bug was invisible until something probed
*during* the login window.

**Root cause.** `up()` is `tailscale_up`, a blocking C call that holds the
`TailscaleNode` actor for the whole login flow — this is item 2 below. Every
`LocalAPIClient` request builds its session through `proxyVia(_:)`, which does
`await node.loopback()`, an actor-isolated accessor. That await queues behind
`up()` and never resumes until it returns. Items 1 and 2 are the same bug.

The awaited value is already memoized: `loopback()` caches on first call and
returns the same value forever after, so the actor entry buys nothing.

Measured on a physical iPhone 12, node left in `NeedsLogin` so `up()` blocked
~53 s, probing concurrently with `up()`:

| Arm | Enters the node actor? | Result during `up()` |
|---|---|---|
| direct HTTP `GET /localapi/v0/status`, loopback captured before `up()` | no | **200 OK in 32 ms**, `BackendState=NeedsLogin` |
| `LocalAPIClient.backendStatus()` — stock | yes | **hung**; resolved only once `up()` returned |
| `LocalAPIClient.backendStatus()` — patched | no | **200 OK in 5 ms**, `BackendState=NeedsLogin` |

The **stock** row is the measurement taken when this bug was first diagnosed on
device; it was *not* re-measured in the session that produced the 5 ms patched
figure, so treat it as cited rather than freshly paired. The mechanism does have
a same-session before/after, on macOS: stock hung with no return within
**10007 ms** where the patched build returned in **22 ms**, baseline first.

The direct arm is the control: the LocalAPI listener answers throughout, so only
the actor hop in front of it is blocked. After `up()` returns, stock
`backendStatus()` answers in 8 ms — there is no hang to find there.

Reproduce with the launch arguments `-duringup` (both arms above), `-probe
<host:port>` (SOCKS5 to a peer), `-localapi` (direct HTTP) and `-localapiclient`
(the real client, after Running).

`-duringup` needs **`-autoconnect` alongside it**: `connect()` only runs
unattended with that argument, and without it `up()` never runs and there is
nothing to sample. Pass both through XCUITest `launchArguments` rather than
`devicectl`, which parses `-autoconnect` as one of its own options; the device
also needs *Settings → Developer → Enable UI Automation*. `probeResult` writes
via `NSLog`, so capture with `idevicesyslog`, not `devicectl --console` (stdout
only).

**The node must be in `NeedsLogin` when the probes run.** On a device whose
state directory still holds credentials, `tailscale_up` returns in ~12 ms and
both arms report `BackendState=Running` — a healthy sample that says nothing
about the defect. Uninstall the app first to clear the container. The run below
was taken after an uninstall: `up()` was called at `00:55:25.160`, the probes
answered at `00:55:25.225` and `00:55:25.230`, and `up()` did not return until
`00:56:53.231` — 88 seconds later, with both arms reporting `NeedsLogin`. Reaching the LocalAPI directly needs both
credentials from `tailscale.h`: the `Sec-Tailscale: localapi` header **and**
basic auth with `local_api_cred`.

**Fix:** [libtailscale#58](https://github.com/tailscale/libtailscale/pull/58)
runs the blocking `tailscale_up` off the actor —
`await Task.detached { tailscale_up(tailscale) }.value` — so `up()` suspends and
releases the actor instead of holding it for the whole login. Carried locally as
`tailscale/patches/0002-up-off-actor.patch` until it lands.

An earlier revision of #58 instead added a `nonisolated resolvedLoopback()` so
the memoized value could be read without actor entry. The maintainer proposed
freeing the actor instead, and measurement showed that is the better fix: tsnet
never serialised these calls — `Up()` blocks on an IPN bus watcher rather than a
lock, and `Loopback()` returned in **433 µs** while `Up()` was held in
`NeedsLogin` — so releasing the actor is sufficient on its own, and the caller
caveat the old approach needed ("resolve the loopback config before calling
`up()`") disappears. It also unblocks `close()`, which is the documented way to
cancel an in-progress `tailscale_up` and was itself unreachable during login.

The login workaround stays regardless — it needs no credentials and is the only
signal available before the node is up.

The login workaround is `LogPipeLogger`: attach a `LogSink`, read tsnet's own
log stream, and match on

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

Everything this project has filed upstream, newest first.

| Upstream | What | Status |
| --- | --- | --- |
| [libtailscale#58](https://github.com/tailscale/libtailscale/pull/58) | Runs `tailscale_up` off the actor so `LocalAPIClient` stops awaiting an actor `up()` holds for the whole login | **Open**, changes requested and addressed |
| [libtailscale#59](https://github.com/tailscale/libtailscale/pull/59) | Universal (arm64 + x86_64) macOS slice — without it a universal macOS release cannot link | **Open**, no review yet |
| [tailscale#21005](https://github.com/tailscale/tailscale/issues/21005) | `TailscaleNode.down()` calls `tailscale_up()`; on a node never brought up it starts it. No `tailscale_down` exists | **Open** |
| [tailscale#20997](https://github.com/tailscale/tailscale/issues/20997) | The issue #58 fixes: LocalAPIClient unusable during bring-up | **Open** |
| [libtailscale#57](https://github.com/tailscale/libtailscale/pull/57) | Makes the built xcframework distributable: privacy manifests (ITMS-91053), a macOS slice, a validator for upload-only failures | **Open** |
| [tailscale#20985](https://github.com/tailscale/tailscale/pull/20985) | `Close()` nil-deref when `Start()` failed early — surfaces as `EXC_BAD_ACCESS`, masking the real startup error | **Merged** 2026-08-26, but *not* in the pinned `v1.102.3` |
| [tailscale#19052](https://github.com/tailscale/tailscale/pull/19052) | darwin `os.Executable` fallback | **Merged**, shipped in v1.98.0 |

If #57 lands, most of `build-tailscalekit.sh` becomes redundant. If #58 lands,
`tailscale/patches/0002-up-off-actor.patch` can be dropped and status/peer data
becomes readable during login without a workaround. #59 is what keeps
`PLATFORMS=ios`: the macOS slice is arm64-only, so a macOS release cannot link
x86_64.

That x86_64 requirement comes from Xcode's default, not from Apple. The macOS
target resolves `ARCHS = arm64 x86_64` via `ARCHS_STANDARD`; nothing in this
repo asks for it. Setting `ARCHS = arm64` would link against the existing slice
and ship Apple-Silicon-only, at the cost of Intel Macs — so #59 is what a
*universal* macOS build needs, not what macOS support needs at all.

Background, both **closed as completed**:

- [tailscale#13937](https://github.com/tailscale/tailscale/issues/13937) —
  first-class Swift support. Closed 2025-05-05; TailscaleKit is the result.
- [tailscale#15410](https://github.com/tailscale/tailscale/issues/15410) —
  libtailscale on iDevices vs. Apple sandboxing. Closed 2025-03-25. Worth
  reading: it anticipated the `os.Executable` problem #19052 later fixed, and
  ends with *"The HelloTailscale sample should get ported over to iOS."*

Closed-as-completed does not mean finished in practice — the `network.server`
sandbox requirement and the bring-up deadlock in item 1 were both found after
those issues were closed.

`build-tailscalekit.sh` applies the carried fixes from `tailscale/patches/` and
**hard-fails if a patch doesn't apply** — an xcframework missing a fix should
never build silently.

#20985 has merged upstream, but the merge commit is **not** contained in the
pinned `v1.102.3` (comparing the two reports `diverged, ahead 153`), so its
module-cache patch stays until a version bump carries it. A release tag's date
does not tell you whether it contains a commit — check containment, not dates.

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

**Why CI missed it.** The `app` matrix in `pr.yml` builds unsigned
(`CODE_SIGNING_ALLOWED=NO`), and without a signature the sandbox is not
enforced — so an unsigned build connects happily while the signed one it
ships never starts.

**This is now guarded.** `.github/workflows/macos-sandbox-check.yml` signs the
app ad-hoc (enough to make the kernel enforce entitlements — no Apple
credentials needed, so it runs on forks), launches it, and fails unless tsnet
reports `tailscale_start ... returned res=0`. It runs on any change to
`app/macOS/**`, `app/Shared/Tailscale/**`, the project manifests, `tailscale/**`,
or the pinned submodule.

To reproduce it locally:

```bash
xcodebuild build -project app/Tunnelless.xcodeproj -scheme Tunnelless-macOS \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/dd-mac \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES

/tmp/dd-mac/Build/Products/Debug/Tunnelless-macOS.app/Contents/MacOS/Tunnelless-macOS \
  -autoconnect 2>&1 | grep tailscale_start
# want: "... tailscale_start sd=... returned res=0"
```

**The guard depends on a local patch.** The `[TailscaleKit]` NSLog tracing it
greps for is not upstream — it comes from
`tailscale/patches/0001-tailscalekit-nslog-tracing.patch`, applied to the
submodule at build time. If that patch stops applying, `build-tailscalekit.sh`
hard-fails; if it were somehow dropped, this check reports "no tailscale_start
result found" and fails loudly rather than silently passing. Rebase the patch
instead of deleting the check.

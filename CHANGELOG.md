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

- **`tailscale/verify-floor-runtime.sh` — proves a declared iOS floor by loading
  it.** `ci/check-platform-floors.sh` compares declared floors against the
  `minos` a slice reports, but never loads anything, and every machine that
  builds this repo runs an OS above every floor it declares — so the failure a
  floor exists to prevent was invisible to every green check.

  The script builds the app for the simulator and launches it twice: once
  carrying the pre-lowering framework from an earlier `tailscalekit-*` release
  (the negative control, which dyld must refuse) and once carrying the current
  one. If the control *loads*, the run reports INCONCLUSIVE and discards the
  subject's pass rather than reporting it.

  It refuses to run on a simulator at or above the old floor, because such a
  runtime clears the old and new floors alike and cannot tell a lowered floor
  from an unlowered one. Needs a runtime in `[declared floor, previous floor)`;
  not wired into CI, as GitHub's macOS images carry no old runtimes.

  First run on iOS 17.5 confirms the lowered floor: the app maps `TailscaleKit`
  and runs, while the same app carrying the `tailscalekit-v1.102.3` framework
  dies with `built for iOS-sim 18.1 which is newer than running OS`. **The macOS
  14.0 floor remains structural only** — there is no macOS simulator, so it
  needs a machine or VM on macOS 14–15.5.

### Changed

- **Marketing version 0.1.0 → 0.1.1.** Releasing 0.1.0 to the Mac App Store **closes that version train**: Apple refuses any further macOS build carrying `CFBundleShortVersionString` 0.1.0 with `Invalid Pre-Release Train. The train version '0.1.0' is closed for new build submissions`. This is not a tooling failure and there is no flag for it — the marketing version has to move. Found when a build-8 ship succeeded for iOS (whose 0.1.0 is still in review, so its train is open) and was refused for macOS in the same run. Bumped in both declaration sites, `app/project.yml` and `app/Project.swift`.

- **`marketing_url` moved off GitHub** to `https://indiagram.com/tunnelless.html`, a real product page ([indiagram-site#4](https://github.com/indiagrams/indiagram-site/pull/4)). It was `https://github.com/indiagrams/tunnelless`, which appears on the live App Store listing as `sellerUrl`. Apple rejected the **support** URL under Guideline 1.5 for being the issue tracker; the marketing URL was the same shape on the same listing and simply was not flagged. All three metadata URLs — support, marketing, privacy — now point at real pages rather than GitHub. Reaches the listing on the next `deliver`, i.e. `make submit`, not on a ship.

- **`Package.swift` now resolves `tailscalekit-v1.102.3+3`** — the first artifact built from the bumped submodule, with patches `0002` and `0003` gone. URL and checksum move together, as always. The floors are unchanged at iOS 17.0 / macOS 14.0, but their **provenance** is not: they now come from upstream's own `@available` gating rather than from a patch applied at build time. Same numbers, different source, which is why the artifact was verified rather than assumed — all three published slices read `minos 17.0 / 17.0 / 14.0`, and the shipped binary still contains all seven of patch `0001`'s NSLog strings, confirming the rebased patch applied on a real build.

- **`macos-sandbox-check.yml` resolves the framework tag from `Package.swift`** instead of deriving it from `tailscale/TAILSCALE_VERSION`. The two agree only while an artifact is uniquely determined by the tsnet version, and that stopped being true the moment a `+N` build suffix existed: `TAILSCALE_VERSION` still reads `v1.102.3` while consumers resolve `v1.102.3+3`. So this job had been downloading `tailscalekit-v1.102.3` — the **pre-lowering** framework, a different binary from the one that ships — ever since `+2` was published. `pr.yml` was fixed the same way in #53; this workflow was missed because it is fork-owned and lives in its own file. It now cross-checks the resolved tag against `TAILSCALE_VERSION` too, so a manifest pointing at a different tsnet version fails loudly rather than quietly testing the wrong thing.

- **The App Store privacy URL now points at `https://indiagram.com/privacy.html`** rather than `https://github.com/indiagrams/tunnelless/blob/main/PRIVACY.md`. Pre-emptive: Apple rejected the *support* URL under Guideline 1.5 for being a GitHub page rather than a website, and the privacy URL was the same shape on the same listing. It was not flagged, and this changes it before it is.

  Sequenced deliberately, because repointing alone would have made things worse. `indiagram.com/privacy.html` described only PrivateClaw — API keys, prompts and AI conversation data on a VPS, none of which this app does — so the site page was extended to cover Tunnelless first (`indiagrams/indiagram-site#3`), mirroring this repo's `PRIVACY.md`: collects nothing, tsnet state confined to the app container and deleted on sign-out, sign-in on Tailscale's own site, connected traffic governed by Tailscale's policy, SOCKS5 traffic never proxied or logged by us. An accurate policy awkwardly hosted beats a well-hosted policy about a different product.

  `PRIVACY.md` remains the canonical text and now carries a pointer to the published page, with an explicit instruction to change both together — two copies of a privacy policy is a drift risk worth naming.

  Reaches the App Store with the next `deliver` upload; the build-7 submissions already in review carry the previous URL.

- **Deployment floors are now iOS 17.0 / macOS 14.0**, down from 18.1 / 15.6.
  A new xcframework was published as `tailscalekit-v1.102.3+2` — same tsnet
  version, rebuilt with patch `0003` — and verified from the downloaded asset:
  `minos 17.0` (ios-arm64, and the simulator slice) and `14.0` (macos-arm64).
  `Package.swift`'s URL, checksum and platform floors moved together;
  `app/project.yml` and `app/Project.swift` follow.

  Reaches users with the next app build. The declarations changing does not
  alter the `0.1.0` binaries currently in App Review.

### Fixed

- **App Review rejection of macOS `0.1.0` build 5 (2026-08-30), both findings.** **Guideline 2.1(a)** — "the Sign in button was unresponsive". Not reproducible here: on a cold, signed build (Debug and Release, macOS 26.5.2) `tailscale_start` returns `res=0`, `control: AuthURL is …` does reach the app's log pipe, `ASWebAuthenticationSession.start()` returns `true` and the sheet presents. What the investigation did find is a latent bug that produces *exactly* the reported symptom: `start()` returns `Bool` and the result was **discarded**. On failure nothing opens, the completion handler never fires, and the continuation was never resumed — so `presentLogin()` never returned, its `isPresentingLogin` latch stayed set, and the `guard !isPresentingLogin` at the top swallowed every later tap. The sign-in button goes permanently dead with no error shown anywhere. `present(url:dismissWhen:)` now returns a three-case `Outcome` (`completed` / `cancelled` / `failedToPresent(reason:)`) instead of a `Bool` that could not represent "the sheet never opened", resumes the continuation on every path, and the caller always clears the latch and shows the reason. `WindowPresenter` now prefers a key window, then any **visible** window, before the detached `NSWindow()` last resort — a window that was never shown cannot host a sheet, which is one way `start()` fails. `presentLoginWhenURLAppears` no longer falls through silently after ~20s leaving the UI on "waiting for login…"; it says no sign-in link arrived and points at Demo mode. **Guideline 1.5** — the Support URL was `https://github.com/indiagrams/tunnelless/issues`, which Apple does not accept as a support site; now `https://indiagram.com/support.html` (verified HTTP 200). Note `fastlane/Fastfile`'s `metadata_dir` is platform-agnostic, so this URL is shared: the queued iOS build 5 carried the same rejected URL and would have failed 1.5 for the same reason.

- **`make ship` recorded almost nothing about the release it had just run.** A real ship produced a **13-line log** — every line printed by `bin/ship.rb` itself, none from the multi-minute `fastlane release` those lines described. Redirecting changed nothing: the output never left the Ruby process. `Bootstrap::Sh.run` wraps `Open3.capture3`, which buffers until exit and discards stderr, and `ship.rb` then dropped the captured string on success and printed stdout without stderr on failure — so **a ship that FAILED was exactly as undiagnosable as one that succeeded**, which is backwards. Diagnosing the v0.1.0+6 ship meant reconstructing events from fastlane's `report.xml` and the ASC API.

  Fixed **upstream** in apple-shipkit ([#276](https://github.com/indiagrams/apple-shipkit/pull/276)) rather than here, because `bin/` is template-owned and `bin/ship.rb` was byte-identical to the template — a fork edit would conflict on every sync for a bug with nothing project-specific about it. Cherry-picked in as `5bb986f` so this repo gets it without the full 271-commit upstream merge, which would also touch `fastlane/metadata/` and could clobber the live App Review notes while both `0.1.0` submissions are queued with Apple.

  Adds `Bootstrap::Sh.stream` (tees a child's merged stdout+stderr as it arrives via `popen2e`; passes `chdir:` as a spawn option instead of mutating the process-global cwd for a whole release) and `test/sh_stream_test.rb` — 10 stdlib-only assertions wired as the `stream-regression` CI job, two of them **controls** asserting the old path fails what the new one passes. Mutation-verified: restoring the `capture3` body fails 5 of the 10.

### Removed

- **Patches `0002-up-off-actor` and `0003-gate-listener-api` — deleted, not rebased.** Both landed upstream on 2026-08-31 ([libtailscale#58](https://github.com/tailscale/libtailscale/pull/58) as `61e8513`, [libtailscale#60](https://github.com/tailscale/libtailscale/pull/60) as `8564835`), and `vendor/libtailscale` was bumped `5e89501` → `59d4bb8` to pick them up. Deleting rather than rebasing is the standing rule for a patch upstream has absorbed: upstream now carries the same shape, so a rebase would reapply what is already there.

  Verified rather than assumed. `0002`'s mechanism is upstream verbatim — `let res = await Task.detached { tailscale_up(tailscale) }.value` — and `0003`'s `@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, *)` is present on both `Listener.swift` and `IncomingConnection.swift`. Neither patch reverse-applied cleanly, which is only evidence that the text differs, not that the fix is present; the files were read.

  **Carried patches: 3 → 1.** The lowered iOS 17 / macOS 14 floors now come from upstream rather than from a patch this repo applies, which was the point of v0.2: carry nothing an adopter would inherit.

### Changed

- **`0001-tailscalekit-nslog-tracing` rebased onto the bumped submodule.** It is not upstream and stays carried — `macos-sandbox-check.yml` greps for the tracing it adds. The bump moved it in two ways: `import Foundation` is now provided upstream (by `8077131`), so that hunk was dropped, and its `up()` hunk had to be re-cut onto #58's detached-task form rather than the old inline `tailscale_up(tailscale)` call. All 7 NSLog statements are preserved and the patch applies cleanly.

- **`tailscale-upstream-watch.yml`'s patch registry** drops the `0002` and `0003` rows, because the registry describes what is carried now. Its unwatched-patch guard is what keeps the list and `tailscale/patches/` in step, and both now hold exactly `0001`.

- **Module-cache Patch 1 (darwin `os.Executable` fallback) is gone.** It merged
  upstream as `tailscale#19052` and shipped in **v1.98.0**; the pin has been
  `v1.102.3` since the last bump, so the block did nothing but print "already
  applied" on every build — confirmed by reading `case "ios", "darwin":` in
  `tsnet.go` at the tag, not by trusting the release date. First item of v0.2's
  "carry less" to actually land.

  It was kept in case the dependency were ever pinned below v1.98. That scenario
  is now guarded explicitly: `build-tailscalekit.sh` hard-fails on such a pin
  with the reason and a `git log -S` pointer to recover the patch, instead of
  letting `TailscaleNode.init()` fail at runtime with "tsnet: cannot find
  executable path". Boundary verified — `v1.98.0` accepted, `v1.96.4` rejected.

### Changed

- **Deployment floors lowered to iOS 17.0 / macOS 14.0** (from 18.1 / 15.6) for
  the *next* xcframework build. `tailscale/patches/0003-gate-listener-api.patch`
  gates TailscaleKit's two listener actors behind `@available`, which confines
  their iOS 18 / macOS 15 requirement to themselves instead of the whole
  framework — this app is a pure client and never calls them. Every number was
  measured by building at it: unpatched the real floor is 18.0/15.0, and
  upstream's shipped 18.1/15.6 is above even that. Sent upstream as
  [libtailscale#60](https://github.com/tailscale/libtailscale/pull/60);
  **when it lands, delete the patch — do not rebase it.**

  The floors in `app/` and `Package.swift` deliberately stay at 18.1/15.6 until a
  new xcframework is published: they must describe the binary consumers actually
  resolve, not the one we can now build. `ci/check-platform-floors.sh` enforces
  that ordering on its own.

### Added

- **`ci/check-app-icon.sh` — the build now refuses a placeholder icon.** Build 1
  shipped apple-shipkit's flat blue template icon unchanged and came back as a
  Guideline 2.3.8 rejection. Nothing objected on the way out: the asset was a
  valid 1024x1024 PNG, all six CI cells were green, and App Store Connect's
  upload validation accepted it. The only thing that noticed was a human
  reviewer, a full cycle later.

  Placeholders are detected structurally, with no knowledge of the app's brand:
  quantise to 8 colours, take the largest distance between clusters covering
  >=3% of the image. Artwork puts distant clusters on the canvas; a flat fill or
  a bare gradient does not. Measured — flat blue `0`, shipkit's template `0`,
  the real icon `282`; the threshold is `40`. Also checks 1024x1024 and rejects
  an alpha channel, which Apple refuses outright.

  Deliberately no Pillow: icons inside a built `.ipa` are CgBI PNGs, which
  Pillow refuses with "broken data stream" — so a Pillow implementation would
  silently skip the artifact that matters most. Pixels come via `sips` and a
  stdlib BMP parse. `ALLOW_PLACEHOLDER_ICON=true` overrides.

### Changed

- **README's Upstream section brought current**, and it now separates *merged*
  from *shipped* — `tailscale#20985` was listed as "Open, approved" when it had
  merged on 2026-08-26, and merging is not what retires the carried patch.
  Added `libtailscale#59` (universal macOS slice, and why it is not what macOS
  support needs) and `tailscale#21005` (`down()` calls `tailscale_up()`), both
  of which existed only in TAILSCALE.md. Every state re-verified against GitHub
  rather than carried over.

### Added

- **`tailscale-upstream-watch.yml` now decides patch retirement instead of
  delegating it.** It reads `tsnet/tsnet.go` at the pinned and latest tags and
  reports whether each contains `tailscale#20985`, replacing a weekly issue that
  said "verify by grepping the tagged source" and left the grepping to a human.
  Four outcomes: actionable now, a bump would retire it, merged-but-unreleased
  (nothing to do), and a fetch failure — which reports `UNKNOWN` rather than
  "not contained", because treating a failed fetch as absence is how a patch
  step quietly outlives its purpose. Since today's real state is
  merged-but-unreleased, the tracking issue now closes itself rather than
  reopening every Monday.

- **App Review notes now answer Guideline 5.1.1(v) (account deletion).** Apple
  raised it against macOS build 4 and no build can answer it: the app creates no
  account, so there is nothing to add to the binary. The notes now state that
  there is no sign-up, and separate the two things signing in does create — the
  on-device state directory, which `Sign out & reset` deletes in one action, and
  the device entry on the user's own tailnet, which the app *cannot* remove
  because tsnet exposes no logout or device-removal call. Written this way
  because the previous draft claimed sign-out removed the tailnet entry, which is
  false — the 12 stale `tunnelless-*` nodes that needed
  `DELETE /api/v2/device/{id}` are the proof.

- **`ci/check-review-notes.sh` fails when an app with interactive sign-in says
  nothing about account deletion.** Guideline 5.1.1(v) has already cost one
  review cycle, and a Resolution Center reply cannot carry the answer forward —
  that thread closes the moment you resubmit, so the notes are the only durable
  channel.

- **macOS builds are possible again.** `ARCHS = arm64` on the `Tunnelless-macOS`
  target. `ARCHS_STANDARD` resolves to `arm64 x86_64`, and TailscaleKit's macOS
  slice is arm64-only, so a universal build could not link — which is what kept
  `PLATFORMS=ios`. Verified against Apple: a Mac App Store package containing
  only an `arm64` slice returns `VERIFY SUCCEEDED with no errors` from
  `altool --validate-app`. **Apple does not require an Intel slice**, so
  [libtailscale#59](https://github.com/tailscale/libtailscale/pull/59) is what a
  *universal* macOS build needs, not what macOS support needs.

### Fixed

- **The notes-vs-plist encryption guard never ran.** `check-review-notes.sh`
  greps line-by-line for `ITSAppUsesNonExemptEncryption is set to <value>`, but
  the notes are hard-wrapped prose and the claim spans a line break, so the
  pattern matched nothing and the check silently passed. It is the guard that
  exists specifically to stop a false claim reaching App Review — the exact bug
  it was written for (PrivateClaw's notes claiming `true` against a `false`
  plist) would have gone straight through here. Now newline-tolerant, and
  verified to fail when the claim is flipped.

- **macOS deployment target raised to 15.6.** It declared `14.0` while
  TailscaleKit's macOS slice is built `minos 15.6`. That links cleanly and then
  fails at launch on anything older — dyld refuses the framework. It appeared
  only as a single `ld: warning` in an otherwise green build. macOS 14 and
  15.0–15.5 can no longer install; that is imposed by the framework, and
  lowering it needs upstream to lower `MACOS_TARGET`.

- **`ci/local-release-check.sh` signed the `.pkg` with the wrong team's
  installer certificate.** Selection was `security find-identity | grep … |
  head -1`, with no team filter, so a keychain holding both a personal-team and
  an org-team *Mac Installer Distribution* cert got whichever sorted first —
  and App Store Connect rejects a package signed by a different team than the
  app. This is the same ambiguity the code-signing path already pins away with
  `RELEASE_MACOS_CERT_SHA1`, left unhandled for the installer cert. Now prefers
  the identity matching `$TEAM_ID`, warns and falls back when none matches, and
  accepts `RELEASE_MACOS_INSTALLER_SHA1` as an override. Adds the `warn()`
  helper the script never had.

### Changed

- **The carried LocalAPI fix now runs `tailscale_up` off the actor** instead of
  adding a `nonisolated` accessor. `tailscale/patches/0002-up-off-actor.patch`
  replaces `tailscale/patches/0002-localapi-nonisolated-loopback.patch`, keeping
  the local build in step with what
  [libtailscale#58](https://github.com/tailscale/libtailscale/pull/58) now
  proposes after review.

  The maintainer proposed freeing the actor rather than working around it, and
  measurement showed that is the better fix. tsnet never serialised these calls
  — `Up()` blocks on an IPN bus watcher rather than a lock — so `Loopback()`
  returns in **433 µs** while `Up()` is held in `NeedsLogin`. Releasing the actor
  is therefore sufficient on its own, and the caveat the old approach required
  ("resolve the loopback config before calling `up()`") is gone. It also unblocks
  `close()`, the documented way to cancel an in-progress `tailscale_up`, which
  was itself unreachable during login.

  At the Swift level, same machine and session, baseline first: stock hung with
  no return within **10007 ms**; patched returned in **22 ms**.

  Confirmed on device (iPhone 12, iOS 26.5) after an uninstall so the node was
  genuinely in `NeedsLogin`: `up()` was in flight for **88 s**, and
  `LocalAPIClient.backendStatus()` answered in **5 ms** inside that window with
  `BackendState=NeedsLogin`. An earlier attempt on a device that still held
  credentials returned `Running` in 12 ms and was discarded — it sampled the
  state where the defect cannot appear.

- `TAILSCALE.md` and `README.md` updated to describe the new approach, and the
  upstream table corrected: [tailscale#20985](https://github.com/tailscale/tailscale/pull/20985)
  has **merged** but is *not* contained in the pinned `v1.102.3`, so its
  module-cache patch stays until a version bump.

### Added

- [libtailscale#59](https://github.com/tailscale/libtailscale/pull/59) and
  [tailscale#21005](https://github.com/tailscale/tailscale/issues/21005) added to
  the upstream table. #21005 reports that `TailscaleNode.down()` calls
  `tailscale_up()`: on a node never brought up it starts it, and no
  `tailscale_down` exists in the C API.

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

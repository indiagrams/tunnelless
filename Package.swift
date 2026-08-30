// swift-tools-version:5.9
//
// Distributes the prebuilt TailscaleKit.xcframework as a SwiftPM dependency.
//
// WHAT THIS VENDS: the binary only. `TailscaleKit` itself is Tailscale's Swift
// wrapper around tsnet — it lives at swift/TailscaleKit inside
// tailscale/libtailscale and is BSD-3-Clause, (c) Tailscale & AUTHORS.
// Upstream publishes no prebuilt binary, so this package exists to make one
// resolvable instead of drag-and-drop. It is not a reimplementation and adds
// no Swift code of its own.
//
// WHAT THIS DOES NOT VEND: the demo app in app/. That code is meant to be read
// and copied, not depended on — see the README. Taking this package as a
// dependency gets you the framework, nothing else.
//
// The archive is pinned by checksum, so a moved or rewritten release asset
// fails resolution instead of silently swapping the binary underneath you.
// Both the URL and the checksum change together on every version bump; see
// tailscale/TAILSCALE_VERSION for the version actually built.
//
// Module-name collision, worth knowing: the framework's module is
// `TailscaleKit`, which is fixed by the binary. An unrelated SwiftPM package
// (mikeydotio/TailscaleKit) vends a module of the same name built a different
// way — statically, from its own C interface, iOS-only. The two cannot coexist
// in one dependency graph. Pick whichever fits; they answer different
// questions.

import PackageDescription

// Hoisted so the line fits SwiftLint's 140-char limit. It must stay on ONE
// line and keep this exact shape: tailscale/verify-package-manifest.sh greps
// the URL out of this file to check it still matches the pinned version.
let assetURL = "https://github.com/indiagrams/tunnelless/releases/download/tailscalekit-v1.102.3+2/TailscaleKit.xcframework.zip"

let package = Package(
    name: "TailscaleKit",
    // Matches the slices actually present in the xcframework: ios-arm64,
    // ios-arm64_x86_64-simulator, macos-arm64.
    // These MUST match the `minos` of the slices in the binary, not the
    // versions we would like to support. SwiftPM does not check them: declare a
    // lower floor and a consumer resolves, links and ships happily, then dyld
    // refuses the framework at launch on any OS below the real minimum.
    // ci/check-platform-floors.sh asserts these against the built slices.
    platforms: [
        .iOS("17.0"),
        .macOS("14.0"),
    ],
    products: [
        .library(name: "TailscaleKit", targets: ["TailscaleKit"]),
    ],
    targets: [
        // The target name must match the .xcframework's name inside the
        // archive; SwiftPM resolves it by that name.
        .binaryTarget(
            name: "TailscaleKit",
            url: assetURL,
            checksum: "b9cf64e6298c548e1edc28c47b503b5f6f14237d21ef3a5c2c4e3559dc8fb0c4"
        ),
    ]
)

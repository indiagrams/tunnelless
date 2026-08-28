// DemoData.swift
//
// Fixture state for App Store screenshot capture.
//
// WHY this exists: the screens worth showing — a connected node and its tailnet — only
// exist after a Tailscale login, and a Simulator has no account to log in with. Without
// this, capture photographs an idle "not connected" screen and never reaches the peer
// list at all.
//
// The data is representative, not invented capability: every field shown is one the app
// really renders from a real /localapi/v0/status response, with the same layout and the
// same code path. Only the source of the bytes differs.
//
// Gated exclusively on a launch argument, which a user cannot set on a shipped app — it
// is reachable from `fastlane snapshot` and from Xcode, and nowhere else.

import Foundation

enum DemoData {
    /// Turned on from the app itself, via the "Demo mode" button on the main screen.
    ///
    /// WHY this exists: App Review could not evaluate the app. Signing in requires a
    /// Tailscale account, and the demo account we supply now prompts for an emailed
    /// verification code that a reviewer cannot receive — Guideline 2.1(a),
    /// "we need an authentication code to access the app's content". Apple's own
    /// suggested remedy is "including a demonstration mode that exhibits the app's
    /// full features and functionality", which is this.
    ///
    /// Deliberately not persisted: demo mode should never survive a relaunch and be
    /// mistaken for a real tailnet. Sign out clears it too.
    @MainActor static var runtimeEnabled = false

    /// True under `fastlane snapshot` / an explicit Xcode run argument.
    static var launchArgumentEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestDemoData")
    }

    @MainActor static var isEnabled: Bool {
        launchArgumentEnabled || runtimeEnabled
    }

    static let tailnetIP = "100.84.19.7"
    static let socksProxy = "127.0.0.1:49872"
    static let tailnetName = "example.ts.net"

    /// Shaped like a real tailnet: a few live machines, a tail of offline ones, a mix of
    /// direct and relayed paths, one exit node, one tagged server, one expired key.
    static let peers: [TailnetPeer] = [
        peer("nas", ip: "100.84.19.22", online: true, route: "direct"),
        peer("build-server", ip: "100.84.19.31", online: true, route: "direct",
             tags: ["tag:ci"]),
        peer("macbook-pro", ip: "100.84.19.44", online: true, route: "relay sfo",
             subtitle: "Alex's MacBook Pro"),
        peer("homelab-gateway", ip: "100.84.19.9", online: true, route: "direct",
             offersExit: true),
        peer("iphone-15", ip: "100.84.19.58", online: true, route: "relay sfo"),
        peer("grafana", ip: "100.84.19.63", online: false, route: nil, tags: ["tag:server"]),
        peer("old-laptop", ip: "100.84.19.77", online: false, route: nil, expired: true),
        peer("pixel-8", ip: "100.84.19.81", online: false, route: nil),
        peer("backup-nas", ip: "100.84.19.95", online: false, route: nil)
    ]

    static var onlineCount: Int {
        peers.filter(\.online).count
    }

    private static func peer(
        _ name: String,
        ip: String,
        online: Bool,
        route: String?,
        subtitle: String? = nil,
        tags: [String] = [],
        offersExit: Bool = false,
        expired: Bool = false
    ) -> TailnetPeer {
        TailnetPeer(
            id: name,
            displayName: name,
            subtitle: subtitle,
            hostName: subtitle ?? name,
            shortDNSName: name,
            ipv4: ip,
            online: online,
            isExitNode: false,
            offersExitNode: offersExit,
            expired: expired,
            tags: tags,
            route: route
        )
    }
}

// TunnellessAppIntents.swift
//
// Shortcuts, Siri, and Spotlight entry points.
//
// These matter beyond convenience: they are the clearest evidence that this is a native
// app rather than a wrapper, which is what App Review Guideline 4.2 is actually asking
// about. They also make the app scriptable — "is my server reachable" becomes an
// automation step rather than a thing you open an app to look at.
//
// Division of labour, forced by tsnet living inside the app process:
//
//   - Anything that must TOUCH the node opens the app (`openAppWhenRun`). A node cannot
//     be started from an out-of-process intent, and the login flow needs a browser.
//   - Anything that only REPORTS reads TailnetSnapshot, so it answers instantly without
//     launching anything.

import AppIntents
import Foundation

// MARK: - Connect

struct ConnectTailnetIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Tailnet"
    static let description = IntentDescription(
        "Opens Tunnelless and joins your Tailscale network.",
        categoryName: "Connection"
    )

    /// WHY it opens the app: tsnet runs in the app's own process, and a first connection
    /// may need an interactive browser login. Performing this silently in the background
    /// would either do nothing or strand the user at an invisible login.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .tunnellessConnectRequested, object: nil)
        return .result()
    }
}

// MARK: - Status

struct TailnetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Tailnet Status"
    static let description = IntentDescription(
        "Reports whether Tunnelless is connected, its address, and how many devices are online.",
        categoryName: "Status"
    )

    /// Reads the last known state, so it answers without launching the app.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let s = TailnetSnapshotStore.load()

        guard s.updatedAt != .distantPast else {
            let msg = "Tunnelless hasn't connected yet."
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }

        let summary = if s.isConnected {
            "Connected as \(s.tailnetIP ?? "unknown"), " +
                "\(s.onlinePeerCount) of \(s.peerCount) devices online (\(s.ageDescription))."
        } else {
            "Not connected (\(s.ageDescription))."
        }
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - Online device count

struct OnlineDeviceCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Count Online Devices"
    static let description = IntentDescription(
        "Returns how many devices on your Tailscale network are currently reachable.",
        categoryName: "Status"
    )

    static let openAppWhenRun = false

    /// Returns an Int rather than a sentence so it composes in Shortcuts — it can feed a
    /// comparison, a notification, or a condition without string parsing.
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let s = TailnetSnapshotStore.load()
        let dialog = s.updatedAt == .distantPast
            ? "Tunnelless hasn't connected yet."
            : "\(s.onlinePeerCount) of \(s.peerCount) devices online (\(s.ageDescription))."
        return .result(value: s.onlinePeerCount, dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - Browse

struct OpenTailnetIntent: AppIntent {
    static let title: LocalizedStringResource = "Browse Tailnet"
    static let description = IntentDescription(
        "Opens Tunnelless to the list of devices on your Tailscale network.",
        categoryName: "Connection"
    )

    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .tunnellessBrowseRequested, object: nil)
        return .result()
    }
}

// MARK: - Shortcuts surface

/// Registers the phrases Siri and Spotlight match against.
///
/// Every phrase must contain `\(.applicationName)` — App Intents refuses to build
/// otherwise, because a bare phrase would collide across apps.
struct TunnellessShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectTailnetIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "Join my tailnet with \(.applicationName)"
            ],
            shortTitle: "Connect",
            systemImageName: "network"
        )
        AppShortcut(
            intent: TailnetStatusIntent(),
            phrases: [
                "\(.applicationName) status",
                "Check my tailnet with \(.applicationName)"
            ],
            shortTitle: "Status",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: OnlineDeviceCountIntent(),
            phrases: [
                "How many devices are online in \(.applicationName)"
            ],
            shortTitle: "Online devices",
            systemImageName: "number.circle"
        )
        AppShortcut(
            intent: OpenTailnetIntent(),
            phrases: [
                "Browse my tailnet with \(.applicationName)",
                "Show devices in \(.applicationName)"
            ],
            shortTitle: "Browse",
            systemImageName: "list.bullet.rectangle"
        )
    }
}

// MARK: - App-side hooks

extension Notification.Name {
    /// Posted by ConnectTailnetIntent once the app is frontmost.
    static let tunnellessConnectRequested = Notification.Name("tunnelless.connectRequested")
    /// Posted by OpenTailnetIntent once the app is frontmost.
    static let tunnellessBrowseRequested = Notification.Name("tunnelless.browseRequested")
}

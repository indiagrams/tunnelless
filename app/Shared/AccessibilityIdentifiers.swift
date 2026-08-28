import Foundation

/// Stable identifiers for UI test queries.
///
/// **Why these exist.** UI tests should never match elements by their visible
/// text — the moment your app supports another language (or you tweak copy),
/// the test silently breaks. Use these constants in both your views and
/// your tests so the contract is explicit and refactor-safe.
///
/// **Adding an identifier.** Define a constant here, attach it to the view
/// via `.accessibilityIdentifier(AccessibilityIdentifiers.<name>)`, and
/// query it in tests via `app.staticTexts[AccessibilityIdentifiers.<name>]`
/// (or `.otherElements`, `.buttons`, `.images` etc. depending on the SwiftUI
/// element type backing it).
///
/// **Single source of truth.** This file is compiled into BOTH the main
/// app target (via `app/Shared/**`) AND the UI test target (via an
/// explicit `sources:` entry in project.yml / Project.swift). UI tests
/// run as a separate process and can't link the app binary, so the
/// standard `@testable import` pattern doesn't apply for them. Compiling
/// the one shared file into both targets preserves the single-source-of-
/// truth property — refactor here and both ends see it.
///
/// **Naming convention.** Dotted, lowercase, scoped by feature
/// (`Tunnelless.title`, `Settings.signIn`, `Trends.chart`). The leading scope
/// makes them grep-friendly and avoids collisions as forks add features.
public enum AccessibilityIdentifiers {
    /// The "Tunnelless" title text — stable selector for UI tests across locales.
    /// SwiftUI Text elements surface in XCUITest queries as `app.staticTexts[id]`.
    /// SwiftUI containers (VStack, HStack, ZStack) without an explicit
    /// accessibility role don't surface independently, so attach identifiers
    /// to elements that XCUITest can actually query.
    public static let title = "Tunnelless.title"

    // MARK: - Tailnet demo

    /// Current tsnet node state ("idle", "starting tsnet…", "running", "failed").
    public static let statusText = "Tunnelless.statusText"
    /// The node's tailnet IPv4 address, shown once the node reaches Running.
    public static let tailnetIP = "Tunnelless.tailnetIP"
    /// Starts the node and the browser-login flow.
    public static let connectButton = "Tunnelless.connectButton"
    static let demoModeButton = "demoModeButton"
    /// Opens the interactive auth URL scraped from tsnet's log stream.
    public static let loginLink = "Tunnelless.loginLink"

    // MARK: - Peer dashboard

    /// Opens the tailnet peer list. Only present once the node is running.
    public static let peersButton = "Tunnelless.peersButton"
    /// "N online of M" header above the peer list — the cheapest assertion that the
    /// LocalAPI was read and decoded, without depending on any particular peer existing.
    public static let peerCount = "Tunnelless.peerCount"
    /// A single peer row. Non-unique by design: tests query the collection.
    public static let peerRow = "Tunnelless.peerRow"

    // MARK: - Saved services

    /// Opens the saved-services list.
    public static let servicesButton = "Tunnelless.servicesButton"
    /// A saved service row.
    public static let serviceRow = "Tunnelless.serviceRow"
    /// Opens the add-service sheet.
    public static let addServiceButton = "Tunnelless.addServiceButton"
    /// Name field in the add-service sheet.
    public static let serviceNameField = "Tunnelless.serviceNameField"
    /// Confirms the add-service sheet.
    public static let saveServiceButton = "Tunnelless.saveServiceButton"
    /// HTTP status badge in the reader.
    public static let serviceStatus = "Tunnelless.serviceStatus"
    /// Rendered response body in the reader.
    public static let serviceBody = "Tunnelless.serviceBody"
}

// ContentView.swift
//
// Demonstrates a userspace Tailscale node running inside the app.
//
// The flow: start tsnet with an empty auth key, read tsnet's log stream for the
// interactive auth URL, open it, and wait for the node to reach Running. Once up,
// the app has its own tailnet IPv4 address and can reach tailnet peers through the
// SOCKS5 proxy tsnet exposes on loopback.
//
// No packet tunnel, no NetworkExtension entitlement, no VPN permission prompt.

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @State private var model = DemoModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            statusRow

            if let ip = model.tailnetIP {
                labelled("Tailnet IPv4", ip)
                    .accessibilityIdentifier(AccessibilityIdentifiers.tailnetIP)
            }

            if let proxy = model.socksProxy {
                labelled("SOCKS5 proxy", proxy)
            }

            if model.authURL != nil {
                // Opens an in-app sheet and returns here automatically once the node is up.
                Button("Sign in to Tailscale") {
                    Task { await model.presentLogin() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AccessibilityIdentifiers.loginLink)
            }

            if let err = model.errorText {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(model.isRunning ? "Connected" : "Connect") {
                    Task { await model.connect() }
                }
                .disabled(model.isBusy || model.isRunning)
                .accessibilityIdentifier(AccessibilityIdentifiers.connectButton)

                Button("Sign out & reset", role: .destructive) {
                    Task { await model.signOut() }
                }
                .disabled(model.isBusy)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        .task {
            // Launch with `-autoconnect` to start the node without a tap.
            // Used by UI tests and for capturing screenshots of the connected state.
            if ProcessInfo.processInfo.arguments.contains("-autoconnect") {
                await model.connect()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tailnet Demo")
                .font(.title2.bold())
            Text("A userspace tsnet node inside this app — no VPN profile.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRunning ? .green : (model.isBusy ? .orange : .secondary))
                .frame(width: 9, height: 9)
            Text(model.statusText)
                .font(.callout.monospaced())
                .accessibilityIdentifier(AccessibilityIdentifiers.statusText)
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class DemoModel {
    private let manager = TailscaleNodeManager(hostName: "tailnet-demo")

    var statusText = "idle"
    var tailnetIP: String?
    var socksProxy: String?
    var authURL: URL?
    var errorText: String?
    var isBusy = false
    var isRunning = false
    var isPresentingLogin = false

    private var logTask: Task<Void, Never>?

    func connect() async {
        isBusy = true
        errorText = nil
        statusText = "starting tsnet…"

        do {
            try await manager.startForBrowserLogin()

            // Cached before up() ran — see TailscaleNodeManager.cachedLoopback.
            if let lb = await manager.cachedLoopback {
                socksProxy = "\(lb.address)"
            }

            startWatchingLogs()

            statusText = "waiting for login…"

            // If tsnet needs interactive auth it logs an AuthURL within a few seconds.
            // Present it in-app as soon as it appears, rather than making the user tap.
            await presentLoginWhenURLAppears()

            try await manager.awaitUp()

            if case let .connected(ip) = await manager.state {
                tailnetIP = ip
                isRunning = true
                statusText = "running"
                authURL = nil
            }
        } catch {
            errorText = String(describing: error)
            statusText = "failed"
        }
        isBusy = false
    }

    /// Reads tsnet's log stream for the auth URL and the Running transition.
    ///
    /// This exists because LocalAPIClient hangs forever on physical iOS devices —
    /// the log pipe is the only reliable signal there.
    private func startWatchingLogs() {
        logTask?.cancel()
        logTask = Task { [manager] in
            guard let pipe = await manager.currentLogPipe() else { return }
            // Iterating FileHandle.AsyncBytes can throw (e.g. the pipe closing on reset).
            // That's an expected end-of-stream here, not a failure to surface.
            do {
                for try await line in manager.logLines(pipe) {
                    if Task.isCancelled { return }
                    if let url = manager.authURL(from: line) {
                        await MainActor.run { self.authURL = url }
                    }
                    if manager.reportsRunning(line) {
                        await MainActor.run { self.statusText = "running" }
                    }
                }
            } catch {
                return
            }
        }
    }

    /// Presents the interactive login sheet for the URL parsed from tsnet's logs.
    ///
    /// The sheet closes itself when the node reaches Running — Tailscale's flow ends on
    /// console.tailscale.com and never redirects back to the app, so the node is the only
    /// reliable completion signal.
    func presentLogin() async {
        guard let url = authURL, !isPresentingLogin else { return }
        isPresentingLogin = true
        let ok = await WebAuthLogin.present(url: url, dismissWhen: await manager.currentUpTask())
        isPresentingLogin = false
        if !ok { statusText = "login cancelled" }
    }

    /// Waits briefly for tsnet to log an auth URL, then presents it.
    ///
    /// Returns immediately if the node is already authorised — a node with persisted state
    /// goes straight to Running and never logs an AuthURL, so waiting forever would hang.
    private func presentLoginWhenURLAppears() async {
        for _ in 0..<40 {                       // ~20s
            if authURL != nil { await presentLogin(); return }
            if isRunning { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func signOut() async {
        isBusy = true
        logTask?.cancel()
        await manager.signOutAndReset()
        tailnetIP = nil
        socksProxy = nil
        authURL = nil
        isRunning = false
        statusText = "idle"
        isBusy = false
    }
}

#Preview {
    ContentView()
}

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
import TailscaleKit

#if canImport(UIKit)
    import UIKit
#endif

struct ContentView: View {
    @State private var model = DemoModel()
    @State private var showPeers = false
    @State private var showServices = false

    var body: some View {
        NavigationStack {
            content
        }
    }

    private var content: some View {
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

            if model.isRunning {
                // Button + navigationDestination rather than NavigationLink(isActive:),
                // which is deprecated under NavigationStack. This shape also lets the
                // Browse Tailnet intent drive navigation by flipping the same flag.
                Button {
                    showPeers = true
                } label: {
                    Label("Browse tailnet", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier(AccessibilityIdentifiers.peersButton)

                Button {
                    showServices = true
                } label: {
                    Label("Services", systemImage: "bookmark")
                }
                .accessibilityIdentifier(AccessibilityIdentifiers.servicesButton)
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

                if !model.isRunning {
                    // Visible and unauthenticated on purpose: this is the path App
                    // Review takes when it cannot receive the demo account's
                    // verification code.
                    Button("Demo mode") {
                        Task { await model.enterDemoMode() }
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier(AccessibilityIdentifiers.demoModeButton)
                }

                Button("Sign out & reset", role: .destructive) {
                    Task { await model.signOut() }
                }
                .disabled(model.isBusy)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        .navigationDestination(isPresented: $showPeers) {
            PeerListView(manager: model.manager)
        }
        .navigationDestination(isPresented: $showServices) {
            ServiceListView(manager: model.manager)
        }
        .task {
            // Launch with `-autoconnect` to start the node without a tap.
            // Used by UI tests and for capturing screenshots of the connected state.
            if ProcessInfo.processInfo.arguments.contains("-autoconnect") {
                await model.connect()
            }
        }
        // App Intents that need the node must run here: tsnet lives in this process,
        // and a first connection may need an interactive browser login.
        .onReceive(NotificationCenter.default.publisher(for: .tunnellessConnectRequested)) { _ in
            guard !model.isRunning, !model.isBusy else { return }
            Task { await model.connect() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tunnellessBrowseRequested)) { _ in
            showPeers = model.isRunning
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tunnelless")
                .font(.title2.bold())
                .accessibilityIdentifier(AccessibilityIdentifiers.title)
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
    /// Not private: the diagnostic probes in DiagnosticProbes.swift extend this type.
    let manager = TailscaleNodeManager(hostName: "tunnelless")

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
        // Screenshot capture: present the connected state without a node. Starting tsnet
        // would stall at a login the Simulator cannot complete.
        if DemoData.isEnabled {
            tailnetIP = DemoData.tailnetIP
            socksProxy = DemoData.socksProxy
            isRunning = true
            isBusy = false
            authURL = nil
            statusText = "running"
            return
        }

        isBusy = true
        errorText = nil
        statusText = "starting tsnet…"

        do {
            try await manager.startForBrowserLogin()

            // Cached before up() ran — see TailscaleNodeManager.cachedLoopback.
            if let lb = await manager.cachedLoopback {
                socksProxy = "\(lb.address)"
            }

            // Detached on purpose: this must overlap up(), not follow it. Awaiting it
            // here would sit behind presentLoginWhenURLAppears(), which blocks until
            // login completes — the exact window the probe is meant to sample.
            if ProcessInfo.processInfo.arguments.contains("-duringup") {
                Task { await self.runDuringUpProbesIfRequested() }
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
                TailnetSnapshotStore.update(
                    isConnected: true, tailnetIP: ip, socksProxy: socksProxy
                )
                await seedPeerCounts()
                await runProbeIfRequested()
                await runLocalAPIProbeIfRequested()
                await runLocalAPIClientProbeIfRequested()
                await runPeerProbeIfRequested()
                await runServiceProbeIfRequested()
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
                    if Task.isCancelled {
                        return
                    }
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
        let outcome = await WebAuthLogin.present(url: url, dismissWhen: manager.currentUpTask())
        // ALWAYS clear the latch, on every outcome. This is the line that keeps the
        // sign-in button alive: the guard above rejects every later tap while
        // `isPresentingLogin` is set, so a path that leaves it set turns the button
        // permanently dead — which is indistinguishable, to a user or an App Review
        // engineer, from a button that does nothing at all.
        isPresentingLogin = false
        switch outcome {
        case .completed:
            errorText = nil
        case .cancelled:
            statusText = "login cancelled"
        case let .failedToPresent(reason):
            // Say it out loud rather than sitting on "waiting for login…". A sign-in
            // that cannot start is a bug report, not a state to wait in.
            statusText = "sign-in unavailable"
            errorText = "Could not open the Tailscale sign-in page — \(reason). "
                + "Try again, or use Demo mode."
        }
    }

    /// Waits briefly for tsnet to log an auth URL, then presents it.
    ///
    /// Returns immediately if the node is already authorised — a node with persisted state
    /// goes straight to Running and never logs an AuthURL, so waiting forever would hang.
    private func presentLoginWhenURLAppears() async {
        for _ in 0 ..< 40 { // ~20s
            if authURL != nil {
                await presentLogin(); return
            }
            if isRunning {
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Fell through: no auth URL in ~20s and the node is not up. Previously this
        // returned silently and the UI kept saying "waiting for login…" forever,
        // with no button and no explanation. Say what happened; `connect()` can
        // still finish if the node comes up on its own.
        if authURL == nil, !isRunning {
            statusText = "no sign-in link yet"
            errorText = "Tailscale has not returned a sign-in link yet. "
                + "Check the network connection and press Connect again, or use Demo mode."
        }
    }

    /// Reads status once at connect so the snapshot carries peer counts immediately.
    ///
    /// WHY at connect and not only in the peer list: App Intents read the snapshot
    /// without launching the app, and PeerListModel only refreshes while its view is
    /// on screen. Without this, "Count Online Devices" answers 0 until the user has
    /// visited the dashboard at least once — measured on device, which is the only
    /// place the gap shows.
    private func seedPeerCounts() async {
        guard let loopback = await manager.cachedLoopback else { return }
        guard let status = try? await TailnetStatusClient(loopback: loopback).status() else { return }
        let rows = status.peerRows()
        TailnetSnapshotStore.update(
            tailnetName: status.CurrentTailnet?.Name,
            peerCount: rows.count,
            onlinePeerCount: rows.filter(\.online).count
        )
    }

    /// Shows the app's full interface against fixture data, with no account.
    /// See DemoData.runtimeEnabled for why this is in the shipping app.
    func enterDemoMode() async {
        DemoData.runtimeEnabled = true
        await connect()
    }

    func signOut() async {
        isBusy = true
        // Leaving demo mode is part of sign-out; otherwise "Connect" would keep
        // returning fixture data with no way back to a real node.
        DemoData.runtimeEnabled = false
        logTask?.cancel()
        await manager.signOutAndReset()
        TailnetSnapshotStore.clear()
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

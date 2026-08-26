// TailscaleNodeManager.swift
//
// A userspace Tailscale (tsnet) node running inside the app process.
//
// This is the whole point of the reference: the app becomes its own device on the
// tailnet WITHOUT a packet tunnel. There is no NEPacketTunnelProvider, no
// NetworkExtension entitlement, and no "Allow VPN configuration" prompt. Traffic
// reaches the tailnet through the SOCKS5 proxy tsnet exposes on loopback.
//
// Every comment marked WHY below records a failure that cost real debugging time.
// They are not stylistic notes — removing the behaviour they describe reintroduces
// a hang, a deadlock, or a TailscaleError(3).

import Foundation
import TailscaleKit

// MARK: - Log sink

/// Routes tsnet's Go-side log output into a `Pipe` we can read line by line.
///
/// WHY: `LocalAPIClient` is non-functional on physical iOS devices — every HTTP call
/// through it blocks forever (`startLoginInteractive`, `backendStatus`, `watchIPNBus`).
/// The SOCKS5 proxy accepts the TCP connection but never returns an HTTP response, and
/// there is no error and no timeout. Reading tsnet's own log stream is the only reliable
/// way to observe login state on device. tsnet re-logs the auth URL every few seconds,
/// so a late reader still catches it.
struct LogPipeLogger: LogSink {
    let pipe: Pipe
    var logFileHandle: Int32? { pipe.fileHandleForWriting.fileDescriptor }
    func log(_ message: String) {}
}

// MARK: - Errors

enum TailscaleNodeError: Error, Equatable {
    case notStarted
    case noAddress
    case loginTimedOut
}

// MARK: - State

enum TailscaleNodeState: Equatable {
    case idle
    case starting
    /// Node is up and has a tailnet IPv4 address.
    case connected(ip: String)
    case failed(String)

    static func == (a: TailscaleNodeState, b: TailscaleNodeState) -> Bool {
        switch (a, b) {
        case (.idle, .idle), (.starting, .starting): return true
        case let (.connected(x), .connected(y)): return x == y
        case let (.failed(x), .failed(y)): return x == y
        default: return false
        }
    }
}

// MARK: - Manager

actor TailscaleNodeManager {

    /// Hostname this node registers under on the tailnet.
    private let hostName: String

    private var node: TailscaleNode?
    private var upTask: Task<Void, Error>?
    private var logPipe: Pipe?

    /// Loopback address + credentials for the SOCKS5 proxy and the LocalAPI.
    ///
    /// WHY cached: `up()` calls `tailscale_up()`, a blocking C call that holds the
    /// `TailscaleNode` actor for the ENTIRE browser-login flow. Any `await node.loopback()`
    /// issued after `upTask` starts queues behind it and never returns. Resolving it here,
    /// before `up()` is ever called, avoids the deadlock outright.
    private(set) var cachedLoopback: TailscaleNode.LoopbackConfig?

    private(set) var state: TailscaleNodeState = .idle

    init(hostName: String) {
        self.hostName = hostName
    }

    /// Where tsnet persists node identity between launches.
    ///
    /// WHY it matters: sign-out MUST delete this directory. Otherwise tsnet reuses the
    /// persisted auth, never re-logs `control: AuthURL is …`, and a login flow that waits
    /// for that line waits forever.
    static func stateDirPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("tsnet-state", isDirectory: true).path
    }

    /// Brings up a node using the interactive browser-login path (empty auth key).
    ///
    /// Returns immediately; the node continues coming up in the background. Observe
    /// `logLines()` for the auth URL and `state` for completion.
    func startForBrowserLogin() async throws {
        if case .connected = state { return }

        // WHY: `TailscaleNode(config:logger:)` calls TsnetStart() internally, which takes the
        // tsnet state-directory lock. A previous attempt's background up() task still holds a
        // strong reference to the old node, so the Go server is alive and the lock is held.
        // Constructing a second node here produces TailscaleError(3). Reuse instead.
        if node != nil {
            state = .starting
            return
        }

        state = .starting

        do {
            let stateDir = Self.stateDirPath()
            try FileManager.default.createDirectory(atPath: stateDir,
                                                    withIntermediateDirectories: true)

            let config = Configuration(
                hostName: hostName,
                path: stateDir,
                authKey: "",                 // empty ⇒ interactive browser login
                controlURL: kDefaultControlURL,
                ephemeral: false             // persist identity across launches
            )

            let pipe = Pipe()
            logPipe = pipe
            let newNode = try TailscaleNode(config: config, logger: LogPipeLogger(pipe: pipe))
            node = newNode

            // Must happen BEFORE up() — see cachedLoopback.
            cachedLoopback = try await newNode.loopback()

            // WHY one shared task: concurrent TsnetUp calls against the same Go server handle
            // produce TailscaleError(3). Retries must await THIS task, never start another.
            //
            // WHY [weak newNode]: a strong capture keeps the Go server alive past a reset,
            // holding the state-dir lock so the next login attempt fails. Weak lets
            // TailscaleNode.deinit → TsnetClose fire as soon as `node` is cleared.
            //
            // WHY addrs() inside the task: TailscaleIPs() contends with up() at the Go level.
            // Called from outside, right after up() returns, it hangs. Called here it doesn't.
            upTask = Task { [weak self, weak newNode] in
                guard let newNode else { return }
                try await newNode.up()
                let ip = try await newNode.addrs().ip4 ?? ""
                await self?.markConnected(ip: ip)
            }
        } catch {
            // WHY this cleanup: without it the next attempt hits the `node != nil` early
            // return above, reuses the failed node, and "Try Again" becomes a silent no-op.
            upTask?.cancel()
            upTask = nil
            try? await node?.close()
            node = nil
            logPipe = nil
            cachedLoopback = nil
            state = .failed(String(describing: error))
            throw error
        }
    }

    private func markConnected(ip: String) {
        state = ip.isEmpty ? .failed("node came up without an IPv4 address") : .connected(ip: ip)
    }

    /// Awaits the in-flight bring-up, surfacing any error from `up()`.
    func awaitUp() async throws {
        guard let upTask else { throw TailscaleNodeError.notStarted }
        try await upTask.value
    }

    /// The in-flight bring-up task.
    ///
    /// Handed to `WebAuthLogin.present(url:dismissWhen:)` so the login sheet can dismiss
    /// itself the moment the node reaches Running — Tailscale never redirects back to the
    /// app, so completion has to be observed from the node, not from the browser.
    func currentUpTask() -> Task<Void, Error>? { upTask }

    /// tsnet's log stream, line by line.
    ///
    /// Match on these two lines to drive a login UI:
    ///   `control: AuthURL is https://…`      → first run, open this URL in a browser
    ///   `Switching ipn state … -> Running`   → already authorised, skip the browser
    ///
    /// WHY not the friendlier banner: `"To start this tsnet server… go to:"` is written to a
    /// DIFFERENT file descriptor and never reaches this pipe. Matching on it looks correct
    /// and silently never fires.
    nonisolated func logLines(_ pipe: Pipe) -> AsyncLineSequence<FileHandle.AsyncBytes> {
        pipe.fileHandleForReading.bytes.lines
    }

    func currentLogPipe() -> Pipe? { logPipe }

    /// Extracts the interactive auth URL from a tsnet log line, if present.
    nonisolated func authURL(from line: String) -> URL? {
        guard let r = line.range(of: "AuthURL is ") else { return nil }
        return URL(string: String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// True when a log line reports the node reached the Running state.
    nonisolated func reportsRunning(_ line: String) -> Bool {
        line.contains("Switching ipn state") && line.contains("-> Running")
    }

    /// Tears the node down and deletes persisted identity.
    ///
    /// WHY the state dir is removed: see `stateDirPath()`. Leaving it means the next login
    /// silently reuses old credentials and never emits an auth URL.
    func signOutAndReset() async {
        upTask?.cancel()
        upTask = nil
        try? await node?.close()
        node = nil
        logPipe = nil
        cachedLoopback = nil
        state = .idle
        try? FileManager.default.removeItem(atPath: Self.stateDirPath())
    }
}

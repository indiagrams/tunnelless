// DiagnosticProbes.swift
//
// Launch-argument probes that measure what the app can actually reach on a physical
// device. They exist because this project's central claims are not observable from the
// Simulator, and because the LocalAPIClient bug in TAILSCALE.md §1 was misdiagnosed
// twice by measuring only after the node reached Running.
//
//   -probe <host:port>   GET through the node's SOCKS5 proxy to a tailnet peer
//   -localapi            direct GET /localapi/v0/status at the loopback listener
//   -localapiclient      the real LocalAPIClient.backendStatus(), after Running
//   -duringup            both LocalAPI arms *while up() is still in flight*
//
// -duringup is the one that matters: up() holds the TailscaleNode actor for the whole
// login, and everything else is measured after it has let go.

import Foundation
import TailscaleKit

@MainActor
extension DemoModel {
    /// Launch with `-probe <host:port>` to GET `http://<host:port>/` through the node's
    /// SOCKS5 proxy and log the outcome.
    ///
    /// This answers the one question the simulator cannot: whether app traffic actually
    /// traverses the tailnet on a physical device. `LocalAPIClient` is known to hang on
    /// device (see TAILSCALE.md), and it reaches the LocalAPI *through this same loopback
    /// listener* — so whether ordinary SOCKS5 forwarding also hangs, or only the LocalAPI
    /// path does, determines what this app can be built on.
    func probeResult(_ text: String) {
        NSLog("[probe] %@", text)
    }

    func runProbeIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-probe"), i + 1 < args.count else { return }
        let target = args[i + 1]
        guard let colon = target.lastIndex(of: ":"),
              let port = UInt16(target[target.index(after: colon)...])
        else {
            probeResult("bad -probe target '\(target)'; expected host:port")
            return
        }
        let host = String(target[..<colon])

        guard let lb = await manager.cachedLoopback,
              let client = SOCKS5Client(loopbackAddress: lb.address, credential: lb.proxyCredential)
        else {
            probeResult("no loopback config; cannot build SOCKS5 client")
            return
        }

        probeResult("dialing \(host):\(port) via SOCKS5 \(lb.address)")
        let started = Date()
        do {
            let response = try await client.get(host: host, port: port)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let firstLine = response.split(separator: "\r\n").first.map(String.init) ?? "<empty>"
            let ok = response.contains("TUNNELLESS_SOCKS_PROBE_OK")
            probeResult("RESULT \(ok ? "OK" : "UNEXPECTED") in \(ms)ms — \(firstLine)")
            probeResult("body-contains-token=\(ok) bytes=\(response.utf8.count)")
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            probeResult("RESULT FAILED in \(ms)ms — \(String(describing: error))")
        }
    }

    /// Launch with `-localapi` to hit `/localapi/v0/status` directly, bypassing
    /// `LocalAPIClient` entirely.
    ///
    /// TAILSCALE.md records that every `LocalAPIClient` call hangs forever on device. The
    /// SOCKS5 probe proves the same loopback listener forwards fine, so this isolates
    /// which side owns the bug: if a raw request with the documented credentials returns,
    /// the fault is in `LocalAPIClient`, and peer data is reachable after all.
    ///
    /// Per vendor/libtailscale/tailscale.h the LocalAPI requires BOTH a
    /// `Sec-Tailscale: localapi` header AND basic auth with local_api_cred as the password.
    func runLocalAPIProbeIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-localapi") else { return }
        guard let lb = await manager.cachedLoopback else {
            probeResult("localapi: no loopback config")
            return
        }
        guard let url = URL(string: "http://\(lb.address)/localapi/v0/status") else {
            probeResult("localapi: bad url from address '\(lb.address)'")
            return
        }

        var req = URLRequest(url: url)
        req.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
        let basic = Data(":\(lb.localAPIKey)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        // A short timeout is the whole point: the documented symptom is an
        // indefinite hang with no error, which is indistinguishable from a very
        // slow call unless we bound it.
        req.timeoutInterval = 15

        probeResult("localapi: GET \(url.absoluteString)")
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            probeResult("localapi: RESULT HTTP \(code) in \(ms)ms, \(data.count) bytes")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let peers = (json["Peer"] as? [String: Any])?.count ?? 0
                probeResult("localapi: BackendState=\(json["BackendState"] ?? "?") peers=\(peers)")
            } else {
                probeResult("localapi: body head — \(String(bytes: data.prefix(200), encoding: .utf8) ?? "<non-utf8>")")
            }
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            probeResult("localapi: RESULT FAILED in \(ms)ms — \(String(describing: error))")
        }
    }

    /// Launch with `-localapiclient` to call the real `LocalAPIClient.backendStatus()`.
    ///
    /// This is the before/after for the upstream fix. Against a stock TailscaleKit this
    /// never returns — the call is routed through the SOCKS5 proxy at the loopback address
    /// that proxy is bound to. Against a patched build it should return like any other
    /// HTTP call. The 20s race exists because the failure mode is an indefinite hang, not
    /// an error: without a bound, "broken" and "slow" look identical.
    func runLocalAPIClientProbeIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-localapiclient") else { return }
        guard let node = await manager.currentNode() else {
            probeResult("localapiclient: no node")
            return
        }

        probeResult("localapiclient: calling LocalAPIClient.backendStatus()")
        let started = Date()
        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let client = LocalAPIClient(localNode: node, logger: nil)
                    let status = try await client.backendStatus()
                    return "OK BackendState=\(status.BackendState) peers=\(status.Peer?.count ?? 0)"
                } catch {
                    return "THREW \(String(describing: error))"
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let result {
            probeResult("localapiclient: RESULT \(result) in \(ms)ms")
        } else {
            probeResult("localapiclient: RESULT HUNG — no return after \(ms)ms")
        }
    }

    /// Launch with `-peers` to exercise the peer dashboard's data path end to end:
    /// TailnetStatusClient's typed decode plus the ordering in `peerRows()`.
    ///
    /// Worth its own probe because the risky part is invisible from the UI: the earlier
    /// `-localapi` probe parsed with JSONSerialization, so `IpnState.Status`'s Codable
    /// conformance against a real response had never actually been run. A single
    /// mismatched field would throw and the list would render empty with an error.
    func runPeerProbeIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-peers") else { return }
        guard let lb = await manager.cachedLoopback else {
            probeResult("peers: no loopback config")
            return
        }
        let started = Date()
        do {
            let status = try await TailnetStatusClient(loopback: lb).status()
            let rows = status.peerRows()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let tailnet = status.CurrentTailnet?.Name ?? "?"
            probeResult("peers: decoded \(rows.count) in \(ms)ms tailnet=\(tailnet) health=\(status.Health?.count ?? 0)")
            let flags = rows.map(\.online)
            probeResult("peers: \(flags.filter { $0 }.count) online; online-first=\(flags == flags.sorted { $0 && !$1 })")
            for row in rows.prefix(4) {
                let up = row.online ? "UP  " : "down"
                let sub = row.subtitle ?? "-"
                let ip = row.ipv4 ?? "-"
                probeResult("peers:   \(up) \(row.displayName) ip=\(ip) sub=\(sub) route=\(row.route ?? "-")")
            }
        } catch {
            probeResult("peers: FAILED in \(Int(Date().timeIntervalSince(started) * 1000))ms — \(String(describing: error))")
        }
    }

    /// Launch with `-duringup` to probe the LocalAPI *while `up()` is still in flight*.
    ///
    /// Discriminates two candidate causes of the documented "LocalAPIClient hangs on
    /// device" symptom, which after-Running measurements cannot tell apart:
    ///
    /// - **Actor deadlock.** `LocalAPIClient` obtains its loopback config via
    ///   `proxyVia()` → `await node.loopback()`. `up()` is a blocking C call that holds
    ///   the `TailscaleNode` actor for the whole login flow (TAILSCALE.md §2), so that
    ///   await queues behind it and never returns.
    /// - **Proxy routing.** The request is routed through the SOCKS5 proxy at the
    ///   loopback address the proxy itself is bound to.
    ///
    /// The direct-HTTP arm uses `cachedLoopback`, captured *before* `up()` ran, so it
    /// touches no actor. If direct HTTP answers while LocalAPIClient hangs, the cause is
    /// the actor, not the routing.
    func runDuringUpProbesIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-duringup") else { return }

        // Arm A — direct HTTP via the pre-cached loopback config. No actor involved.
        let lb = await manager.cachedLoopback
        let statusURL = lb.flatMap { URL(string: "http://\($0.address)/localapi/v0/status") }
        if let lb, let url = statusURL {
            var req = URLRequest(url: url)
            req.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
            req.setValue("Basic " + Data(":\(lb.localAPIKey)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 15
            let t0 = Date()
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let state = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                    .flatMap { $0["BackendState"] as? String } ?? "?"
                probeResult("duringup direct: HTTP \(code) BackendState=\(state) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            } catch {
                probeResult("duringup direct: FAILED in \(Int(Date().timeIntervalSince(t0) * 1000))ms — \(String(describing: error))")
            }
        }

        // Arm B — the real LocalAPIClient, which must await node.loopback() internally.
        guard let node = await manager.currentNode() else {
            probeResult("duringup client: no node")
            return
        }
        let t1 = Date()
        let outcome = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let status = try await LocalAPIClient(localNode: node, logger: nil).backendStatus()
                    return "OK BackendState=\(status.BackendState)"
                } catch {
                    return "THREW \(String(describing: error))"
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let ms = Int(Date().timeIntervalSince(t1) * 1000)
        probeResult("duringup client: " + (outcome.map { "\($0) in \(ms)ms" } ?? "HUNG — no return after \(ms)ms"))
    }
}

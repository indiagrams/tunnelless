// SOCKS5Client.swift
//
// A minimal SOCKS5 client for the proxy tsnet exposes on loopback.
//
// WHY this exists rather than URLSession: `URLSession.connectionProxyDictionary`
// honours only the HTTP/HTTPS proxy keys on iOS. The SOCKS keys
// (`kCFStreamPropertySOCKSProxyHost` / `…Port`) are accepted without error and
// then ignored, so a URLSession "through the proxy" silently goes out over the
// normal interface instead — it appears to work while never touching the
// tailnet. Speaking SOCKS5 ourselves over an NWConnection is the only way to
// route app traffic through tsnet's loopback proxy.
//
// Auth is username/password per vendor/libtailscale/tailscale.h: the username is
// literally "tsnet" and the password is LoopbackConfig.proxyCredential.

import Foundation
import Network

enum SOCKS5Error: Error, Equatable {
    case notReady(String)
    case methodRejected(UInt8)
    case authRejected(UInt8)
    case connectRejected(UInt8)
    case shortRead
    case badReply
    case timedOut
}

struct SOCKS5Client: Sendable {
    /// tailscale.h: "Authentication is required with the username \"tsnet\"".
    static let username = "tsnet"

    let proxyHost: String
    let proxyPort: UInt16
    let credential: String

    init?(loopbackAddress: String, credential: String) {
        // LoopbackConfig.address is "host:port".
        guard let idx = loopbackAddress.lastIndex(of: ":"),
              let port = UInt16(loopbackAddress[loopbackAddress.index(after: idx)...])
        else { return nil }
        proxyHost = String(loopbackAddress[..<idx])
        proxyPort = port
        self.credential = credential
    }

    /// Performs a plain HTTP/1.1 GET against `host:port` through the proxy and
    /// returns the raw response (headers included).
    ///
    /// Deliberately raw rather than URLSession-backed: the point is to prove that
    /// bytes traverse the tailnet, with nothing in between that could quietly
    /// fall back to the normal interface.
    func get(host: String, port: UInt16, path: String = "/", timeout: TimeInterval = 20) async throws -> String {
        let conn = try await openTunnel(host: host, port: port, timeout: timeout)
        defer { conn.cancel() }

        // Tunnelled HTTP/1.1. `Connection: close` makes EOF the end-of-body signal,
        // so no chunked/Content-Length parsing is needed here.
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\n" +
            "User-Agent: Tunnelless/probe\r\nConnection: close\r\n\r\n"
        try await Self.send(conn, Data(request.utf8))

        var body = Data()
        while let chunk = try await Self.receiveSome(conn) {
            body.append(chunk)
        }
        return String(bytes: body, encoding: .utf8) ?? ""
    }

    /// Opens a SOCKS5 tunnel to `host:port` and returns the connected socket,
    /// positioned at the start of the tunnelled payload.
    ///
    /// The caller owns the connection and must `cancel()` it.
    func openTunnel(host: String, port: UInt16, timeout: TimeInterval = 20) async throws -> NWConnection {
        let conn = NWConnection(
            host: NWEndpoint.Host(proxyHost),
            port: NWEndpoint.Port(rawValue: proxyPort)!,
            using: .tcp
        )
        let queue = DispatchQueue(label: "socks5.\(UUID().uuidString)")
        conn.start(queue: queue)

        do {
            try await Self.waitReady(conn, timeout: timeout)

            // 1. Greeting — offer username/password (0x02) only. tsnet's proxy always
            //    requires auth, so advertising "no auth" just invites a rejection.
            try await Self.send(conn, Data([0x05, 0x01, 0x02]))
            let greeting = try await Self.receive(conn, exactly: 2)
            guard greeting[0] == 0x05 else { throw SOCKS5Error.badReply }
            guard greeting[1] == 0x02 else { throw SOCKS5Error.methodRejected(greeting[1]) }

            // 2. Username/password auth (RFC 1929).
            var auth = Data([0x01])
            let user = Data(Self.username.utf8), pass = Data(credential.utf8)
            auth.append(UInt8(user.count)); auth.append(user)
            auth.append(UInt8(pass.count)); auth.append(pass)
            try await Self.send(conn, auth)
            let authReply = try await Self.receive(conn, exactly: 2)
            guard authReply[1] == 0x00 else { throw SOCKS5Error.authRejected(authReply[1]) }

            // 3. CONNECT.
            try await Self.send(conn, Self.connectRequest(host: host, port: port))

            let reply = try await Self.receive(conn, exactly: 4)
            guard reply[0] == 0x05 else { throw SOCKS5Error.badReply }
            guard reply[1] == 0x00 else { throw SOCKS5Error.connectRejected(reply[1]) }
            try await Self.drainBoundAddress(conn, addressType: reply[3])

            return conn
        } catch {
            // The tunnel never opened, so no caller can own this socket.
            conn.cancel()
            throw error
        }
    }

    // MARK: - NWConnection bridging

    /// Builds the SOCKS5 CONNECT request.
    ///
    /// Sends the destination as a domain name (0x03) unless it parses as IPv4 —
    /// MagicDNS names must resolve on tsnet's side of the proxy, not ours.
    private static func connectRequest(host: String, port: UInt16) -> Data {
        var req = Data([0x05, 0x01, 0x00])
        if let v4 = ipv4Octets(host) {
            req.append(0x01)
            req.append(contentsOf: v4)
        } else {
            let h = Data(host.utf8)
            req.append(0x03)
            req.append(UInt8(h.count))
            req.append(h)
        }
        req.append(UInt8(port >> 8))
        req.append(UInt8(port & 0xFF))
        return req
    }

    /// Consumes BND.ADDR + BND.PORT so the stream sits at the start of the payload.
    private static func drainBoundAddress(_ conn: NWConnection, addressType: UInt8) async throws {
        switch addressType {
        case 0x01:
            _ = try await receive(conn, exactly: 4 + 2)
        case 0x04:
            _ = try await receive(conn, exactly: 16 + 2)
        case 0x03:
            let len = try await receive(conn, exactly: 1)
            _ = try await receive(conn, exactly: Int(len[0]) + 2)
        default:
            throw SOCKS5Error.badReply
        }
    }

    private static func ipv4Octets(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func waitReady(_ conn: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let done = Resumed()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if done.claim() {
                        k.resume()
                    }
                case let .failed(err):
                    if done.claim() {
                        k.resume(throwing: SOCKS5Error.notReady(String(describing: err)))
                    }
                case .cancelled:
                    if done.claim() {
                        k.resume(throwing: SOCKS5Error.notReady("cancelled"))
                    }
                default:
                    break
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if done.claim() {
                    k.resume(throwing: SOCKS5Error.timedOut)
                }
            }
        }
    }

    private static func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err {
                    k.resume(throwing: err)
                } else {
                    k.resume()
                }
            })
        }
    }

    private static func receive(_ conn: NWConnection, exactly n: Int) async throws -> [UInt8] {
        var out = Data()
        while out.count < n {
            guard let chunk = try await receiveSome(conn, max: n - out.count) else {
                throw SOCKS5Error.shortRead
            }
            out.append(chunk)
        }
        return [UInt8](out)
    }

    private static func receiveSome(_ conn: NWConnection, max: Int = 64 * 1024) async throws -> Data? {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, err in
                if let err {
                    k.resume(throwing: err); return
                }
                if let data, !data.isEmpty {
                    k.resume(returning: data); return
                }
                k.resume(returning: isComplete ? nil : Data())
            }
        }
    }
}

/// One-shot latch so a continuation is resumed exactly once across the
/// state handler and the timeout race.
private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used {
            return false
        }
        used = true
        return true
    }
}

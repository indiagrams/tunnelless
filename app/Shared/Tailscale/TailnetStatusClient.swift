// TailnetStatusClient.swift
//
// Reads tsnet's LocalAPI directly to get tailnet status and the peer list.
//
// WHY not `LocalAPIClient`: it awaits `node.loopback()`, which is actor-isolated, and
// `up()` holds that actor for the entire login flow — so every call blocks until login
// completes (TAILSCALE.md §1). Fixed upstream in libtailscale#58 and carried locally as
// tailscale/patches/0002, but anyone consuming the *published* xcframework still has the
// stock wrapper. Addressing the LocalAPI directly works on both, during login and after.
//
// The loopback config comes from `TailscaleNodeManager.cachedLoopback`, resolved before
// `up()` ran, so nothing here ever touches the node actor.
//
// Credentials are the two documented in vendor/libtailscale/tailscale.h: a
// `Sec-Tailscale: localapi` header AND basic auth with `local_api_cred` as the password.

import Foundation
import TailscaleKit

enum TailnetStatusError: Error {
    case noLoopbackConfig
    case badURL(String)
    case http(Int)
    case decode(String)
}

struct TailnetStatusClient: Sendable {
    let address: String
    let localAPIKey: String

    init(loopback: TailscaleNode.LoopbackConfig) {
        address = loopback.address
        localAPIKey = loopback.localAPIKey
    }

    /// Fetches `/localapi/v0/status`, decoded into TailscaleKit's own model.
    ///
    /// A short timeout is deliberate: the documented failure mode in this area is an
    /// indefinite hang, and a dashboard that spins forever is worse than one that says
    /// it could not read status.
    func status(timeout: TimeInterval = 10) async throws -> IpnState.Status {
        guard let url = URL(string: "http://\(address)/localapi/v0/status") else {
            throw TailnetStatusError.badURL(address)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
        let basic = Data("tsnet:\(localAPIKey)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(code) else {
            throw TailnetStatusError.http(code)
        }

        do {
            return try JSONDecoder().decode(IpnState.Status.self, from: data)
        } catch {
            throw TailnetStatusError.decode(String(describing: error))
        }
    }
}

// MARK: - View model shapes

/// One row in the peer list, flattened from `IpnState.PeerStatus` so the view does no
/// unwrapping and the ordering rules live in one place.
struct TailnetPeer: Identifiable, Sendable, Equatable {
    let id: String
    /// What to show in a list. Prefers the MagicDNS name because `HostName` is whatever
    /// the device calls itself — measured on a real tailnet, three peers reported
    /// "localhost" and two more shared a name, while the MagicDNS name is unique by
    /// construction and is what you actually dial.
    let displayName: String
    /// Shown under the title only when it adds something the MagicDNS name doesn't.
    let subtitle: String?
    let hostName: String
    /// MagicDNS name with the tailnet suffix trimmed — the full form is long and the
    /// suffix is identical for every peer, so it carries no information in a list.
    let shortDNSName: String?
    let ipv4: String?
    let online: Bool
    let isExitNode: Bool
    let offersExitNode: Bool
    let expired: Bool
    let tags: [String]
    /// nil when the peer is unreachable; "direct" or a DERP region otherwise.
    let route: String?

    init(status: IpnState.PeerStatus, magicDNSSuffix: String?) {
        id = status.ID
        hostName = status.HostName
        ipv4 = status.TailscaleIPs?.first { !$0.contains(":") }
        online = status.Online
        isExitNode = status.ExitNode
        offersExitNode = status.ExitNodeOption
        expired = status.Expired ?? false
        tags = status.Tags ?? []

        let dns = status.DNSName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let short: String? = if let suffix = magicDNSSuffix, !suffix.isEmpty, dns.hasSuffix(suffix) {
            String(dns.dropLast(suffix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        } else {
            dns.isEmpty ? nil : dns
        }
        shortDNSName = short

        displayName = short ?? status.HostName
        // Suppress the subtitle when it repeats the title or says nothing: "localhost"
        // is the default a device reports when it has no useful name of its own.
        let host = status.HostName
        subtitle = (host.isEmpty || host == short || host.caseInsensitiveCompare("localhost") == .orderedSame)
            ? nil : host

        // CurAddr is set only for a direct connection; otherwise traffic goes via DERP
        // and Relay names the region. Both empty means no active path.
        if let cur = status.CurAddr, !cur.isEmpty {
            route = "direct"
        } else if let relay = status.Relay, !relay.isEmpty {
            route = "relay \(relay)"
        } else {
            route = nil
        }
    }
}

extension IpnState.Status {
    /// Peers as display rows: online first, then case-insensitive by hostname.
    ///
    /// Online-first matters because a long-lived tailnet accumulates far more offline
    /// records than live ones — this device's own tailnet has 65 peers and 2 online.
    func peerRows() -> [TailnetPeer] {
        let suffix = CurrentTailnet?.MagicDNSSuffix
        return (Peer ?? [:]).values
            .map { TailnetPeer(status: $0, magicDNSSuffix: suffix) }
            .sorted {
                $0.online == $1.online
                    ? $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    : $0.online && !$1.online
            }
    }
}

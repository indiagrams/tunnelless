// SavedService.swift
//
// Bookmarks for things on your tailnet: a NAS admin page, a Grafana instance, a
// router, an internal API.
//
// This is the point of a userspace node. The app has no VPN profile, so no other app
// on the device can reach these addresses — the app has to be the client. A saved
// service is the address plus enough context to fetch it again.

import Foundation

struct SavedService: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// A MagicDNS name or a tailnet IP. Resolved on tsnet's side of the proxy, not ours.
    var host: String
    var port: UInt16
    var path: String

    init(id: UUID = UUID(), name: String, host: String, port: UInt16 = 80, path: String = "/") {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.path = path.hasPrefix("/") ? path : "/" + path
    }

    /// Display form. The scheme is always http: the tunnel is already encrypted by
    /// WireGuard, and TLS to an internal host usually means a self-signed certificate
    /// that a fetch would reject anyway.
    var displayURL: String {
        port == 80 ? "http://\(host)\(path)" : "http://\(host):\(port)\(path)"
    }
}

// MARK: - Storage

enum SavedServiceStore {
    private static let key = "tunnelless.savedServices"
    private static var defaults: UserDefaults {
        .standard
    }

    static func load() -> [SavedService] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedService].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ services: [SavedService]) {
        guard let data = try? JSONEncoder().encode(services) else { return }
        defaults.set(data, forKey: key)
    }

    static func add(_ service: SavedService) {
        var all = load()
        // Replace rather than duplicate when the same address is saved twice — the
        // obvious way to hit this is saving a peer that is already bookmarked.
        if let i = all.firstIndex(where: {
            $0.host == service.host && $0.port == service.port && $0.path == service.path
        }) {
            all[i] = service
        } else {
            all.append(service)
        }
        save(all)
    }

    static func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    static func contains(host: String, port: UInt16) -> Bool {
        load().contains { $0.host == host && $0.port == port }
    }

    static func clear() {
        defaults.removeObject(forKey: key)
    }
}

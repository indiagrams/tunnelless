// TailnetSnapshot.swift
//
// The last known tailnet state, small enough to persist and read from anywhere.
//
// WHY this exists: tsnet runs inside the app process, so nothing outside that process
// can ask it anything. App Intents may be performed while the app is backgrounded, and
// a widget runs in a different process entirely — neither can start a node or query the
// LocalAPI. They read this snapshot instead, which the app writes whenever it learns
// something new.
//
// Storage is `UserDefaults.standard` for now. When the widget extension lands this moves
// to a shared App Group container, which is the only way a separate process can read it.
// That migration is deliberately deferred: an App Group needs a registered identifier and
// an entitlement on both targets, and none of the App Intents work needs it.

import Foundation

struct TailnetSnapshot: Codable, Equatable, Sendable {
    var isConnected: Bool
    var tailnetIP: String?
    var socksProxy: String?
    var tailnetName: String?
    var peerCount: Int
    var onlinePeerCount: Int
    var updatedAt: Date

    static let empty = TailnetSnapshot(
        isConnected: false, tailnetIP: nil, socksProxy: nil, tailnetName: nil,
        peerCount: 0, onlinePeerCount: 0, updatedAt: .distantPast
    )

    /// How stale the snapshot is, in a form worth showing a person.
    ///
    /// Intents and widgets can be read long after the app last ran, and "connected"
    /// from three days ago is a lie worth qualifying rather than repeating.
    var ageDescription: String {
        guard updatedAt != .distantPast else { return "never updated" }
        let seconds = Date().timeIntervalSince(updatedAt)
        if seconds < 90 {
            return "just now"
        }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 1
        f.allowedUnits = [.day, .hour, .minute]
        return (f.string(from: seconds).map { "\($0) ago" }) ?? "recently"
    }
}

// MARK: - Storage

enum TailnetSnapshotStore {
    private static let key = "tunnelless.tailnetSnapshot"

    /// Swapped for a shared App Group suite when the widget extension lands.
    private static var defaults: UserDefaults {
        .standard
    }

    static func load() -> TailnetSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(TailnetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    static func save(_ snapshot: TailnetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// Merges in whatever the caller knows, leaving the rest alone.
    ///
    /// Callers learn different pieces at different times — `connect()` knows the IP and
    /// proxy before any peer has been read, and the peer poll knows counts without
    /// re-deriving connection state. A merge keeps either from clobbering the other.
    static func update(
        isConnected: Bool? = nil,
        tailnetIP: String?? = nil,
        socksProxy: String?? = nil,
        tailnetName: String?? = nil,
        peerCount: Int? = nil,
        onlinePeerCount: Int? = nil
    ) {
        var s = load()
        if let isConnected {
            s.isConnected = isConnected
        }
        if let tailnetIP {
            s.tailnetIP = tailnetIP
        }
        if let socksProxy {
            s.socksProxy = socksProxy
        }
        if let tailnetName {
            s.tailnetName = tailnetName
        }
        if let peerCount {
            s.peerCount = peerCount
        }
        if let onlinePeerCount {
            s.onlinePeerCount = onlinePeerCount
        }
        s.updatedAt = Date()
        save(s)
    }

    static func clear() {
        defaults.removeObject(forKey: key)
    }
}

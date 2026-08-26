// PeerListView.swift
//
// The tailnet seen from inside the app: peers, whether each is reachable, and how.
//
// This is what a userspace node can show that a connection indicator cannot — the app
// is a member of the tailnet, so it can enumerate it. Status comes from the LocalAPI
// directly (see TailnetStatusClient) rather than LocalAPIClient, so it works during
// login as well as after.

import SwiftUI
import TailscaleKit

struct PeerListView: View {
    @State private var model: PeerListModel
    @State private var search = ""

    init(manager: TailscaleNodeManager) {
        _model = State(initialValue: PeerListModel(manager: manager))
    }

    private var visiblePeers: [TailnetPeer] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.peers }
        return model.peers.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.hostName.localizedCaseInsensitiveContains(q)
                || ($0.ipv4?.contains(q) ?? false)
        }
    }

    var body: some View {
        List {
            if let health = model.health, !health.isEmpty {
                Section("Health") {
                    ForEach(health, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let err = model.errorText {
                Section {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                ForEach(visiblePeers) { peer in
                    PeerRow(peer: peer)
                }
            } header: {
                Text(model.headerText)
                    .accessibilityIdentifier(AccessibilityIdentifiers.peerCount)
            } footer: {
                if model.peers.isEmpty, model.errorText == nil {
                    Text("No peers yet. A tailnet with only this node has nothing to show.")
                }
            }
        }
        .searchable(text: $search, prompt: "Host, MagicDNS name, or IP")
        .refreshable { await model.reload() }
        .navigationTitle(model.tailnetName ?? "Tailnet")
        .task { await model.startPolling() }
        .onDisappear { model.stopPolling() }
    }
}

private struct PeerRow: View {
    let peer: TailnetPeer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(peer.online ? .green : .secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName)
                    .font(.body.weight(.medium))

                if let subtitle = peer.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let ip = peer.ipv4 {
                    Text(ip)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 6) {
                    if let route = peer.route {
                        badge(route, tint: peer.route == "direct" ? .green : .blue)
                    }
                    if peer.isExitNode {
                        badge("exit node", tint: .purple)
                    } else if peer.offersExitNode {
                        badge("offers exit", tint: .secondary)
                    }
                    if peer.expired {
                        badge("key expired", tint: .orange)
                    }
                    ForEach(peer.tags, id: \.self) { tag in
                        badge(tag.replacingOccurrences(of: "tag:", with: ""), tint: .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier(AccessibilityIdentifiers.peerRow)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Model

@MainActor
@Observable
final class PeerListModel {
    private let manager: TailscaleNodeManager

    private(set) var peers: [TailnetPeer] = []
    private(set) var tailnetName: String?
    private(set) var health: [String]?
    private(set) var errorText: String?

    private var pollTask: Task<Void, Never>?

    init(manager: TailscaleNodeManager) {
        self.manager = manager
    }

    var headerText: String {
        let online = peers.filter(\.online).count
        return peers.isEmpty ? "Peers" : "\(online) online of \(peers.count)"
    }

    /// Polls status until the view goes away.
    ///
    /// 5s is a deliberate floor: the LocalAPI is local so the call is cheap, but each
    /// response on a large tailnet is ~80 KB of JSON to decode, and nothing in this view
    /// changes faster than a peer coming online.
    func startPolling(every seconds: Double = 5) async {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func reload() async {
        // Screenshot capture has no Tailscale account, so there is no status to read.
        // Same view, same row rendering — only the source of the rows differs.
        if DemoData.isEnabled {
            peers = DemoData.peers
            tailnetName = DemoData.tailnetName
            health = nil
            errorText = nil
            return
        }

        guard let loopback = await manager.cachedLoopback else {
            errorText = "Node has not started yet."
            return
        }
        do {
            let status = try await TailnetStatusClient(loopback: loopback).status()
            peers = status.peerRows()
            tailnetName = status.CurrentTailnet?.Name
            // Feeds App Intents (and, later, the widget), which cannot query tsnet.
            TailnetSnapshotStore.update(
                tailnetName: status.CurrentTailnet?.Name,
                peerCount: peers.count,
                onlinePeerCount: peers.filter(\.online).count
            )
            // Health is nil when fine; an empty array would render an empty section.
            health = (status.Health?.isEmpty ?? true) ? nil : status.Health
            errorText = nil
        } catch {
            errorText = "Could not read tailnet status — \(String(describing: error))"
        }
    }
}

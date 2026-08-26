// ServiceReaderView.swift
//
// Fetches a saved service through the node's SOCKS5 proxy and renders what comes back.
//
// WHY a reader and not a web view: WKWebView cannot use a SOCKS proxy. Pointing one at
// an internal address would silently egress over the normal interface and fail, or worse,
// appear to work while never touching the tailnet. Feeding a WKWebView through a custom
// scheme handler is possible but means proxying every subresource, redirect, and cookie
// by hand, and WebSockets still would not work.
//
// So this renders the response honestly rather than pretending to be a browser: JSON
// pretty-printed, HTML reduced to its text, plain text as-is, anything else described.
// That covers the internal APIs and status pages people actually self-host.

import SwiftUI

struct ServiceReaderView: View {
    let service: SavedService
    let manager: TailscaleNodeManager

    @State private var state: LoadState = .idle

    enum LoadState {
        case idle
        case loading
        case failed(String)
        case loaded(SOCKS5Client.Response, elapsedMS: Int)
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Fetching \(service.displayURL)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case let .failed(message):
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Could not reach this service", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(service.displayURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

            case let .loaded(response, ms):
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        responseHeader(response, ms: ms)
                        Divider()
                        Text(ResponseRenderer.text(for: response))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .accessibilityIdentifier(AccessibilityIdentifiers.serviceBody)
            }
        }
        .navigationTitle(service.name)
        .toolbar {
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .task { await load() }
    }

    private var isLoading: Bool {
        if case .loading = state {
            return true
        }
        return false
    }

    private func responseHeader(_ r: SOCKS5Client.Response, ms: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(r.statusCode)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((200 ..< 300).contains(r.statusCode) ? .green.opacity(0.15) : .orange.opacity(0.15),
                                in: Capsule())
                    .foregroundStyle((200 ..< 300).contains(r.statusCode) ? .green : .orange)
                    .accessibilityIdentifier(AccessibilityIdentifiers.serviceStatus)
                Text(r.reason).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(ms) ms · \(r.body.count) bytes")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(service.displayURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if !r.contentType.isEmpty {
                Text(r.contentType).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func load() async {
        state = .loading
        guard let lb = await manager.cachedLoopback,
              let client = SOCKS5Client(loopbackAddress: lb.address, credential: lb.proxyCredential)
        else {
            state = .failed("The node isn't running, so there's no proxy to reach it through.")
            return
        }
        let started = Date()
        do {
            let response = try await client.fetch(host: service.host, port: service.port, path: service.path)
            state = .loaded(response, elapsedMS: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

// MARK: - Rendering

/// Turns a response body into something worth reading.
///
/// Kept separate from the view so it can be tested without a tailnet.
enum ResponseRenderer {
    static func text(for response: SOCKS5Client.Response) -> String {
        let body = response.body
        guard !body.isEmpty else { return "(empty response)" }

        switch response.contentType {
        case "application/json", "text/json":
            return prettyJSON(body) ?? response.bodyText
        case "text/html", "application/xhtml+xml":
            return htmlToText(response.bodyText)
        case let t where t.hasPrefix("text/"):
            return response.bodyText
        default:
            // Might still be text with a wrong or missing content-type — a lot of
            // self-hosted endpoints send octet-stream for JSON.
            if let json = prettyJSON(body) {
                return json
            }
            let decoded = response.bodyText
            return decoded.isEmpty
                ? "(\(body.count) bytes of \(response.contentType.isEmpty ? "unknown type" : response.contentType))"
                : decoded
        }
    }

    static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
              )
        else { return nil }
        return String(bytes: pretty, encoding: .utf8)
    }

    /// Strips markup to readable text.
    ///
    /// Deliberately simple. script and style contents are dropped entirely — otherwise
    /// a dashboard's JavaScript dwarfs its actual content — then tags are removed and
    /// the handful of entities that survive that are decoded.
    static func htmlToText(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "head"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        s = s.replacingOccurrences(of: "<br[^>]*>|</p>|</div>|</li>|</tr>|</h[1-6]>",
                                   with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                        ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")]
        for (entity, char) in entities {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        // Collapse the blank lines that tag removal leaves behind.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n[ \\t]*\n+", with: "\n\n", options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no readable text in this HTML)" : trimmed
    }
}

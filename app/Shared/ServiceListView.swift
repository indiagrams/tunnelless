// ServiceListView.swift
//
// The saved services list: add, open, delete.

import SwiftUI

struct ServiceListView: View {
    let manager: TailscaleNodeManager

    @State private var services: [SavedService] = []
    @State private var isAdding = false

    var body: some View {
        List {
            if services.isEmpty {
                ContentUnavailableView {
                    Label("No saved services", systemImage: "bookmark")
                } description: {
                    Text("Save a device from the tailnet list, or add an address by hand. "
                        + "Only this app can reach them — there's no VPN profile.")
                } actions: {
                    Button("Add service") { isAdding = true }
                }
            } else {
                ForEach(services) { service in
                    NavigationLink {
                        ServiceReaderView(service: service, manager: manager)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name).font(.body.weight(.medium))
                            Text(service.displayURL)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityIdentifiers.serviceRow)
                }
                .onDelete { offsets in
                    for i in offsets {
                        SavedServiceStore.remove(id: services[i].id)
                    }
                    services = SavedServiceStore.load()
                }
            }
        }
        .navigationTitle("Services")
        .toolbar {
            Button { isAdding = true } label: { Image(systemName: "plus") }
                .accessibilityIdentifier(AccessibilityIdentifiers.addServiceButton)
        }
        .sheet(isPresented: $isAdding) {
            ServiceEditor { saved in
                SavedServiceStore.add(saved)
                services = SavedServiceStore.load()
            }
        }
        .onAppear { services = SavedServiceStore.load() }
    }
}

/// Add or edit one service. Also used from the peer list, pre-filled with the peer.
struct ServiceEditor: View {
    var prefilledHost: String?
    var prefilledName: String?
    var onSave: (SavedService) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "80"
    @State private var path = "/"

    init(prefilledHost: String? = nil, prefilledName: String? = nil, onSave: @escaping (SavedService) -> Void) {
        self.prefilledHost = prefilledHost
        self.prefilledName = prefilledName
        self.onSave = onSave
        _host = State(initialValue: prefilledHost ?? "")
        _name = State(initialValue: prefilledName ?? "")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier(AccessibilityIdentifiers.serviceNameField)
                    TextField("Host or tailnet IP", text: $host)
                        .plainTextEntry()
                    TextField("Port", text: $port)
                        .font(.body.monospaced())
                    TextField("Path", text: $path)
                        .plainTextEntry()
                }
                Section {
                    Text("Requests go over your Tailscale network through this app's "
                        + "local proxy. Plain http is correct here — the tunnel is already "
                        + "encrypted, and internal hosts rarely have certificates a client "
                        + "would accept.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add service")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(SavedService(
                            name: name.trimmingCharacters(in: .whitespaces),
                            host: host.trimmingCharacters(in: .whitespaces),
                            port: UInt16(port) ?? 80,
                            path: path.isEmpty ? "/" : path
                        ))
                        dismiss()
                    }
                    .disabled(!isValid)
                    .accessibilityIdentifier(AccessibilityIdentifiers.saveServiceButton)
                }
            }
        }
    }
}

private extension View {
    /// Monospaced, no autocorrect, no autocapitalisation — the right treatment for a
    /// hostname or a path.
    ///
    /// `textInputAutocapitalization` is iOS-only and fails to compile on macOS. These
    /// views are shared, and `make check` runs `--fast`, which builds iOS alone — so the
    /// break only appeared in CI. Wrapping it here keeps the difference in one place
    /// instead of scattering `#if os(iOS)` through the form.
    func plainTextEntry() -> some View {
        let base = autocorrectionDisabled().font(.body.monospaced())
        #if os(iOS)
            return base.textInputAutocapitalization(.never)
        #else
            return base
        #endif
    }
}

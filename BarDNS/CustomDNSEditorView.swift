//
//  CustomDNSEditorView.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//  Based on DNS Easy Switcher by Gregory Linford.
//

import SwiftUI

struct CustomDNSEditorView: View {
    let server: CustomDNSServer?
    var onSave: (CustomDNSServer) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var primaryDNS: String
    @State private var secondaryDNS: String
    @State private var tertiaryDNS: String
    @State private var quaternaryDNS: String

    init(server: CustomDNSServer?, onSave: @escaping (CustomDNSServer) -> Void, onCancel: @escaping () -> Void) {
        self.server = server
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: server?.name ?? "")
        _primaryDNS = State(initialValue: server?.primaryDNS ?? "")
        _secondaryDNS = State(initialValue: server?.secondaryDNS ?? "")
        _tertiaryDNS = State(initialValue: server?.tertiaryDNS ?? "")
        _quaternaryDNS = State(initialValue: server?.quaternaryDNS ?? "")
    }

    private func entries(from field: String) -> [String] {
        field.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func invalidEntries(in field: String) -> [String] {
        entries(from: field).filter { DNSManager.shared.parseDNSServer($0) == nil }
    }

    private func errorText(for field: String) -> String? {
        let invalid = invalidEntries(in: field)
        guard !invalid.isEmpty else { return nil }
        return "Not a valid IPv4/IPv6 address: \(invalid.joined(separator: ", "))"
    }

    private var hasAnyInvalidEntries: Bool {
        !invalidEntries(in: primaryDNS).isEmpty ||
            !invalidEntries(in: secondaryDNS).isEmpty ||
            !invalidEntries(in: tertiaryDNS).isEmpty ||
            !invalidEntries(in: quaternaryDNS).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server == nil ? "Add Custom DNS" : "Edit Custom DNS")
                .font(.headline)

            TextField("Name (e.g. Work DNS)", text: $name)
                .textFieldStyle(.roundedBorder)

            dnsField(placeholder: "Primary DNS (e.g. 8.8.8.8)", text: $primaryDNS)
            dnsField(placeholder: "Secondary DNS (optional)", text: $secondaryDNS)
            dnsField(placeholder: "Third DNS (IPv6 or IPv4, optional)", text: $tertiaryDNS)
            dnsField(placeholder: "Fourth DNS (IPv6 or IPv4, optional)", text: $quaternaryDNS)

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button(server == nil ? "Add" : "Save") {
                    let values = CustomDNSServer(
                        id: server?.id ?? UUID().uuidString,
                        name: name,
                        primaryDNS: primaryDNS,
                        secondaryDNS: secondaryDNS,
                        tertiaryDNS: tertiaryDNS,
                        quaternaryDNS: quaternaryDNS,
                        timestamp: server?.timestamp ?? Date()
                    )
                    onSave(values)
                }
                .keyboardShortcut(.return)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          primaryDNS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          hasAnyInvalidEntries)
            }
        }
        .padding()
        .frame(width: 360)
    }

    @ViewBuilder
    private func dnsField(placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .help("Use comma to add multiple addresses")
            if let error = errorText(for: text.wrappedValue) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

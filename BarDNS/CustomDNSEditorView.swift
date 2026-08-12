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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server == nil ? "Add Custom DNS" : "Edit Custom DNS")
                .font(.headline)

            TextField("Name (e.g. Work DNS)", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Primary DNS (e.g. 8.8.8.8 or 127.0.0.1:5353)", text: $primaryDNS)
                .textFieldStyle(.roundedBorder)
                .help("Use comma to add multiple addresses. For custom ports on IPv4, add colon and port number (e.g., 127.0.0.1:5353)")

            TextField("Secondary DNS (optional)", text: $secondaryDNS)
                .textFieldStyle(.roundedBorder)
                .help("Use comma to add multiple addresses. For custom ports on IPv4, add colon and port number (e.g., 127.0.0.1:5353)")

            TextField("Third DNS (IPv6 or IPv4, optional)", text: $tertiaryDNS)
                .textFieldStyle(.roundedBorder)
                .help("Tip: bracket IPv6 if adding a port, e.g., [2001:4860:4860::8888]:5353")

            TextField("Fourth DNS (IPv6 or IPv4, optional)", text: $quaternaryDNS)
                .textFieldStyle(.roundedBorder)
                .help("Use comma to add multiple IPv6 entries if needed")

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
                          primaryDNS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

//
//  CustomDNSManagerView.swift
//  BarDNS
//
//  Created by Gregory LINFORD on 25/02/2025.
//

import SwiftUI

enum CustomDNSAction {
    case use, edit, delete
}

struct CustomDNSManagerView: View {
    let customServers: [CustomDNSServer]
    @Binding var isCloudflareVisible: Bool
    @Binding var isQuad9Visible: Bool
    @Binding var isAdGuardVisible: Bool
    let onAction: (CustomDNSAction, CustomDNSServer) -> Void
    let onAdd: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manage DNS")
                .font(.headline)
                .padding(.bottom, 4)

            Text("Preset Providers")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Toggle("Cloudflare DNS", isOn: $isCloudflareVisible)
            Toggle("Quad9 DNS", isOn: $isQuad9Visible)
            Toggle("AdGuard DNS", isOn: $isAdGuardVisible)

            Divider()
                .padding(.vertical, 4)

            Text("Custom DNS")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if customServers.isEmpty {
                Text("No custom DNS servers added")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
            } else {
                List {
                    ForEach(customServers) { server in
                        HStack {
                            Text(server.name)
                                .lineLimit(1)

                            Spacer()

                            Button(action: {
                                onAction(.edit, server)
                            }) {
                                Image(systemName: "pencil")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .help("Edit this DNS")
                            .padding(.trailing, 8)

                            Button(action: {
                                onAction(.delete, server)
                            }) {
                                Image(systemName: "trash")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                            .help("Delete this DNS")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(minHeight: 100, maxHeight: 200)
                .listStyle(.plain)
            }

            Button(action: onAdd) {
                Text("Add Custom DNS")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)

            HStack {
                Spacer()
                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.escape)
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(width: 300)
    }
}

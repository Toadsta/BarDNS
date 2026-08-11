//
//  AboutView.swift
//  BarDNS
//
//  Created by Gregory LINFORD on 27/02/2025.
//

import SwiftUI

struct AboutView: View {
    var onClose: () -> Void
    
    private var versionText: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return buildNumber.isEmpty ? "Version \(shortVersion)" : "Version \(shortVersion) (\(buildNumber))"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BarDNS")
                .font(.headline)
            
            Text(versionText)
                .foregroundColor(.secondary)
            
            Link("GitHub — Toadsta/BarDNS", destination: URL(string: "https://github.com/Toadsta/BarDNS")!)
            
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
        .frame(width: 320)
    }
}

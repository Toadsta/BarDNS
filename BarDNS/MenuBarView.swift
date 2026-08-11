//
//  MenuBarView.swift
//  BarDNS
//
//  Created by Gregory LINFORD on 23/02/2025.
//
import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DNSSettings.timestamp) private var dnsSettings: [DNSSettings]
    @Query(sort: \CustomDNSServer.name) private var customServers: [CustomDNSServer]
    @State private var isUpdating = false
    @State private var isSpeedTesting = false
    @State private var pingResults: [DNSSpeedTester.PingResult] = []
    @State private var showingAddDNS = false
    @State private var showingManageDNS = false
    @State private var aboutWindowController: CustomSheetWindowController?
    @State private var selectedServer: CustomDNSServer?
    @State private var windowController: CustomSheetWindowController?
    
    var body: some View {
        Group {
            VStack {
                // Custom DNS servers appear above the presets
                ForEach(customServers) { server in
                    dnsToggleRow(
                        label: getCustomDNSLabelWithPing(server),
                        isOn: dnsSettings.first?.activeCustomDNSID == server.id,
                        action: { activateDNS(type: .custom(server)) }
                    )
                }

                if !customServers.isEmpty {
                    Divider()
                }

                dnsToggleRow(
                    label: getLabelWithPing("Cloudflare DNS", dnsType: .cloudflare),
                    isOn: dnsSettings.first?.isCloudflareEnabled ?? false,
                    action: { activateDNS(type: .cloudflare) }
                )

                dnsToggleRow(
                    label: getLabelWithPing("Quad9 DNS", dnsType: .quad9),
                    isOn: dnsSettings.first?.isQuad9Enabled ?? false,
                    action: { activateDNS(type: .quad9) }
                )

                dnsToggleRow(
                    label: getLabelWithPing("AdGuard DNS", dnsType: .adguard),
                    isOn: dnsSettings.first?.isAdGuardEnabled ?? false,
                    action: { activateDNS(type: .adguard) }
                )

                Divider()

                if !customServers.isEmpty {
                    Button(action: {
                        showManageCustomDNSSheet()
                    }) {
                        Text("Manage Custom DNS")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.vertical, 5)
                    .disabled(isSpeedTesting)
                }

                Button(action: {
                    showAddCustomDNSSheet()
                }) {
                    Text("Add Custom DNS")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .padding(.vertical, 5)
                .disabled(isSpeedTesting)
                
                Divider()
                
                Menu {
                    Button("Disable DNS Override") {
                        if !isUpdating && !isSpeedTesting {
                            isUpdating = true
                            DNSManager.shared.disableDNS { success in
                                if success {
                                    Task { @MainActor in
                                        updateSettings(type: .none)
                                    }
                                }
                                isUpdating = false
                            }
                        }
                    }
                    .disabled(isUpdating || isSpeedTesting)

                    Button(isSpeedTesting ? "Running Speed Test…" : "Run Speed Test") {
                        runSpeedTest()
                    }
                    .disabled(isUpdating || isSpeedTesting)

                    Button(isUpdating ? "Clearing DNS Cache…" : "Clear DNS Cache") {
                        clearDNSCache()
                    }
                    .disabled(isUpdating || isSpeedTesting)
                } label: {
                    Text("Settings")
                }
                .padding(.horizontal)
                .disabled(isSpeedTesting)

                Divider()

                Button("About") {
                    showAboutSheet()
                }
                .padding(.vertical, 5)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .padding(.vertical, 5)
            }
            .padding(.vertical, 5)
        }
        .onAppear {
            ensureSettingsExist()
        }
    }

    @ViewBuilder
    private func dnsToggleRow(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(label, isOn: Binding(
            get: { isOn },
            set: { newValue in
                if newValue && !isUpdating {
                    action()
                }
            }
        ))
        .padding(.horizontal)
        .disabled(isUpdating || isSpeedTesting)
        .overlay(alignment: .trailing) {
            if isSpeedTesting {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                    .padding(.trailing, 8)
            }
        }
    }

    // Helper methods for getting ping results
    private func getLabelWithPing(_ baseLabel: String, dnsType: DNSType) -> String {
        guard !pingResults.isEmpty else { return baseLabel }
        
        switch dnsType {
        case .cloudflare:
            if let result = pingResults.first(where: { $0.dnsName == "Cloudflare" }) {
                return "\(baseLabel) (\(Int(result.responseTime))ms)"
            }
        case .quad9:
            if let result = pingResults.first(where: { $0.dnsName == "Quad9" }) {
                return "\(baseLabel) (\(Int(result.responseTime))ms)"
            }
        case .adguard:
            if let result = pingResults.first(where: { $0.dnsName == "AdGuard" }) {
                return "\(baseLabel) (\(Int(result.responseTime))ms)"
            }
        default:
            break
        }
        
        return baseLabel
    }
    
    
    private func getCustomDNSLabelWithPing(_ server: CustomDNSServer) -> String {
        guard !pingResults.isEmpty else { return server.name }
        
        if let result = pingResults.first(where: { $0.isCustom && $0.customID == server.id }) {
            return "\(server.name) (\(Int(result.responseTime))ms)"
        }
        
        return server.name
    }
    
    // Run DNS speed test
    private func runSpeedTest() {
        guard !isSpeedTesting else { return }
        
        isSpeedTesting = true
        pingResults = []
        
        DNSSpeedTester.shared.testAllDNS(customServers: customServers) { results in
            self.pingResults = results
            self.isSpeedTesting = false
        }
    }
    
    private func showAddCustomDNSSheet() {
        let addView = AddCustomDNSView { newServer in
            if let newServer = newServer {
                modelContext.insert(newServer)
                try? modelContext.save()
                // Automatically activate the new DNS
                activateDNS(type: .custom(newServer))
            }
            windowController?.close()
            windowController = nil
        }
        
        windowController = CustomSheetWindowController(view: addView, title: "Add Custom DNS")
        windowController?.window?.level = .floating
        windowController?.showWindow(nil)
        
        // Position the window relative to the menu bar
        if let window = windowController?.window,
           let screenFrame = NSScreen.main?.frame {
            let windowFrame = window.frame
            let newOrigin = NSPoint(
                x: screenFrame.width - windowFrame.width - 20,
                y: screenFrame.height - 40 - windowFrame.height
            )
            window.setFrameTopLeftPoint(newOrigin)
        }
    }
    
    private func showManageCustomDNSSheet() {
        let manageView = CustomDNSManagerView(customServers: customServers, onAction: { action, server in
            switch action {
            case .edit:
                editCustomDNS(server)
            case .delete:
                modelContext.delete(server)
                try? modelContext.save()
                
                // If this was the active server, disable DNS
                if dnsSettings.first?.activeCustomDNSID == server.id {
                    isUpdating = true
                    DNSManager.shared.disableDNS { success in
                        if success {
                            Task { @MainActor in
                                updateSettings(type: .none)
                            }
                        }
                        isUpdating = false
                    }
                }
            case .use:
                activateDNS(type: .custom(server))
            }
            
            // Don't close the window for .use or .edit actions
            if action == .delete {
                windowController?.close()
                windowController = nil
            }
        }, onClose: {
            windowController?.close()
            windowController = nil
        })
        
        windowController = CustomSheetWindowController(view: manageView, title: "Manage Custom DNS")
        windowController?.window?.level = .floating
        windowController?.showWindow(nil)
        
        // Position the window relative to the menu bar
        if let window = windowController?.window,
           let screenFrame = NSScreen.main?.frame {
            let windowFrame = window.frame
            let newOrigin = NSPoint(
                x: screenFrame.width - windowFrame.width - 20,
                y: screenFrame.height - 40 - windowFrame.height
            )
            window.setFrameTopLeftPoint(newOrigin)
        }
    }
    
    private func showAboutSheet() {
        let aboutView = AboutView {
            aboutWindowController?.close()
            aboutWindowController = nil
        }
        
        aboutWindowController?.close()
        aboutWindowController = CustomSheetWindowController(view: aboutView, title: "About")
        aboutWindowController?.window?.level = .floating
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.center()
    }
    
    private func editCustomDNS(_ server: CustomDNSServer) {
        let editView = EditCustomDNSView(server: server) { updatedServer in
            if let updatedServer = updatedServer {
                // Update existing server properties
                server.name = updatedServer.name
                server.primaryDNS = updatedServer.primaryDNS
                server.secondaryDNS = updatedServer.secondaryDNS
                server.tertiaryDNS = updatedServer.tertiaryDNS
                server.quaternaryDNS = updatedServer.quaternaryDNS
                try? modelContext.save()
                
                // If this was the active server, update DNS settings
                if dnsSettings.first?.activeCustomDNSID == server.id {
                    activateDNS(type: .custom(server))
                }
            }
            
            windowController?.close()
            windowController = nil
        }
        
        windowController?.close()
        
        windowController = CustomSheetWindowController(view: editView, title: "Edit Custom DNS")
        windowController?.window?.level = .floating
        windowController?.showWindow(nil)
        
        // Position the window relative to the menu bar
        if let window = windowController?.window,
           let screenFrame = NSScreen.main?.frame {
            let windowFrame = window.frame
            let newOrigin = NSPoint(
                x: screenFrame.width - windowFrame.width - 20,
                y: screenFrame.height - 40 - windowFrame.height
            )
            window.setFrameTopLeftPoint(newOrigin)
        }
    }
    
    enum DNSType: Equatable {
        case none
        case cloudflare
        case quad9
        case adguard
        case custom(CustomDNSServer)
        
        static func == (lhs: DNSType, rhs: DNSType) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none):
                return true
            case (.cloudflare, .cloudflare):
                return true
            case (.quad9, .quad9):
                return true
            case (.adguard, .adguard):
                return true
            case (.custom(let lServer), .custom(let rServer)):
                return lServer.id == rServer.id
        
            default:
                return false
            }
        }
    }
    
    private func activateDNS(type: DNSType) {
        isUpdating = true
        
        switch type {
        case .cloudflare:
            DNSManager.shared.setPredefinedDNS(dnsServers: DNSManager.shared.cloudflareServers) { success in
                if success {
                    Task { @MainActor in
                        updateSettings(type: type)
                    }
                }
                isUpdating = false
            }
        case .quad9:
            DNSManager.shared.setPredefinedDNS(dnsServers: DNSManager.shared.quad9Servers) { success in
                if success {
                    Task { @MainActor in
                        updateSettings(type: type)
                    }
                }
                isUpdating = false
            }
        case .adguard:
            DNSManager.shared.setPredefinedDNS(dnsServers: DNSManager.shared.adguardServers) { success in
                if success {
                    Task { @MainActor in
                        updateSettings(type: type)
                    }
                }
                isUpdating = false
            }
        case .custom(let server):
            DNSManager.shared.setCustomDNS(servers: server.dnsEntries) { success in
                if success {
                    Task { @MainActor in
                        updateSettings(type: type)
                    }
                }
                isUpdating = false
        
            }
        case .none:
            updateSettings(type: type)
            isUpdating = false
        }
    }
    
    private func updateSettings(type: DNSType) {
        if let settings = dnsSettings.first {
            settings.isCloudflareEnabled = (type == .cloudflare)
            settings.isQuad9Enabled = (type == .quad9)
            settings.isAdGuardEnabled = type == .adguard ? true : nil
            
            
            if case .custom(let server) = type {
                settings.activeCustomDNSID = server.id
            } else {
                settings.activeCustomDNSID = nil
            }
            
            settings.timestamp = Date()
        }
    }
    
    private func ensureSettingsExist() {
        if dnsSettings.isEmpty {
            modelContext.insert(DNSSettings())
            try? modelContext.save()
        }
    }
    
    private func clearDNSCache() {
        if !isUpdating && !isSpeedTesting {
            isUpdating = true
            DNSManager.shared.clearDNSCache { success in
                DispatchQueue.main.async {
                    self.isUpdating = false
                }
            }
        }
    }
}

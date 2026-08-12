//
//  SettingsView.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//

import SwiftUI
import SwiftData
import ServiceManagement
import AppKit

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, dnsProviders, advanced, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .dnsProviders: return "DNS Providers"
            case .advanced: return "Advanced"
            case .about: return "About"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .dnsProviders: return "network"
            case .advanced: return "wrench.and.screwdriver.fill"
            case .about: return "info.circle.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .general: return .gray
            case .dnsProviders: return .blue
            case .advanced: return .purple
            case .about: return .gray
            }
        }
    }

    @State private var selection: Section? = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(section.iconColor.gradient)
                        .frame(width: 22, height: 22)
                        .overlay {
                            Image(systemName: section.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView()
            case .dnsProviders:
                DNSProvidersSettingsView()
            case .advanced:
                AdvancedSettingsView()
            case .about:
                AboutSettingsView()
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}

private struct GeneralSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DNSSettings.timestamp) private var dnsSettings: [DNSSettings]
    @Query(sort: \CustomDNSServer.name) private var customServers: [CustomDNSServer]
    @State private var isUpdating = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showLaunchAtLoginError = false

    private var activeDescription: String {
        guard let settings = dnsSettings.first else { return "Default DNS" }
        if settings.isCloudflareEnabled { return "Cloudflare DNS" }
        if settings.isQuad9Enabled { return "Quad9 DNS" }
        if settings.isAdGuardEnabled ?? false { return "AdGuard DNS" }
        if settings.isGoogleEnabled ?? false { return "Google DNS" }
        if let activeID = settings.activeCustomDNSID,
           let server = customServers.first(where: { $0.id == activeID }) {
            return server.name
        }
        return "Default DNS"
    }

    private var isDefaultDNSActive: Bool {
        guard let settings = dnsSettings.first else { return true }
        return !settings.isCloudflareEnabled &&
            !settings.isQuad9Enabled &&
            !(settings.isAdGuardEnabled ?? false) &&
            !(settings.isGoogleEnabled ?? false) &&
            settings.activeCustomDNSID == nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section {
                HStack {
                    Text("Currently Active")
                    Spacer()
                    Text(activeDescription)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Default DNS")
                    Spacer()
                    if isDefaultDNSActive {
                        Text("Active")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Use Default DNS") {
                            revertToDefault()
                        }
                        .disabled(isUpdating)
                    }
                }
            } footer: {
                Text("Reverts your Mac to the DNS servers provided automatically by your router or ISP.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .alert("Couldn't Update Login Item", isPresented: $showLaunchAtLoginError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("BarDNS couldn't register as a login item. This usually requires the app to be installed in /Applications.")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            showLaunchAtLoginError = true
        }
    }

    private func revertToDefault() {
        guard !isUpdating else { return }
        isUpdating = true
        DNSManager.shared.disableDNS { success in
            if success, let settings = dnsSettings.first {
                Task { @MainActor in
                    settings.resetToDefault()
                    try? modelContext.save()
                }
            }
            isUpdating = false
        }
    }
}

private struct DNSProvidersSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DNSSettings.timestamp) private var dnsSettings: [DNSSettings]
    @Query(sort: \CustomDNSServer.name) private var customServers: [CustomDNSServer]

    @State private var isAddingNew = false
    @State private var editingServer: CustomDNSServer?
    @State private var pendingDelete: CustomDNSServer?
    @State private var showUpdateFailedAlert = false

    var body: some View {
        Form {
            Section {
                Toggle("Cloudflare DNS", isOn: binding(\.isCloudflareVisible))
                Toggle("Google DNS", isOn: binding(\.isGoogleVisible))
                Toggle("Quad9 DNS", isOn: binding(\.isQuad9Visible))
                Toggle("AdGuard DNS", isOn: binding(\.isAdGuardVisible))
            } header: {
                Text("Preset Providers")
            } footer: {
                Text("Turn off a provider to hide it from the menu.")
            }

            Section {
                if customServers.isEmpty {
                    Text("No custom DNS servers added")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customServers) { server in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .lineLimit(1)
                                Text(server.primaryDNS)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if dnsSettings.first?.activeCustomDNSID == server.id {
                                Text("Active")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Menu {
                                Button("Edit") {
                                    editingServer = server
                                }
                                Button("Delete", role: .destructive) {
                                    pendingDelete = server
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .imageScale(.large)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Manage this DNS")
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                HStack {
                    Text("Custom DNS Servers")
                    Spacer()
                    Button {
                        isAddingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            } footer: {
                Text("Custom DNS servers appear above the presets in the menu.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("DNS Providers")
        .sheet(isPresented: $isAddingNew) {
            CustomDNSEditorView(server: nil) { values in
                modelContext.insert(values)
                try? modelContext.save()
                isAddingNew = false
            } onCancel: {
                isAddingNew = false
            }
        }
        .sheet(item: $editingServer) { server in
            CustomDNSEditorView(server: server) { values in
                server.name = values.name
                server.primaryDNS = values.primaryDNS
                server.secondaryDNS = values.secondaryDNS
                server.tertiaryDNS = values.tertiaryDNS
                server.quaternaryDNS = values.quaternaryDNS
                try? modelContext.save()

                // If this server is currently active, push the updated addresses live
                if dnsSettings.first?.activeCustomDNSID == server.id {
                    DNSManager.shared.setCustomDNS(servers: server.dnsEntries) { success in
                        if !success {
                            Task { @MainActor in
                                showUpdateFailedAlert = true
                            }
                        }
                    }
                }
                editingServer = nil
            } onCancel: {
                editingServer = nil
            }
        }
        .confirmationDialog(
            "Delete custom DNS?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let server = pendingDelete {
                    delete(server)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This removes the selected DNS entry from your list.")
        }
        .alert("Couldn't Update DNS", isPresented: $showUpdateFailedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The saved changes didn't take effect on your Mac's network settings. Try again from DNS Providers.")
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<DNSSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { dnsSettings.first?[keyPath: keyPath] ?? true },
            set: { newValue in
                if let settings = dnsSettings.first {
                    settings[keyPath: keyPath] = newValue
                    try? modelContext.save()
                }
            }
        )
    }

    private func delete(_ server: CustomDNSServer) {
        let wasActive = dnsSettings.first?.activeCustomDNSID == server.id
        modelContext.delete(server)
        try? modelContext.save()

        if wasActive, let settings = dnsSettings.first {
            DNSManager.shared.disableDNS { success in
                if success {
                    Task { @MainActor in
                        settings.resetToDefault()
                        try? modelContext.save()
                    }
                }
            }
        }
    }
}

private struct AdvancedSettingsView: View {
    @Query(sort: \CustomDNSServer.name) private var customServers: [CustomDNSServer]
    @State private var isSpeedTesting = false
    @State private var isClearing = false
    @State private var pingResults: [DNSSpeedTester.PingResult] = []

    var body: some View {
        Form {
            Section {
                HStack {
                    Button(isSpeedTesting ? "Running Speed Test…" : "Run Speed Test") {
                        runSpeedTest()
                    }
                    .disabled(isSpeedTesting)

                    if isSpeedTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.leading, 4)
                    }
                }

                if !pingResults.isEmpty {
                    ForEach(pingResults) { result in
                        HStack {
                            Text(result.dnsName)
                            Spacer()
                            Text(result.isSuccess ? "\(Int(result.responseTime))ms" : "Failed")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Speed Test")
            }

            Section {
                Button(isClearing ? "Clearing DNS Cache…" : "Clear DNS Cache") {
                    clearDNSCache()
                }
                .disabled(isClearing)
            } header: {
                Text("Maintenance")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
    }

    private func runSpeedTest() {
        guard !isSpeedTesting else { return }
        isSpeedTesting = true
        pingResults = []
        DNSSpeedTester.shared.testAllDNS(customServers: customServers) { results in
            self.pingResults = results
            self.isSpeedTesting = false
        }
    }

    private func clearDNSCache() {
        guard !isClearing else { return }
        isClearing = true
        DNSManager.shared.clearDNSCache { _ in
            DispatchQueue.main.async {
                isClearing = false
            }
        }
    }
}

private struct AboutSettingsView: View {
    private var versionText: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        return "Version \(shortVersion)"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)

                Text("BarDNS")
                    .font(.title2.bold())

                Text(versionText)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 16)

            Form {
                Section {
                    LabeledContent("GitHub") {
                        Link("Toadsta/BarDNS", destination: URL(string: "https://github.com/Toadsta/BarDNS")!)
                    }
                } footer: {
                    Text("A fork of DNS Easy Switcher by Gregory Linford.")
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("About")
    }
}

//
//  MenuBarView.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//  Based on DNS Easy Switcher by Gregory Linford.
//
import SwiftUI
import SwiftData
import UserNotifications

struct MenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \DNSSettings.timestamp) private var dnsSettings: [DNSSettings]
    @Query(sort: \CustomDNSServer.name) private var customServers: [CustomDNSServer]
    @State private var isUpdating = false

    private var isDefaultDNSActive: Bool {
        guard let settings = dnsSettings.first else { return true }
        return !settings.isCloudflareEnabled &&
            !settings.isQuad9Enabled &&
            !(settings.isAdGuardEnabled ?? false) &&
            !(settings.isGoogleEnabled ?? false) &&
            settings.activeCustomDNSID == nil
    }

    private var hasVisiblePresets: Bool {
        (dnsSettings.first?.isCloudflareVisible ?? true) ||
        (dnsSettings.first?.isQuad9Visible ?? true) ||
        (dnsSettings.first?.isAdGuardVisible ?? true) ||
        (dnsSettings.first?.isGoogleVisible ?? true)
    }

    var body: some View {
        Group {
            VStack {
                // Custom DNS servers appear above the presets
                ForEach(customServers) { server in
                    dnsToggleRow(
                        label: server.name,
                        isOn: dnsSettings.first?.activeCustomDNSID == server.id,
                        action: { activateDNS(type: .custom(server)) }
                    )
                }

                if !customServers.isEmpty && hasVisiblePresets {
                    Divider()
                }

                if dnsSettings.first?.isCloudflareVisible ?? true {
                    dnsToggleRow(
                        label: "Cloudflare DNS",
                        isOn: dnsSettings.first?.isCloudflareEnabled ?? false,
                        action: { activateDNS(type: .cloudflare) }
                    )
                }

                if dnsSettings.first?.isGoogleVisible ?? true {
                    dnsToggleRow(
                        label: "Google DNS",
                        isOn: dnsSettings.first?.isGoogleEnabled ?? false,
                        action: { activateDNS(type: .google) }
                    )
                }

                if dnsSettings.first?.isQuad9Visible ?? true {
                    dnsToggleRow(
                        label: "Quad9 DNS",
                        isOn: dnsSettings.first?.isQuad9Enabled ?? false,
                        action: { activateDNS(type: .quad9) }
                    )
                }

                if dnsSettings.first?.isAdGuardVisible ?? true {
                    dnsToggleRow(
                        label: "AdGuard DNS",
                        isOn: dnsSettings.first?.isAdGuardEnabled ?? false,
                        action: { activateDNS(type: .adguard) }
                    )
                }

                if !customServers.isEmpty || hasVisiblePresets {
                    Divider()
                }

                dnsToggleRow(
                    label: "Default DNS",
                    isOn: isDefaultDNSActive,
                    action: { disableDNSOverride() }
                )

                Divider()

                Menu {
                    Button("Run Speed Test") { openSettings(on: .advanced, autoRunSpeedTest: true) }
                    Button("Clear DNS Cache") { clearDNSCacheShortcut() }
                    Button("Add Custom DNS") { openSettings(on: .dnsProviders, autoAddCustomDNS: true) }
                } label: {
                    Text("Settings")
                } primaryAction: {
                    openWindow(id: "settings")
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
            NetworkMonitor.shared.start(modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bardnsOpenSettingsGeneral)) { _ in
            openWindow(id: "settings")
        }
    }

    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    // A system notification, unlike an alert attached to this view, still reaches the user if the
    // menu bar popover has already closed by the time the async DNS change finishes (e.g. because
    // the Touch ID / admin-password prompt stole focus and dismissed it).
    private func notifyFailure() {
        postNotification(
            title: "Couldn't Update DNS",
            body: "The change didn't take effect on your Mac's network settings. Try again from the menu."
        )
    }

    private func openSettings(on section: SettingsView.Section, autoRunSpeedTest: Bool = false, autoAddCustomDNS: Bool = false) {
        QuickActionStore.shared.pendingSection = section
        QuickActionStore.shared.shouldAutoRunSpeedTest = autoRunSpeedTest
        QuickActionStore.shared.shouldAutoAddCustomDNS = autoAddCustomDNS
        NotificationCenter.default.post(name: .bardnsQuickAction, object: nil)
        openWindow(id: "settings")
    }

    private func clearDNSCacheShortcut() {
        DNSManager.shared.clearDNSCache { _ in }
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
        .disabled(isUpdating)
    }

    enum DNSType: Equatable {
        case none
        case cloudflare
        case quad9
        case adguard
        case google
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
            case (.google, .google):
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
                } else {
                    notifyFailure()
                }
                isUpdating = false
            }
        case .quad9:
            DNSManager.shared.setPredefinedDNS(dnsServers: DNSManager.shared.quad9Servers) { success in
                if success {
                    Task { @MainActor in
                        updateSettings(type: type)
                    }
                } else {
                    notifyFailure()
                }
                isUpdating = false
            }
        case .adguard:
            DNSManager.shared.setPredefinedDNS(dnsServers: DNSManager.shared.adguardServers) { success in
                if success {
                    Task { @MainActor in
                        updateSettings(type: type)
                    }
                } else {
                    notifyFailure()
                }
                isUpdating = false
            }
        case .google:
            DNSManager.shared.setPredefinedDNS(dnsServers: DNSManager.shared.googleServers) { success in
                if success {
                    Task { @MainActor in
                        updateSettings(type: type)
                    }
                } else {
                    notifyFailure()
                }
                isUpdating = false
            }
        case .custom(let server):
            DNSManager.shared.setCustomDNS(servers: server.dnsEntries) { success in
                if success {
                    Task { @MainActor in
                        updateSettings(type: type)
                    }
                } else {
                    notifyFailure()
                }
                isUpdating = false

            }
        case .none:
            updateSettings(type: type)
            isUpdating = false
        }
    }

    private func disableDNSOverride() {
        guard !isUpdating else { return }
        isUpdating = true
        DNSManager.shared.disableDNS { success in
            if success {
                Task { @MainActor in
                    updateSettings(type: .none)
                }
            } else {
                notifyFailure()
            }
            isUpdating = false
        }
    }

    private func updateSettings(type: DNSType) {
        guard let settings = dnsSettings.first else { return }

        if type == .none {
            settings.resetToDefault()
            return
        }

        settings.isCloudflareEnabled = (type == .cloudflare)
        settings.isQuad9Enabled = (type == .quad9)
        settings.isAdGuardEnabled = type == .adguard ? true : nil
        settings.isGoogleEnabled = type == .google ? true : nil

        if case .custom(let server) = type {
            settings.activeCustomDNSID = server.id
        } else {
            settings.activeCustomDNSID = nil
        }

        settings.timestamp = Date()
    }

    private func ensureSettingsExist() {
        if dnsSettings.isEmpty {
            modelContext.insert(DNSSettings())
            try? modelContext.save()
        }
    }
}

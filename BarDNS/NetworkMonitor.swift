//
//  NetworkMonitor.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//

import Foundation
import CoreLocation
import CoreWLAN
import Network
import SwiftData
import Observation

/// Watches which Wi-Fi network is currently joined and, if that network has a
/// saved NetworkDNSProfile, applies its DNS selection automatically.
///
/// Reading the current Wi-Fi SSID on modern macOS requires Location Services
/// authorization (CoreWLAN gates `CWInterface.ssid()` behind it) even though
/// this feature has nothing to do with location — that's a new permission
/// prompt this feature introduces to BarDNS. Mockup scope: this duplicates a
/// small amount of "apply a DNSType and reflect it in DNSSettings" logic that
/// also lives in MenuBarView.updateSettings; worth extracting to a shared
/// spot on DNSSettings itself if this graduates out of beta.
@Observable
final class NetworkMonitor: NSObject {
    static let shared = NetworkMonitor()

    private let locationManager = CLLocationManager()
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.toadsie.BarDNS.NetworkMonitor")
    private var modelContext: ModelContext?
    private var started = false

    var currentNetworkName: String?
    var authorizationStatus: CLAuthorizationStatus

    private override init() {
        authorizationStatus = CLLocationManager().authorizationStatus
        super.init()
        locationManager.delegate = self
    }

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        guard !started else { return }
        started = true
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            self?.refreshCurrentNetwork()
        }
        pathMonitor.start(queue: monitorQueue)
        refreshCurrentNetwork()
    }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func refreshCurrentNetwork() {
        let ssid = CWWiFiClient.shared().interface()?.ssid()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentNetworkName = ssid
            self.applyProfileIfNeeded(for: ssid)
        }
    }

    private func applyProfileIfNeeded(for networkName: String?) {
        guard let networkName, let modelContext else { return }
        let descriptor = FetchDescriptor<NetworkDNSProfile>(
            predicate: #Predicate { $0.networkName == networkName }
        )
        guard let profile = try? modelContext.fetch(descriptor).first else { return }
        applyProfile(profile)
    }

    private func serverList(for type: MenuBarView.DNSType) -> [String]? {
        switch type {
        case .cloudflare: return DNSManager.shared.cloudflareServers
        case .quad9: return DNSManager.shared.quad9Servers
        case .adguard: return DNSManager.shared.adguardServers
        case .google: return DNSManager.shared.googleServers
        default: return nil
        }
    }

    private func applyProfile(_ profile: NetworkDNSProfile) {
        guard let modelContext else { return }
        let customServers = (try? modelContext.fetch(FetchDescriptor<CustomDNSServer>())) ?? []
        let type = profile.resolvedSelection(customServers: customServers)

        switch type {
        case .none:
            DNSManager.shared.disableDNS { [weak self] success in
                if success { self?.reflectActiveSettings(type: .none) }
            }
        case .custom(let server):
            DNSManager.shared.setCustomDNS(servers: server.dnsEntries) { [weak self] success in
                if success { self?.reflectActiveSettings(type: .custom(server)) }
            }
        default:
            guard let servers = serverList(for: type) else { return }
            DNSManager.shared.setPredefinedDNS(dnsServers: servers) { [weak self] success in
                if success { self?.reflectActiveSettings(type: type) }
            }
        }
    }

    /// Mirrors the DNSType into DNSSettings so the menu bar / General tab reflect
    /// what a network-triggered auto-switch just applied, same as a manual switch would.
    private func reflectActiveSettings(type: MenuBarView.DNSType) {
        guard let modelContext else { return }
        guard let settings = try? modelContext.fetch(FetchDescriptor<DNSSettings>()).first else { return }

        Task { @MainActor in
            if type == .none {
                settings.resetToDefault()
            } else {
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
            try? modelContext.save()
        }
    }
}

extension NetworkMonitor: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        refreshCurrentNetwork()
    }
}

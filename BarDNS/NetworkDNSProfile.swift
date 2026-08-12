//
//  NetworkDNSProfile.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//

import Foundation
import SwiftData

@Model
final class NetworkDNSProfile {
    var id: String
    var networkName: String
    /// One of: "cloudflare", "quad9", "adguard", "google", a CustomDNSServer.id, or nil
    /// (meaning "don't override on this network").
    var selection: String?
    var timestamp: Date

    init(id: String = UUID().uuidString,
         networkName: String,
         selection: String? = nil,
         timestamp: Date = Date()) {
        self.id = id
        self.networkName = networkName
        self.selection = selection
        self.timestamp = timestamp
    }
}

extension NetworkDNSProfile {
    /// Resolves this profile's stored selection to a DNSType, given the current
    /// custom server list (needed since custom entries are stored by id).
    func resolvedSelection(customServers: [CustomDNSServer]) -> MenuBarView.DNSType {
        guard let selection else { return .none }
        switch selection {
        case "cloudflare": return .cloudflare
        case "quad9": return .quad9
        case "adguard": return .adguard
        case "google": return .google
        default:
            if let server = customServers.first(where: { $0.id == selection }) {
                return .custom(server)
            }
            return .none
        }
    }

    static func storageKey(for type: MenuBarView.DNSType) -> String? {
        switch type {
        case .none: return nil
        case .cloudflare: return "cloudflare"
        case .quad9: return "quad9"
        case .adguard: return "adguard"
        case .google: return "google"
        case .custom(let server): return server.id
        }
    }
}

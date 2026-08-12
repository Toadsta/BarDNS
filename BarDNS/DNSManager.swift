//
//  DNSManager.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//  Based on DNS Easy Switcher by Gregory Linford.
//

import Foundation
import AppKit
import LocalAuthentication
import Darwin

class DNSManager {
    static let shared = DNSManager()
    
    let cloudflareServers = [
        "1.1.1.1",           // IPv4 Primary
        "1.0.0.1",           // IPv4 Secondary
        "2606:4700:4700::1111",  // IPv6 Primary
        "2606:4700:4700::1001"   // IPv6 Secondary
    ]
    
    let quad9Servers = [
        "9.9.9.9",              // IPv4 Primary
        "149.112.112.112",      // IPv4 Secondary
        "2620:fe::fe",          // IPv6 Primary
        "2620:fe::9"            // IPv6 Secondary
    ]
    
    let adguardServers = [
        "94.140.14.14",       // IPv4 Primary
        "94.140.15.15",       // IPv4 Secondary
        "2a10:50c0::ad1:ff",  // IPv6 Primary
        "2a10:50c0::ad2:ff"   // IPv6 Secondary
    ]

    let googleServers = [
        "8.8.8.8",                // IPv4 Primary
        "8.8.4.4",                // IPv4 Secondary
        "2001:4860:4860::8888",   // IPv6 Primary
        "2001:4860:4860::8844"    // IPv6 Secondary
    ]

    
    private func getNetworkServices() -> [String] {
        let task = Process()
        task.launchPath = "/usr/sbin/networksetup"
        task.arguments = ["-listallnetworkservices"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let services = String(data: data, encoding: .utf8) {
                return services.components(separatedBy: .newlines)
                    .dropFirst() // Drop the header line
                    .filter { !$0.isEmpty && !$0.hasPrefix("*") } // Remove empty lines and disabled services
            }
        } catch {
            print("Error getting network services: \(error)")
        }
        return []
    }
    
    private func findActiveServices() -> [String] {
        let services = getNetworkServices()
        let activeServices = services.filter {
            $0.lowercased().contains("wi-fi") || $0.lowercased().contains("ethernet")
        }
        return activeServices.isEmpty ? [services.first].compactMap { $0 } : activeServices
    }
    
    private func executeWithAuthentication(command: String, completion: @escaping (Bool) -> Void) {
            let context = LAContext()
            context.localizedReason = "BarDNS needs to modify network settings"
            
            var error: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "BarDNS needs to modify network settings") { success, error in
                    if success {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let task = Process()
                            task.launchPath = "/bin/bash"
                            task.arguments = ["-c", command]
                            
                            let pipe = Pipe()
                            task.standardOutput = pipe
                            
                            do {
                                try task.run()
                                task.waitUntilExit()
                                
                                let success = task.terminationStatus == 0
                                DispatchQueue.main.async { completion(success) }
                            } catch {
                                print("Failed to execute command: \(error)")
                                DispatchQueue.main.async { completion(false) }
                            }
                        }
                    } else {
                        print("Authentication failed: \(error?.localizedDescription ?? "Unknown error")")
                        DispatchQueue.main.async { completion(false) }
                    }
                }
            } else {
                // Fall back to AppleScript for admin privileges
                print("Local Authentication not available: \(error?.localizedDescription ?? "Unknown error")")
                
                DispatchQueue.global(qos: .userInitiated).async {
                    let script = """
                    do shell script "\(command)" with administrator privileges
                    """
                    
                    var scriptError: NSDictionary?
                    if let scriptObject = NSAppleScript(source: script) {
                        if scriptObject.executeAndReturnError(&scriptError) != nil {
                            DispatchQueue.main.async { completion(true) }
                        } else {
                            print("AppleScript error: \(scriptError ?? ["error": "Unknown error"] as NSDictionary)")
                            DispatchQueue.main.async { completion(false) }
                        }
                    } else {
                        DispatchQueue.main.async { completion(false) }
                    }
                }
            }
        }
    
    func setPredefinedDNS(dnsServers: [String], completion: @escaping (Bool) -> Void) {
        let services = findActiveServices()
        guard !services.isEmpty else {
            completion(false)
            return
        }
        
        let dispatchGroup = DispatchGroup()
        var allSucceeded = true
        
        for service in services {
            dispatchGroup.enter()
            
            let dnsArgs = dnsServers.joined(separator: " ")
            let dnsCommand = "/usr/sbin/networksetup -setdnsservers '\(service)' \(dnsArgs)"
            let ipv6Command = "/usr/sbin/networksetup -setv6off '\(service)'; /usr/sbin/networksetup -setv6automatic '\(service)'"
            let fullCommand = "\(dnsCommand); \(ipv6Command)"
            
            executeWithAuthentication(command: fullCommand) { success in
                if !success {
                    allSucceeded = false
                }
                dispatchGroup.leave()
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            completion(allSucceeded)
        }
    }
        
    func setCustomDNS(servers rawServers: [String], completion: @escaping (Bool) -> Void) {
        let services = findActiveServices()
        // Allow comma-separated entries in any slot
        let flattenedServers = rawServers
            .flatMap { entry in
                entry
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .filter { !$0.isEmpty }
        let parsedServers = flattenedServers.compactMap(parseDNSServer)
        
        guard !services.isEmpty, !parsedServers.isEmpty else {
            completion(false)
            return
        }
        
        let hasCustomPorts = parsedServers.contains { $0.port != nil }
        
        // If no custom ports are specified, use the standard network setup method
        if !hasCustomPorts {
            let servers = parsedServers.map { $0.address }
            setStandardDNS(services: services, servers: servers, completion: completion)
            return
        }
        
        // For DNS servers with custom ports, we need to modify the resolver configuration
        let resolverContent = createResolverContent(parsedServers)
        
        // We'll use the existing executeWithAuthentication method which properly handles
        // authentication with Touch ID or admin password
        let createDirCmd = "sudo mkdir -p /etc/resolver"
        executeWithAuthentication(command: createDirCmd) { dirSuccess in
            if !dirSuccess {
                print("Failed to create resolver directory")
                completion(false)
                return
            }
            
            // Now write the resolver content
            let writeFileCmd = "echo '\(resolverContent)' | sudo tee /etc/resolver/custom > /dev/null"
            self.executeWithAuthentication(command: writeFileCmd) { fileSuccess in
                if !fileSuccess {
                    print("Failed to write resolver configuration")
                    completion(false)
                    return
                }
                
                // Set permissions
                let permCmd = "sudo chmod 644 /etc/resolver/custom"
                self.executeWithAuthentication(command: permCmd) { permSuccess in
                    if !permSuccess {
                        print("Failed to set resolver file permissions")
                        completion(false)
                        return
                    }
                    
                    // Also set standard DNS servers to ensure proper resolution
                    let standardServers = parsedServers.map { $0.address }
                    self.setStandardDNS(services: services, servers: standardServers, completion: completion)
                }
            }
        }
    }

    private func createResolverContent(_ servers: [(address: String, port: Int?)]) -> String {
        var resolverContent = "# Custom DNS configuration with port\n"
        
        for server in servers {
            resolverContent += "nameserver \(server.address)\n"
            if let port = server.port {
                resolverContent += "port \(port)\n"
            }
        }
        
        return resolverContent
    }

    /// Validates that a string is a real IPv4 or IPv6 address, so nothing else
    /// (shell metacharacters, hostnames, etc.) can reach a shell command built
    /// from user-entered DNS server text.
    func isValidIPAddress(_ address: String) -> Bool {
        var ipv4Addr = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4Addr) }) == 1 {
            return true
        }
        var ipv6Addr = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6Addr) }) == 1 {
            return true
        }
        return false
    }

    func parseDNSServer(_ input: String) -> (address: String, port: Int?)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Support IPv6 with explicit port using bracket notation: [addr]:port
        if trimmed.hasPrefix("["), let closingBracket = trimmed.firstIndex(of: "]") {
            let address = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
            guard isValidIPAddress(address) else { return nil }
            let remainder = trimmed[trimmed.index(after: closingBracket)..<trimmed.endIndex]
            if remainder.hasPrefix(":") {
                let portString = remainder.dropFirst()
                if let port = Int(portString), (1...65535).contains(port) {
                    return (address, port)
                }
            }
            return (address, nil)
        }

        // IPv4 with port (single colon, numeric suffix)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2,
           let port = Int(parts[1]), (1...65535).contains(port),
           !parts[0].contains(":") {
            let address = String(parts[0])
            guard isValidIPAddress(address) else { return nil }
            return (address, port)
        }

        // IPv6 or plain address with no port
        guard isValidIPAddress(trimmed) else { return nil }
        return (trimmed, nil)
    }

    func disableDNS(completion: @escaping (Bool) -> Void) {
        let services = findActiveServices()
        guard !services.isEmpty else {
            completion(false)
            return
        }
        
        // Remove any custom resolver configuration
        let removeResolverCmd = "sudo rm -f /etc/resolver/custom"
        
        executeWithAuthentication(command: removeResolverCmd) { _ in
            // Continue with normal DNS reset regardless of resolver removal success
            let dispatchGroup = DispatchGroup()
            var allSucceeded = true
            
            for service in services {
                dispatchGroup.enter()
                
                let command = "/usr/sbin/networksetup -setdnsservers '\(service)' empty"
                
                self.executeWithAuthentication(command: command) { success in
                    if !success {
                        allSucceeded = false
                    }
                    dispatchGroup.leave()
                }
            }
            
            dispatchGroup.notify(queue: .main) {
                completion(allSucceeded)
            }
        }
    }

    // Helper method to set standard DNS settings
    private func setStandardDNS(services: [String], servers: [String], completion: @escaping (Bool) -> Void) {
        let dispatchGroup = DispatchGroup()
        var allSucceeded = true
        
        for service in services {
            dispatchGroup.enter()
            
            let dnsArgs = servers.joined(separator: " ")
            let dnsCommand = "/usr/sbin/networksetup -setdnsservers '\(service)' \(dnsArgs)"
            let ipv6Command = "/usr/sbin/networksetup -setv6off '\(service)'; /usr/sbin/networksetup -setv6automatic '\(service)'"
            let fullCommand = "\(dnsCommand); \(ipv6Command)"
            
            executeWithAuthentication(command: fullCommand) { success in
                if !success {
                    allSucceeded = false
                }
                dispatchGroup.leave()
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            completion(allSucceeded)
        }
    }

    func clearDNSCache(completion: @escaping (Bool) -> Void) {
        let flushCommand = "dscacheutil -flushcache"
        
        executeWithAuthentication(command: flushCommand) { success in
            if success {
                let restartCommand = "killall -HUP mDNSResponder 2>/dev/null || killall -HUP mdnsresponder 2>/dev/null || true"
                
                self.executeWithAuthentication(command: restartCommand) { _ in
                    completion(success)
                }
            } else {
                completion(false)
            }
        }
    }
}

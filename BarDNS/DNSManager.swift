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
    
    // Applies to every enabled service rather than guessing by name, since VPNs, USB/Thunderbolt
    // adapters, and other non-Wi-Fi/Ethernet-named services can also be the one actually carrying
    // traffic.
    private func findActiveServices() -> [String] {
        getNetworkServices()
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

                            let outputPipe = Pipe()
                            let errorPipe = Pipe()
                            task.standardOutput = outputPipe
                            task.standardError = errorPipe

                            do {
                                try task.run()
                                task.waitUntilExit()

                                let success = task.terminationStatus == 0
                                if !success {
                                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                                    let errorOutput = String(data: errorData, encoding: .utf8)?
                                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                    print("Command failed (exit \(task.terminationStatus)): \(command)\n\(errorOutput)")
                                }
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
        setStandardDNS(services: services, servers: dnsServers, completion: completion)
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

        setStandardDNS(services: services, servers: parsedServers, completion: completion)
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

    /// Validates a plain IPv4/IPv6 address. macOS's system-wide DNS config has no way to honor a
    /// non-standard port, so custom DNS entries only ever support bare addresses.
    func parseDNSServer(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isValidIPAddress(trimmed) else { return nil }
        return trimmed
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
            var anySucceeded = false

            for service in services {
                dispatchGroup.enter()

                let command = "/usr/sbin/networksetup -setdnsservers '\(service)' empty"

                self.executeWithAuthentication(command: command) { success in
                    if success {
                        anySucceeded = true
                    }
                    dispatchGroup.leave()
                }
            }

            dispatchGroup.notify(queue: .main) {
                completion(anySucceeded)
            }
        }
    }

    // Applies DNS settings to every enabled service, but reports success as long as at least one
    // service accepted it — an inactive/virtual service (e.g. Thunderbolt Bridge, iPhone USB when
    // not connected) failing shouldn't block a change that succeeded on the interface actually
    // carrying traffic.
    private func setStandardDNS(services: [String], servers: [String], completion: @escaping (Bool) -> Void) {
        let dispatchGroup = DispatchGroup()
        var anySucceeded = false

        for service in services {
            dispatchGroup.enter()

            let dnsArgs = servers.joined(separator: " ")
            let dnsCommand = "/usr/sbin/networksetup -setdnsservers '\(service)' \(dnsArgs)"
            let ipv6Command = "/usr/sbin/networksetup -setv6off '\(service)'; /usr/sbin/networksetup -setv6automatic '\(service)'"
            let fullCommand = "\(dnsCommand); \(ipv6Command)"

            executeWithAuthentication(command: fullCommand) { success in
                if success {
                    anySucceeded = true
                }
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            completion(anySucceeded)
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

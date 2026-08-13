//
//  DNSManager.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//  Based on DNS Easy Switcher by Gregory Linford.
//

import Foundation
import Darwin
import os

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

    private static let networksetup = "/usr/sbin/networksetup"
    private static let dscacheutil = "/usr/bin/dscacheutil"
    private static let killall = "/usr/bin/killall"
    private static let osascript = "/usr/bin/osascript"

    /// Prefix of the explanatory first line of `networksetup -listallnetworkservices` output.
    private static let servicesHeaderPrefix = "An asterisk"

    private let log = Logger(subsystem: "com.toadsie.BarDNS", category: "DNSManager")

    /// Serial, so two quick menu clicks can never stack two authorization prompts on top of
    /// each other, and so the one-at-a-time assumption below always holds.
    private let workQueue = DispatchQueue(label: "com.toadsie.BarDNS.dns", qos: .userInitiated)

    // MARK: - Running commands

    private struct CommandResult {
        let status: Int32
        let output: String
        let errorOutput: String

        var succeeded: Bool { status == 0 }
    }

    /// Runs a tool with an explicit argument vector.
    ///
    /// No shell is involved, so nothing in `arguments` — a network service name containing an
    /// apostrophe, a DNS address, anything — can be reinterpreted as shell syntax.
    private func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            log.error("Could not launch \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return CommandResult(status: -1, output: "", errorOutput: error.localizedDescription)
        }

        // Drain both pipes concurrently before reaping. Reading one to EOF and only then the
        // other deadlocks if the tool fills the pipe nobody is draining yet.
        var outputData = Data()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            drain.leave()
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        drain.wait()
        task.waitUntilExit()

        return CommandResult(
            status: task.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? "",
            errorOutput: (String(data: errorData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Privileged execution

    /// Marks each invocation's exit status in the privileged batch's output.
    private static let statusMarker = "__BARDNS_STATUS__"

    /// Wraps an argument in POSIX shell single quotes.
    ///
    /// Only needed for the privileged path: `do shell script` has no argument-vector form and
    /// can be handed nothing but a command string, so the quoting `Process` gives us for free
    /// has to be done by hand there.
    static func shellQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for use as an AppleScript string literal. Backslashes first, so the
    /// backslashes introduced by quote-escaping aren't escaped a second time.
    static func appleScriptQuoted(_ string: String) -> String {
        "\"" + string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    /// Runs several tool invocations as root under a *single* administrator authorization,
    /// returning one exit status per invocation, in order.
    ///
    /// Each invocation echoes its own exit status behind a marker rather than relying on the
    /// batch's overall status: chaining with `;` reports only the last command's result, which
    /// would hide exactly the failure we care about, and chaining with `&&` would abort the
    /// whole batch on the first inactive interface.
    ///
    /// Returns nil if authorization was refused or cancelled, or if the output couldn't be
    /// matched up to the invocations.
    private func runPrivileged(_ invocations: [[String]]) -> [Int32]? {
        guard !invocations.isEmpty else { return [] }

        let shellCommand = invocations
            .map { invocation in
                invocation.map(Self.shellQuoted).joined(separator: " ")
                    + "; /bin/echo \(Self.statusMarker)$?"
            }
            .joined(separator: "; ")

        let script = "do shell script \(Self.appleScriptQuoted(shellCommand)) with administrator privileges"

        // `osascript` as a subprocess rather than in-process NSAppleScript: the script text
        // travels as a single argv element that nothing re-parses, and NSAppleScript's
        // thread-safety and reentrancy caveats stop applying altogether.
        //
        // AuthorizationExecuteWithPrivileges would be the more direct route, but Swift marks it
        // unavailable outright ("APIs deprecated as of macOS 10.9 and earlier"), so reaching it
        // needs a dlsym hack or an Objective-C bridge.
        let result = run(Self.osascript, ["-e", script])
        guard result.succeeded else {
            // -128 is AppleScript's "user cancelled", which is a decision rather than a fault.
            if result.errorOutput.contains("-128") {
                log.info("Administrator authorization was cancelled")
            } else {
                log.error("Privileged execution failed (exit \(result.status)): \(result.errorOutput, privacy: .public)")
            }
            return nil
        }

        // `do shell script` hands multi-line output back with carriage-return separators, so
        // split on the whole newline set rather than on "\n".
        let statuses = result.output
            .components(separatedBy: .newlines)
            .compactMap { line -> Int32? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(Self.statusMarker) else { return nil }
                return Int32(trimmed.dropFirst(Self.statusMarker.count))
            }

        guard statuses.count == invocations.count else {
            log.error("Privileged batch returned \(statuses.count) statuses for \(invocations.count) commands")
            return nil
        }
        return statuses
    }

    // MARK: - Network services

    /// Every network service macOS reports as enabled.
    ///
    /// Applies to all of them rather than guessing by name, since VPNs, USB/Thunderbolt
    /// adapters, and other non-Wi-Fi/Ethernet-named services can also be the one actually
    /// carrying traffic.
    private func enabledNetworkServices() -> [String] {
        let result = run(Self.networksetup, ["-listallnetworkservices"])
        guard result.succeeded else {
            log.error("Could not list network services (exit \(result.status)): \(result.errorOutput, privacy: .public)")
            return []
        }

        return result.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                // Drop the header only when it really is the header. Dropping the first line
                // unconditionally would silently swallow a real service if the output ever
                // arrives without one. A leading asterisk marks a disabled service.
                !line.isEmpty
                    && !line.hasPrefix("*")
                    && !line.hasPrefix(Self.servicesHeaderPrefix)
            }
    }

    // MARK: - Applying DNS

    func setPredefinedDNS(dnsServers: [String], completion: @escaping (Bool) -> Void) {
        // The preset lists are hardcoded, but they go through the same validation as user
        // input so a typo in a future preset can't reach a command builder unchecked.
        applyDNS(servers: dnsServers.compactMap(parseDNSServer), completion: completion)
    }

    func setCustomDNS(servers rawServers: [String], completion: @escaping (Bool) -> Void) {
        // Allow comma-separated entries in any slot
        let parsedServers = rawServers
            .flatMap { $0.split(separator: ",").map(String.init) }
            .compactMap(parseDNSServer)

        applyDNS(servers: parsedServers, completion: completion)
    }

    private func applyDNS(servers: [String], completion: @escaping (Bool) -> Void) {
        guard !servers.isEmpty else {
            log.error("Refusing to apply an empty DNS server list")
            DispatchQueue.main.async { completion(false) }
            return
        }

        applyToEachService(arguments: { service in
            ["-setdnsservers", service] + servers
        }, completion: completion)
    }

    func disableDNS(completion: @escaping (Bool) -> Void) {
        applyToEachService(arguments: { service in
            ["-setdnsservers", service, "empty"]
        }, completion: completion)
    }

    /// Runs one `networksetup` invocation per enabled service and reports whether the change
    /// landed anywhere.
    ///
    /// Success means "at least one service accepted it": an inactive or virtual service
    /// (Thunderbolt Bridge, iPhone USB with nothing plugged in) refusing shouldn't mask a
    /// change that took on the interface actually carrying traffic.
    ///
    /// The unprivileged attempt comes first because `networksetup` accepts network changes
    /// from members of the admin group, which covers the overwhelming majority of Macs and
    /// needs no prompt at all. Only a run where *nothing* landed escalates, and then every
    /// refused service is retried together under one authorization — so a standard (non-admin)
    /// account gets a single honest password prompt instead of the previous silent dead end.
    private func applyToEachService(arguments: @escaping (String) -> [String],
                                    completion: @escaping (Bool) -> Void) {
        workQueue.async { [self] in
            let services = enabledNetworkServices()
            guard !services.isEmpty else {
                log.error("No enabled network services found")
                DispatchQueue.main.async { completion(false) }
                return
            }

            var anySucceeded = false
            var refused: [[String]] = []

            for service in services {
                let serviceArguments = arguments(service)
                let result = run(Self.networksetup, serviceArguments)
                if result.succeeded {
                    anySucceeded = true
                } else {
                    log.error("networksetup failed for \(service, privacy: .public) (exit \(result.status)): \(result.errorOutput, privacy: .public)")
                    refused.append([Self.networksetup] + serviceArguments)
                }
            }

            if !anySucceeded, !refused.isEmpty, let statuses = runPrivileged(refused) {
                anySucceeded = statuses.contains(0)
                for (index, status) in statuses.enumerated() where status != 0 {
                    log.error("Privileged networksetup still failed (exit \(status)): \(refused[index].joined(separator: " "), privacy: .public)")
                }
            }

            DispatchQueue.main.async { completion(anySucceeded) }
        }
    }

    // MARK: - DNS cache

    /// Flushes the directory-service cache and restarts mDNSResponder.
    ///
    /// This always elevates: mDNSResponder runs as `_mdnsresponder`, so signalling it needs
    /// real root — admin group membership is not enough, and without the restart the flush
    /// alone does not clear resolution state on current macOS.
    func clearDNSCache(completion: @escaping (Bool) -> Void) {
        workQueue.async { [self] in
            let statuses = runPrivileged([
                [Self.dscacheutil, "-flushcache"],
                [Self.killall, "-HUP", "mDNSResponder"]
            ])

            guard let statuses, statuses.allSatisfy({ $0 == 0 }) else {
                log.error("DNS cache clear failed: \(statuses.map(String.init(describing:)) ?? "not authorized", privacy: .public)")
                DispatchQueue.main.async { completion(false) }
                return
            }

            DispatchQueue.main.async { completion(true) }
        }
    }

    // MARK: - Validation

    /// Validates that a string is a real IPv4 or IPv6 address, so nothing else
    /// (shell metacharacters, hostnames, etc.) can reach a command built from
    /// user-entered DNS server text.
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
}

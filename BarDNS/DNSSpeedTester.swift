//
//  DNSSpeedTester.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//  Based on DNS Easy Switcher by Gregory Linford.
//

import Foundation
import SwiftData

class DNSSpeedTester {
    static let shared = DNSSpeedTester()
    
    // Result struct to store ping results
    struct PingResult: Identifiable {
        let id = UUID()
        let dnsName: String
        let server: String
        let responseTime: Double? // in milliseconds; nil means the ping failed
        let isCustom: Bool
        let customID: String?

        init(dnsName: String, server: String, responseTime: Double?, isCustom: Bool = false, customID: String? = nil) {
            self.dnsName = dnsName
            self.server = server
            self.responseTime = responseTime
            self.isCustom = isCustom
            self.customID = customID
        }
    }
    
    // Track running tasks to ensure proper cleanup
    private var runningTasks: [Process] = []
    private let runningTasksLock = NSLock()
    private var isCurrentlyTesting = false

    private func addRunningTask(_ task: Process) {
        runningTasksLock.lock()
        runningTasks.append(task)
        runningTasksLock.unlock()
    }

    private func removeRunningTask(_ task: Process) {
        runningTasksLock.lock()
        if let index = runningTasks.firstIndex(where: { $0 === task }) {
            runningTasks.remove(at: index)
        }
        runningTasksLock.unlock()
    }

    /// Empties the tracked task list and returns what was in it, for cleanup.
    @discardableResult
    private func drainRunningTasks() -> [Process] {
        runningTasksLock.lock()
        let tasks = runningTasks
        runningTasks = []
        runningTasksLock.unlock()
        return tasks
    }
    
    // Perform ping test for all DNS servers including custom ones. Hidden preset providers
    // (per DNSSettings visibility toggles) are skipped.
    func testAllDNS(customServers: [CustomDNSServer], settings: DNSSettings?, completion: @escaping ([PingResult]) -> Void) {
        // Safety check to prevent multiple simultaneous tests
        guard !isCurrentlyTesting else {
            completion([])
            return
        }

        isCurrentlyTesting = true
        drainRunningTasks()

        let dnsManager = DNSManager.shared

        var allDNSToTest: [(String, String, Bool, String?)] = []
        if settings?.isCloudflareVisible ?? true {
            allDNSToTest.append(("Cloudflare", dnsManager.cloudflareServers[0], false, nil))
        }
        if settings?.isGoogleVisible ?? true {
            allDNSToTest.append(("Google", dnsManager.googleServers[0], false, nil))
        }
        if settings?.isQuad9Visible ?? true {
            allDNSToTest.append(("Quad9", dnsManager.quad9Servers[0], false, nil))
        }
        if settings?.isAdGuardVisible ?? true {
            allDNSToTest.append(("AdGuard", dnsManager.adguardServers[0], false, nil))
        }

        // Add custom DNS servers (first entry only to keep test time reasonable)
        for server in customServers {
            if let firstEntry = server.dnsEntries.first {
                allDNSToTest.append((server.name, firstEntry, true, server.id))
            }
        }
        
        // Use serial queue to avoid overwhelming the system
        let queue = DispatchQueue(label: "com.glinford.DNSSpeedTest", qos: .userInitiated)
        let resultsLock = NSLock()
        var results: [PingResult] = []
        let group = DispatchGroup()
        
        // Create a semaphore to limit concurrent operations
        let semaphore = DispatchSemaphore(value: 5) // Allow 5 concurrent pings
        
        for (index, (name, server, isCustom, customID)) in allDNSToTest.enumerated() {
            group.enter()
            
            // Add a small delay between tests to avoid overwhelming the system
            queue.asyncAfter(deadline: .now() + Double(index) * 0.05) { [weak self] in
                guard let self = self else {
                    semaphore.signal()
                    group.leave()
                    return
                }
                
                semaphore.wait() // Wait for a slot to become available
                
                self.pingServer(server: server) { responseTime in
                    let result = PingResult(
                        dnsName: name,
                        server: server,
                        responseTime: responseTime,
                        isCustom: isCustom,
                        customID: customID
                    )
                    resultsLock.lock()
                    results.append(result)
                    resultsLock.unlock()

                    semaphore.signal() // Release the slot
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            // Clean up any remaining processes
            for task in self.drainRunningTasks() where task.isRunning {
                task.terminate()
            }
            self.isCurrentlyTesting = false

            // Sort by response time, ascending; failures (nil) always sort last regardless of value
            let sortedResults = results.sorted { lhs, rhs in
                switch (lhs.responseTime, rhs.responseTime) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
            completion(sortedResults)
        }
    }

    // Cancel any ongoing tests
    func cancelTests() {
        for task in drainRunningTasks() where task.isRunning {
            task.terminate()
        }
        isCurrentlyTesting = false
    }
    
    // Clean up when app is terminating
    func cleanup() {
        cancelTests()
    }
    
    // Strips any port suffix and detects IPv6, since ping only understands bare addresses
    // and IPv6 requires ping6 on macOS.
    func resolvePingTarget(_ server: String) -> (host: String, isIPv6: Bool) {
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)

        // Bracketed IPv6 with optional port, e.g. [2001:db8::1]:53
        if address.hasPrefix("["), let closingBracket = address.firstIndex(of: "]") {
            let host = String(address[address.index(after: address.startIndex)..<closingBracket])
            return (host, true)
        }

        let colonCount = address.filter { $0 == ":" }.count

        // IPv4 with port, e.g. 127.0.0.1:5353 (single colon, numeric suffix)
        if colonCount == 1, let colonIndex = address.firstIndex(of: ":") {
            let host = String(address[address.startIndex..<colonIndex])
            let port = address[address.index(after: colonIndex)...]
            if Int(port) != nil {
                return (host, false)
            }
        }

        // Plain IPv6 (multiple colons, no brackets)
        if colonCount > 1 {
            return (address, true)
        }

        return (address, false)
    }

    // Measure ping time to a DNS server with safer implementation. Returns nil on failure.
    private func pingServer(server: String, completion: @escaping (Double?) -> Void) {
        let (host, isIPv6) = resolvePingTarget(server)

        let task = Process()
        if isIPv6 {
            task.launchPath = "/sbin/ping6"
            task.arguments = ["-c", "2", host] // ping6 has no -t timeout flag
        } else {
            task.launchPath = "/sbin/ping"
            task.arguments = ["-c", "2", "-t", "2", host] // 2 pings, 2-second timeout
        }
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        // Keep track of task for cleanup
        addRunningTask(task)

        // Set up termination handler before running
        task.terminationHandler = { [weak self] process in
            guard let self = self else { return }

            self.removeRunningTask(process)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Parse ping results
            if process.terminationStatus == 0 && output.contains("min/avg/max") {
                // More robust parsing approach
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains("min/avg/max") {
                        let parts = line.components(separatedBy: "=")
                        if parts.count >= 2 {
                            let stats = parts[1].trimmingCharacters(in: .whitespaces)
                            let values = stats.components(separatedBy: "/")
                            if values.count >= 2 {
                                if let avgTime = Double(values[1].trimmingCharacters(in: .whitespaces)) {
                                    completion(avgTime)
                                    return
                                }
                            }
                        }
                    }
                }
                // If we get here, parsing failed
                completion(nil)
            } else {
                completion(nil) // Ping failed
            }
        }

        do {
            try task.run()
        } catch {
            removeRunningTask(task)
            completion(nil) // Process failed to start
        }
    }
    
    // Deinitializer to clean up resources
    deinit {
        cleanup()
    }
}

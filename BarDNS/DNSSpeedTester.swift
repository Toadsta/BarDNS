//
//  DNSSpeedTester.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//  Based on DNS Easy Switcher by Gregory Linford.
//

import Foundation
import SwiftData
import os

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

    /// One server to measure. A named struct rather than a tuple so the three String-ish
    /// fields can't be transposed at the call site.
    private struct Target {
        let name: String
        let server: String
        let isCustom: Bool
        let customID: String?
    }

    private static let maxConcurrentPings = 5
    /// Bounds a single ping. `ping6` has no timeout flag of its own, and plain `ping`'s `-t`
    /// only bounds the send loop, so the process needs killing from outside either way.
    private static let pingTimeout: TimeInterval = 5
    /// Bounds the whole run, as a backstop for a ping that outlives SIGTERM.
    private static let overallTimeout: TimeInterval = 20
    private static let launchStagger: TimeInterval = 0.05

    private let log = Logger(subsystem: "com.toadsie.BarDNS", category: "DNSSpeedTester")

    // Track running tasks to ensure proper cleanup
    private var runningTasks: [Process] = []
    private var isCurrentlyTesting = false
    /// Guards both `runningTasks` and `isCurrentlyTesting`. The testing flag needs it as much
    /// as the task list does: its check-then-set is what keeps two runs from overlapping.
    private let stateLock = NSLock()

    private let timeoutQueue = DispatchQueue(label: "com.toadsie.BarDNS.speedtest.timeout")

    private func addRunningTask(_ task: Process) {
        stateLock.lock()
        runningTasks.append(task)
        stateLock.unlock()
    }

    private func removeRunningTask(_ task: Process) {
        stateLock.lock()
        if let index = runningTasks.firstIndex(where: { $0 === task }) {
            runningTasks.remove(at: index)
        }
        stateLock.unlock()
    }

    /// Empties the tracked task list and returns what was in it, for cleanup.
    @discardableResult
    private func drainRunningTasks() -> [Process] {
        stateLock.lock()
        let tasks = runningTasks
        runningTasks = []
        stateLock.unlock()
        return tasks
    }

    /// Claims the testing slot. Returns false if a run is already in flight.
    private func beginTesting() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isCurrentlyTesting else { return false }
        isCurrentlyTesting = true
        return true
    }

    private func endTesting() {
        stateLock.lock()
        isCurrentlyTesting = false
        stateLock.unlock()
    }

    private func terminateRunningTasks() {
        for task in drainRunningTasks() where task.isRunning {
            task.terminate()
        }
    }

    // Perform ping test for all DNS servers including custom ones. Hidden preset providers
    // (per DNSSettings visibility toggles) are skipped.
    func testAllDNS(customServers: [CustomDNSServer], settings: DNSSettings?, completion: @escaping ([PingResult]) -> Void) {
        // Safety check to prevent multiple simultaneous tests
        guard beginTesting() else {
            completion([])
            return
        }

        // Anything left over from a previous run is stale; stop it rather than leaking it.
        terminateRunningTasks()

        let dnsManager = DNSManager.shared

        var targets: [Target] = []
        if settings?.isCloudflareVisible ?? true {
            targets.append(Target(name: "Cloudflare", server: dnsManager.cloudflareServers[0], isCustom: false, customID: nil))
        }
        if settings?.isGoogleVisible ?? true {
            targets.append(Target(name: "Google", server: dnsManager.googleServers[0], isCustom: false, customID: nil))
        }
        if settings?.isQuad9Visible ?? true {
            targets.append(Target(name: "Quad9", server: dnsManager.quad9Servers[0], isCustom: false, customID: nil))
        }
        if settings?.isAdGuardVisible ?? true {
            targets.append(Target(name: "AdGuard", server: dnsManager.adguardServers[0], isCustom: false, customID: nil))
        }

        // Add custom DNS servers (first entry only to keep test time reasonable)
        for server in customServers {
            if let firstEntry = server.dnsEntries.first {
                targets.append(Target(name: server.name, server: firstEntry, isCustom: true, customID: server.id))
            }
        }

        guard !targets.isEmpty else {
            endTesting()
            completion([])
            return
        }

        // Concurrent, because the semaphore below is what limits how many pings are in flight.
        // On a serial queue the semaphore would instead block the queue itself, so one wedged
        // ping could stall every ping behind it.
        let queue = DispatchQueue(label: "com.toadsie.BarDNS.speedtest", qos: .userInitiated, attributes: .concurrent)
        let semaphore = DispatchSemaphore(value: Self.maxConcurrentPings)
        let resultsLock = NSLock()
        var results: [PingResult] = []
        let group = DispatchGroup()

        // Exactly one of the completion path and the watchdog reports, whichever arrives first.
        let finishLock = NSLock()
        var didFinish = false
        let finish: (Bool) -> Void = { [weak self] timedOut in
            finishLock.lock()
            let alreadyFinished = didFinish
            didFinish = true
            finishLock.unlock()
            guard !alreadyFinished else { return }

            if let self {
                if timedOut {
                    self.log.error("Speed test timed out after \(Self.overallTimeout)s; reporting partial results")
                }
                self.terminateRunningTasks()
                self.endTesting()
            }

            resultsLock.lock()
            let snapshot = results
            resultsLock.unlock()
            completion(snapshot.sorted(by: Self.fastestFirst))
        }

        // Backstop. Per-ping timeouts should make this unreachable, but nothing else in this
        // class can recover if a ping process survives SIGTERM — and the cost of not
        // recovering is a Run Speed Test button that stays disabled for the life of the app.
        // `finish` is idempotent, so this firing late is harmless and needs no cancellation.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overallTimeout) {
            finish(true)
        }

        for (index, target) in targets.enumerated() {
            group.enter()

            // Stagger the launches slightly to avoid a burst of processes.
            queue.asyncAfter(deadline: .now() + Double(index) * Self.launchStagger) { [weak self] in
                guard let self else {
                    group.leave()
                    return
                }

                semaphore.wait() // Wait for a slot to become available

                self.pingServer(server: target.server) { responseTime in
                    let result = PingResult(
                        dnsName: target.name,
                        server: target.server,
                        responseTime: responseTime,
                        isCustom: target.isCustom,
                        customID: target.customID
                    )
                    resultsLock.lock()
                    results.append(result)
                    resultsLock.unlock()

                    semaphore.signal() // Release the slot
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            finish(false)
        }
    }

    // Cancel any ongoing tests
    func cancelTests() {
        terminateRunningTasks()
        endTesting()
    }

    // Clean up when app is terminating
    func cleanup() {
        cancelTests()
    }

    // Detects IPv6 vs IPv4, since IPv6 requires ping6 on macOS. DNS entries are always plain
    // addresses (no port syntax is ever accepted), so no port/bracket handling is needed here.
    func resolvePingTarget(_ server: String) -> (host: String, isIPv6: Bool) {
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        return (address, address.contains(":"))
    }

    /// Pulls the average out of ping's `round-trip min/avg/max/stddev = a/b/c/d ms` summary.
    static func averageResponseTime(from output: String, status: Int32) -> Double? {
        guard status == 0 else { return nil }

        for line in output.components(separatedBy: .newlines) where line.contains("min/avg/max") {
            let parts = line.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }

            let values = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: "/")
            guard values.count >= 2,
                  let average = Double(values[1].trimmingCharacters(in: .whitespaces)) else { continue }

            return average
        }
        return nil
    }

    /// Ascending by response time; failures (nil) always sort last regardless of value.
    private static func fastestFirst(_ lhs: PingResult, _ rhs: PingResult) -> Bool {
        switch (lhs.responseTime, rhs.responseTime) {
        case let (l?, r?): return l < r
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return false
        }
    }

    // Measure ping time to a DNS server. Returns nil on failure. Calls its completion exactly
    // once, however the ping ends.
    private func pingServer(server: String, completion: @escaping (Double?) -> Void) {
        let (host, isIPv6) = resolvePingTarget(server)

        // ping takes the host as a positional argument, so a value starting with "-" would be
        // read as a flag instead. Entries are validated when saved, but this is the boundary
        // where it actually matters.
        guard DNSManager.shared.isValidIPAddress(host) else {
            log.error("Refusing to ping a non-address target")
            completion(nil)
            return
        }

        let task = Process()
        if isIPv6 {
            task.executableURL = URL(fileURLWithPath: "/sbin/ping6")
            task.arguments = ["-c", "2", host] // ping6 has no -t; the timer below bounds it
        } else {
            task.executableURL = URL(fileURLWithPath: "/sbin/ping")
            task.arguments = ["-c", "2", "-t", "2", host] // 2 pings, 2-second timeout
        }

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        // The termination handler and the timeout can both reach the caller. Whichever gets
        // there first wins: without this, a ping outliving SIGTERM would leave the caller's
        // DispatchGroup un-left, which used to wedge the whole speed test permanently.
        let reportLock = NSLock()
        var didReport = false
        let reportOnce: (Double?) -> Void = { value in
            reportLock.lock()
            let alreadyReported = didReport
            didReport = true
            reportLock.unlock()
            guard !alreadyReported else { return }
            completion(value)
        }

        let timeout = DispatchSource.makeTimerSource(queue: timeoutQueue)
        timeout.schedule(deadline: .now() + Self.pingTimeout)
        timeout.setEventHandler { [weak self, weak task] in
            guard let task else { return }
            if task.isRunning {
                task.terminate()
            }
            self?.removeRunningTask(task)
            reportOnce(nil)
        }
        // Resumed before the process starts so the source is never released while suspended.
        timeout.resume()

        task.terminationHandler = { [weak self] process in
            timeout.cancel()
            self?.removeRunningTask(process)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            reportOnce(Self.averageResponseTime(from: output, status: process.terminationStatus))
        }

        addRunningTask(task)

        do {
            try task.run()
        } catch {
            timeout.cancel()
            removeRunningTask(task)
            reportOnce(nil) // Process failed to start
        }
    }
}

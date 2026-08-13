//
//  DNSSpeedTesterTests.swift
//  BarDNSTests
//
//  Created by Victoria Taylor.
//

import XCTest
@testable import BarDNS

final class DNSSpeedTesterTests: XCTestCase {
    private let tester = DNSSpeedTester.shared

    func testPlainIPv4ResolvesToItselfAndIsNotIPv6() {
        let result = tester.resolvePingTarget("192.168.0.125")
        XCTAssertEqual(result.host, "192.168.0.125")
        XCTAssertFalse(result.isIPv6)
    }

    func testPlainIPv6IsDetected() {
        let result = tester.resolvePingTarget("2001:4860:4860::8888")
        XCTAssertEqual(result.host, "2001:4860:4860::8888")
        XCTAssertTrue(result.isIPv6)
    }

    func testTrimsWhitespace() {
        let result = tester.resolvePingTarget("  1.1.1.1  ")
        XCTAssertEqual(result.host, "1.1.1.1")
    }

    // MARK: - averageResponseTime

    private static let successfulPingOutput = """
    PING 1.1.1.1 (1.1.1.1): 56 data bytes
    64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.345 ms
    64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=14.567 ms

    --- 1.1.1.1 ping statistics ---
    2 packets transmitted, 2 packets received, 0.0% packet loss
    round-trip min/avg/max/stddev = 12.345/13.456/14.567/1.111 ms
    """

    func testParsesAverageFromPingSummary() {
        XCTAssertEqual(DNSSpeedTester.averageResponseTime(from: Self.successfulPingOutput, status: 0), 13.456)
    }

    func testNonZeroExitIsAFailureEvenWithParseableOutput() {
        // A ping killed by the timeout can still have printed a summary line; it is not a
        // usable measurement.
        XCTAssertNil(DNSSpeedTester.averageResponseTime(from: Self.successfulPingOutput, status: 1))
    }

    func testUnparseableOutputReturnsNil() {
        XCTAssertNil(DNSSpeedTester.averageResponseTime(from: "ping: cannot resolve host", status: 0))
        XCTAssertNil(DNSSpeedTester.averageResponseTime(from: "", status: 0))
        XCTAssertNil(DNSSpeedTester.averageResponseTime(from: "round-trip min/avg/max/stddev", status: 0))
    }
}

//
//  DNSSpeedTesterTests.swift
//  BarDNSTests
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

    func testIPv4WithPortStripsThePort() {
        let result = tester.resolvePingTarget("127.0.0.1:5353")
        XCTAssertEqual(result.host, "127.0.0.1")
        XCTAssertFalse(result.isIPv6)
    }

    func testPlainIPv6IsDetected() {
        let result = tester.resolvePingTarget("2001:4860:4860::8888")
        XCTAssertEqual(result.host, "2001:4860:4860::8888")
        XCTAssertTrue(result.isIPv6)
    }

    func testBracketedIPv6WithPortStripsBracketsAndPort() {
        let result = tester.resolvePingTarget("[2001:4860:4860::8888]:53")
        XCTAssertEqual(result.host, "2001:4860:4860::8888")
        XCTAssertTrue(result.isIPv6)
    }

    func testBracketedIPv6WithoutPort() {
        let result = tester.resolvePingTarget("[2001:4860:4860::8888]")
        XCTAssertEqual(result.host, "2001:4860:4860::8888")
        XCTAssertTrue(result.isIPv6)
    }

    func testTrimsWhitespace() {
        let result = tester.resolvePingTarget("  1.1.1.1  ")
        XCTAssertEqual(result.host, "1.1.1.1")
    }
}

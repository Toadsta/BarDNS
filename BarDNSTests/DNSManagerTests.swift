//
//  DNSManagerTests.swift
//  BarDNSTests
//

import XCTest
@testable import BarDNS

final class DNSManagerTests: XCTestCase {
    private let manager = DNSManager.shared

    // MARK: - isValidIPAddress

    func testValidIPv4Addresses() {
        for address in ["1.1.1.1", "127.0.0.1", "8.8.8.8", "255.255.255.255", "0.0.0.0"] {
            XCTAssertTrue(manager.isValidIPAddress(address), "\(address) should be a valid IPv4 address")
        }
    }

    func testValidIPv6Addresses() {
        for address in ["2001:4860:4860::8888", "::1", "2606:4700:4700::1111", "fe80::1"] {
            XCTAssertTrue(manager.isValidIPAddress(address), "\(address) should be a valid IPv6 address")
        }
    }

    func testInvalidAddressesAreRejected() {
        let invalid = [
            "not-an-ip",
            "1.1.1.1; rm -rf ~",
            "8.8.8.8`touch /tmp/pwned`",
            "$(touch /tmp/pwned)",
            "1.1.1.1 && echo pwned",
            "",
            "999.999.999.999",
            "1.1.1.1:53" // port isn't part of the address itself
        ]
        for address in invalid {
            XCTAssertFalse(manager.isValidIPAddress(address), "\(address.debugDescription) should not be a valid address")
        }
    }

    // MARK: - parseDNSServer

    func testParsesPlainIPv4() {
        let result = manager.parseDNSServer("8.8.8.8")
        XCTAssertEqual(result?.address, "8.8.8.8")
        XCTAssertNil(result?.port)
    }

    func testParsesIPv4WithPort() {
        let result = manager.parseDNSServer("127.0.0.1:5353")
        XCTAssertEqual(result?.address, "127.0.0.1")
        XCTAssertEqual(result?.port, 5353)
    }

    func testParsesPlainIPv6() {
        let result = manager.parseDNSServer("2001:4860:4860::8888")
        XCTAssertEqual(result?.address, "2001:4860:4860::8888")
        XCTAssertNil(result?.port)
    }

    func testParsesBracketedIPv6WithPort() {
        let result = manager.parseDNSServer("[2001:4860:4860::8888]:53")
        XCTAssertEqual(result?.address, "2001:4860:4860::8888")
        XCTAssertEqual(result?.port, 53)
    }

    func testParsesBracketedIPv6WithoutPort() {
        let result = manager.parseDNSServer("[2001:4860:4860::8888]")
        XCTAssertEqual(result?.address, "2001:4860:4860::8888")
        XCTAssertNil(result?.port)
    }

    func testRejectsInvalidPortNumbers() {
        XCTAssertNil(manager.parseDNSServer("127.0.0.1:0"))
        XCTAssertNil(manager.parseDNSServer("127.0.0.1:70000"))
        XCTAssertNil(manager.parseDNSServer("127.0.0.1:not-a-port"))
    }

    func testRejectsShellInjectionAttempts() {
        let payloads = [
            "1.1.1.1; touch /tmp/pwned",
            "8.8.8.8`touch /tmp/pwned`",
            "$(touch /tmp/pwned)",
            "1.1.1.1 && rm -rf ~",
            "not-an-ip-at-all"
        ]
        for payload in payloads {
            XCTAssertNil(manager.parseDNSServer(payload), "\(payload.debugDescription) should be rejected")
        }
    }

    func testRejectsEmptyAndWhitespaceInput() {
        XCTAssertNil(manager.parseDNSServer(""))
        XCTAssertNil(manager.parseDNSServer("   "))
    }

    func testTrimsWhitespace() {
        let result = manager.parseDNSServer("  8.8.8.8  ")
        XCTAssertEqual(result?.address, "8.8.8.8")
    }
}

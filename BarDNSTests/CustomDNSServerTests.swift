//
//  CustomDNSServerTests.swift
//  BarDNSTests
//

import XCTest
@testable import BarDNS

final class CustomDNSServerTests: XCTestCase {
    func testDnsEntriesCollectsAllNonEmptyFields() {
        let server = CustomDNSServer(
            name: "Test",
            primaryDNS: "1.1.1.1",
            secondaryDNS: "1.0.0.1",
            tertiaryDNS: "2606:4700:4700::1111",
            quaternaryDNS: nil
        )
        XCTAssertEqual(server.dnsEntries, ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111"])
    }

    func testDnsEntriesSplitsCommaSeparatedValues() {
        let server = CustomDNSServer(
            name: "Test",
            primaryDNS: "1.1.1.1, 1.0.0.1",
            secondaryDNS: "",
            tertiaryDNS: nil,
            quaternaryDNS: nil
        )
        XCTAssertEqual(server.dnsEntries, ["1.1.1.1", "1.0.0.1"])
    }

    func testDnsEntriesFiltersOutEmptyValues() {
        let server = CustomDNSServer(
            name: "Test",
            primaryDNS: "1.1.1.1",
            secondaryDNS: "",
            tertiaryDNS: "  ",
            quaternaryDNS: nil
        )
        XCTAssertEqual(server.dnsEntries, ["1.1.1.1"])
    }
}

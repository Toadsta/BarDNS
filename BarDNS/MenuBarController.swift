//
//  MenuBarController.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//  Based on DNS Easy Switcher by Gregory Linford.
//

import Foundation
import AppKit

class MenuBarController: ObservableObject {
    init() {
        // Hide the dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

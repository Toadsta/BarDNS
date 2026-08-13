//
//  BarDNS.swift
//  BarDNS
//
//  Created by Victoria Taylor.
//  Based on DNS Easy Switcher by Gregory Linford.
//

import SwiftUI
import SwiftData
import AppKit
import UserNotifications
import Observation

extension Notification.Name {
    /// Posted when the user clicks a BarDNS notification (e.g. a failed DNS change);
    /// observed by MenuBarView (to open Settings) and SettingsView (to land on General).
    static let bardnsOpenSettingsGeneral = Notification.Name("com.toadsie.BarDNS.openSettingsGeneral")
    /// Posted when a menu bar quick action (Run Speed Test, Add Custom DNS) is triggered
    /// while Settings is already open, so it can re-sync from QuickActionStore.
    static let bardnsQuickAction = Notification.Name("com.toadsie.BarDNS.quickAction")
}

/// Holds the latest notification message for GeneralSettingsView to display. A plain
/// broadcast isn't enough here: on the first-ever click, opening the Settings window
/// creates GeneralSettingsView *after* the broadcast already fired, so it would miss
/// it. Reading this @Observable property directly in `body` works regardless of
/// whether the view existed yet when the message arrived.
@Observable
final class NotificationMessageStore {
    static let shared = NotificationMessageStore()
    var failureMessage: String?
}

/// Carries a pending action from a menu bar quick-action click into the Settings window:
/// which tab to land on, and whether to auto-trigger something once there (start the
/// speed test, or pop the Add Custom DNS sheet) rather than just leaving the user to
/// click it again.
@Observable
final class QuickActionStore {
    static let shared = QuickActionStore()
    var pendingSection: SettingsView.Section?
    var shouldAutoRunSpeedTest = false
    var shouldAutoAddCustomDNS = false
}

/// Only needed so notification clicks can be intercepted (UNUserNotificationCenter's
/// delegate) — without this, clicking a notification just activates the app with no
/// way to route it to Settings.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if response.notification.request.content.userInfo["isFailure"] as? Bool == true {
            NotificationMessageStore.shared.failureMessage = response.notification.request.content.body
        }
        NotificationCenter.default.post(name: .bardnsOpenSettingsGeneral, object: nil)
        completionHandler()
    }
}

@main
struct BarDNS: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let modelContainer: ModelContainer

    init() {
        // BarDNS is an LSUIElement (no Dock icon), so it doesn't get the "already running,
        // just activate it" behavior a normal app gets for free. Enforce it manually: if
        // another instance is already running, bring it forward and quit this one.
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if let existing = runningInstances.first(where: { $0.processIdentifier != currentPID }) {
            existing.activate()
            // NSApplication.terminate(_:) only requests termination once the run loop is
            // running, which it isn't yet here — by the time it took effect, this duplicate
            // process had already built its Scene body and put up a second menu bar icon.
            // Exit immediately instead, before any UI gets created.
            exit(0)
        }

        do {
            let schema = Schema([
                DNSSettings.self,
                CustomDNSServer.self
            ])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            self.modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // If the persistent store cannot be created (e.g., corrupted store or permission issue),
            // fall back to an in-memory container so the app can still launch.
            let schema = Schema([
                DNSSettings.self,
                CustomDNSServer.self
            ])
            self.modelContainer = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            print("Warning: Using in-memory store due to ModelContainer error: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup(id: "hidden") {
            Color.clear
                .frame(width: 0, height: 0)
                .hidden()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 0, height: 0)
        .modelContainer(modelContainer)
        
        MenuBarExtra("BarDNS", systemImage: "server.rack") {
            MenuBarView()
                .environment(\.modelContext, modelContainer.mainContext)
                .frame(width: 300)
        }

        Window("BarDNS Settings", id: "settings") {
            SettingsView()
        }
        .modelContainer(modelContainer)
        .windowResizability(.contentSize)
    }
}

import AppKit
import SwiftUI
import UserNotifications

@main
struct SomnoireApp: App {
    @NSApplicationDelegateAdaptor(SomnoireAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            SomnoireMenuView(bluetooth: appDelegate.bluetooth, openSettings: appDelegate.openSettings).modifier(AppAppearanceStyle())
        } label: { SomnoireStatusLabel(bluetooth: appDelegate.bluetooth) }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class SomnoireAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let bluetooth = BluetoothManager()
    private var appearanceObserver: NSObjectProtocol?
    private func applyAppearance() {
        switch AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "System") ?? .system {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
    private var settingsWindow: NSWindow?
    func openSettings() {
        bluetooth.settingsVisibility(true)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SomnoireSettingsView(bluetooth: bluetooth).modifier(AppAppearanceStyle())))
            window.title = "Somnoire Settings"; window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 600)); window.contentMinSize = NSSize(width: 680, height: 500)
            window.isReleasedWhenClosed = false; window.delegate = self; window.center(); settingsWindow = window
        }
        updateDock(); settingsWindow?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    private var onboardingWindow: NSWindow?
    func openOnboarding() {
        if onboardingWindow == nil {
            let root = OnboardingView(bluetooth: bluetooth, close: { [weak self] in self?.onboardingWindow?.performClose(nil) }).modifier(AppAppearanceStyle())
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Welcome to Somnoire"; window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 580, height: 610)); window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            onboardingWindow = window
        }
        bluetooth.settingsVisibility(true); updateDock()
        onboardingWindow?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    private func updateDock(excluding closing: NSWindow? = nil) {
        let visible = [settingsWindow, diagnosticsWindow, onboardingWindow].compactMap { $0 }.contains { $0 !== closing }
        NSApplication.shared.setActivationPolicy(visible ? .regular : .accessory)
    }
    private var diagnosticsWindow: NSWindow?
    func openDiagnostics() {
        if diagnosticsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SomnoireDiagnosticsView(bluetooth: bluetooth).modifier(AppAppearanceStyle())))
            window.title = "Somnoire Diagnostics"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 600))
            window.contentMinSize = NSSize(width: 560, height: 440)
            window.isReleasedWhenClosed = false; window.isRestorable = false
            window.delegate = self; window.center(); diagnosticsWindow = window
        }
        updateDock(); diagnosticsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { settingsWindow = nil; bluetooth.settingsVisibility(onboardingWindow?.isVisible == true) }
        if notification.object as? NSWindow === diagnosticsWindow { bluetooth.diagnosticsClosed(); diagnosticsWindow = nil }
        if notification.object as? NSWindow === onboardingWindow { onboardingWindow = nil; bluetooth.settingsVisibility(settingsWindow?.isVisible == true) }
        updateDock(excluding: notification.object as? NSWindow)
    }
    private func refreshSettingsOwnership() {
        bluetooth.settingsVisibility([settingsWindow, onboardingWindow].compactMap { $0 }.contains { $0.isVisible && !$0.isMiniaturized })
    }
    func windowDidMiniaturize(_ notification: Notification) { refreshSettingsOwnership() }
    func windowDidDeminiaturize(_ notification: Notification) { refreshSettingsOwnership() }
    func applicationDidHide(_ notification: Notification) { bluetooth.settingsVisibility(false) }
    func applicationDidUnhide(_ notification: Notification) {
        refreshSettingsOwnership()
    }
    static func shouldRestoreMonitoring(isTestHost: Bool) -> Bool { !isTestHost }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let testing = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard Self.shouldRestoreMonitoring(isTestHost: testing) else { return }
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).min(by: {
               let lhs = $0.launchDate ?? .distantPast, rhs = $1.launchDate ?? .distantPast
               return lhs == rhs ? $0.processIdentifier < $1.processIdentifier : lhs < rhs
           }), existing.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            existing.activate(options: .activateIgnoringOtherApps)
            NSApplication.shared.terminate(nil); return
        }
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyAppearance() }
        }
        bluetooth.resumeSavedMonitoring()
        if !UserDefaults.standard.bool(forKey: "onboardingComplete") { openOnboarding() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = [onboardingWindow, settingsWindow, diagnosticsWindow].compactMap({ $0 }).first {
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        } else { openSettings() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { bluetooth.shutdown() }
}

struct LowBatteryPolicy {
    static let thresholds = [10,15,20,25,30]
    static func next(percentage: Int, threshold: Int, latched: Bool) -> (alert: Bool, latched: Bool) {
        guard (0...100).contains(percentage), thresholds.contains(threshold) else { return (false, latched) }
        if percentage >= threshold + 5 { return (false, false) }
        if percentage <= threshold && !latched { return (true, true) }
        return (false, latched)
    }
}
@MainActor
final class LowBatteryAlerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled: Bool
    @Published var threshold: Int { didSet { generation += 1; preferences.set(threshold, forKey: "lowBatteryThreshold") } }
    @Published private(set) var status = "Notifications off"
    private let preferences: UserDefaults
    private var sending: Set<String> = []
    private var generation = 0
    func cancelPendingEvaluation() { generation += 1 }
    init(preferences: UserDefaults) {
        self.preferences = preferences
        enabled = preferences.bool(forKey: "lowBatteryAlerts")
        let value = preferences.integer(forKey: "lowBatteryThreshold")
        threshold = LowBatteryPolicy.thresholds.contains(value) ? value : 20
        super.init()
    }
    func refresh() {
        UNUserNotificationCenter.current().delegate = self
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            status = settings.authorizationStatus == .authorized ? "Notifications allowed" : settings.authorizationStatus == .denied ? "Notifications denied in System Settings" : "Permission not requested"
        }
    }
    func setEnabled(_ value: Bool) {
        if !value { generation += 1; enabled = false; preferences.set(false, forKey: "lowBatteryAlerts"); return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            do {
                enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                preferences.set(enabled, forKey: "lowBatteryAlerts"); refresh()
            } catch { enabled = false; status = "Notifications unavailable" }
        }
    }
    func evaluate(bank: UUID, percentage: Int, fresh: Bool) {
        guard enabled, fresh else { return }
        let key = "lowBatteryLatch.\(bank.uuidString).\(threshold)"
        guard !sending.contains(key) else { return }
        let decision = LowBatteryPolicy.next(percentage: percentage, threshold: threshold, latched: preferences.bool(forKey: key))
        if !decision.latched { preferences.set(false, forKey: key) }
        guard decision.alert else { return }
        sending.insert(key)
        let ticket = generation, evaluatedAt = Date()
        Task {
            defer { sending.remove(key) }
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let settings = await center.notificationSettings()
            guard enabled, ticket == generation, Date().timeIntervalSince(evaluatedAt) < 30, settings.authorizationStatus == .authorized else { refresh(); return }
            let content = UNMutableNotificationContent()
            content.title = "Low power bank battery"; content.body = "Your power bank is at \(percentage)%."
            do {
                try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
                guard enabled, ticket == generation else {
                    center.removePendingNotificationRequests(withIdentifiers: [key])
                    center.removeDeliveredNotifications(withIdentifiers: [key]); return
                }
                preferences.set(true, forKey: key)
            } catch { status = "Notification could not be sent" }
        }
    }
    func forget(bank: UUID) {
        generation += 1
        let keys = LowBatteryPolicy.thresholds.map { "lowBatteryLatch.\(bank.uuidString).\($0)" }
        for key in keys { preferences.removeObject(forKey: key) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: keys)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: keys)
    }
    func test() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .authorized else { refresh(); return }
            let content = UNMutableNotificationContent(); content.title = "Somnoire test"; content.body = "Low-battery notifications are ready."
            do { try await center.add(UNNotificationRequest(identifier: "somnoire-test", content: content, trigger: nil)) }
            catch { status = "Test notification could not be sent" }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
}

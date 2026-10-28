import AppKit
import SwiftUI

@main
struct SomnoireApp: App {
    @NSApplicationDelegateAdaptor(SomnoireAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            SomnoireMenuView(bluetooth: appDelegate.bluetooth, openDiagnostics: appDelegate.openDiagnostics, openSettings: appDelegate.openSettings)
        } label: { SomnoireStatusLabel(bluetooth: appDelegate.bluetooth) }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class SomnoireAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let bluetooth = BluetoothManager()
    private var settingsWindow: NSWindow?
    func openSettings() {
        bluetooth.settingsVisibility(true)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SomnoireSettingsView(bluetooth: bluetooth, resize: self.resizeSettings)))
            window.title = "Somnoire Settings"; window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 360)); window.contentMinSize = NSSize(width: 520, height: 340)
            window.isReleasedWhenClosed = false; window.delegate = self; window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    private func resizeSettings(_ pane: Int) {
        guard let window = settingsWindow else { return }
        let height = min(pane == 1 ? 570.0 : pane == 2 ? 360.0 : 430.0, (window.screen?.visibleFrame.height ?? 800) - 80)
        var frame = window.frame; let top = frame.maxY
        frame.size.height = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: height)).height; frame.origin.y = top-frame.height
        window.setFrame(frame, display: true, animate: false)
    }
    private var diagnosticsWindow: NSWindow?
    func openDiagnostics() {
        if diagnosticsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SomnoireDiagnosticsView(bluetooth: bluetooth)))
            window.title = "Somnoire Diagnostics"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 600))
            window.contentMinSize = NSSize(width: 560, height: 440)
            window.isReleasedWhenClosed = false; window.isRestorable = false
            window.delegate = self; window.center(); diagnosticsWindow = window
        }
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { bluetooth.settingsVisibility(false); settingsWindow = nil }
        if notification.object as? NSWindow === diagnosticsWindow { bluetooth.diagnosticsClosed() }
    }
    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { bluetooth.settingsVisibility(false) }
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { bluetooth.settingsVisibility(true) }
    }
    func applicationDidHide(_ notification: Notification) { bluetooth.settingsVisibility(false) }
    func applicationDidUnhide(_ notification: Notification) {
        if settingsWindow?.isVisible == true && settingsWindow?.isMiniaturized == false { bluetooth.settingsVisibility(true) }
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
        bluetooth.resumeSavedMonitoring()
        if !UserDefaults.standard.bool(forKey: "onboardingComplete") { openSettings() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { bluetooth.shutdown() }
}

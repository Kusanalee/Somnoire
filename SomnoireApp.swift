import AppKit
import SwiftUI

@main
struct SomnoireApp: App {
    @NSApplicationDelegateAdaptor(SomnoireAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            SomnoireMenuView(bluetooth: appDelegate.bluetooth, openDiagnostics: appDelegate.openDiagnostics)
        } label: { SomnoireStatusLabel(bluetooth: appDelegate.bluetooth) }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class SomnoireAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let bluetooth = BluetoothManager()
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
        if notification.object as? NSWindow === diagnosticsWindow { bluetooth.diagnosticsClosed() }
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
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { bluetooth.shutdown() }
}

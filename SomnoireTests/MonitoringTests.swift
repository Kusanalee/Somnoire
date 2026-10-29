import XCTest
import SwiftUI
import AppKit
@testable import Somnoire

final class MonitoringTests: XCTestCase {
    @MainActor
    func testAlertPreferenceAndLatchPersistenceWithoutPermissionRequests() {
        let suite = "SomnoireTests.Alerts", prefs = UserDefaults(suiteName: "SomnoireTests.Alerts")!
        prefs.removePersistentDomain(forName: suite); defer { prefs.removePersistentDomain(forName: suite) }
        let alerts = LowBatteryAlerts(preferences: prefs), bank = UUID()
        XCTAssertFalse(alerts.enabled); XCTAssertEqual(alerts.threshold, 20)
        alerts.threshold = 15
        XCTAssertEqual(LowBatteryAlerts(preferences: prefs).threshold, 15)
        alerts.evaluate(bank: bank, percentage: 0, fresh: false)
        XCTAssertFalse(prefs.bool(forKey: "lowBatteryLatch.\(bank.uuidString).15"))
        prefs.set(true, forKey: "lowBatteryLatch.\(bank.uuidString).15")
        alerts.forget(bank: bank)
        XCTAssertFalse(prefs.bool(forKey: "lowBatteryLatch.\(bank.uuidString).15"))
    }
    func testLowBatteryHysteresisAndThresholds() {
        var latched = false, count = 0
        for percentage in [20,20,19,21,24,25,20] {
            let result = LowBatteryPolicy.next(percentage: percentage, threshold: 20, latched: latched)
            latched = result.latched; if result.alert { count += 1 }
        }
        XCTAssertEqual(count, 2)
        XCTAssertFalse(LowBatteryPolicy.next(percentage: -1, threshold: 20, latched: false).alert)
        XCTAssertTrue(LowBatteryPolicy.next(percentage: 0, threshold: 10, latched: false).alert)
    }
    func testSharedBatteryRetainsStaleAndRejectsInvalidUpdates() {
        var battery = BatteryPresentation(); let bank = UUID(), date = Date()
        XCTAssertEqual(battery.text, "—")
        battery.receive(bank: bank, value: 42, date: date, now: 0, source: "advertisement")
        XCTAssertTrue(battery.fresh(now: 29, available: true))
        XCTAssertFalse(battery.fresh(now: 30, available: true)); XCTAssertEqual(battery.text, "42%")
        battery.receive(bank: bank, value: .nan, date: date, now: 31, source: "telemetry")
        XCTAssertEqual(battery.sampledAt, 0)
        battery.receive(bank: bank, value: 0, date: date, now: 32, source: "telemetry")
        XCTAssertEqual(battery.text, "0%")
        XCTAssertFalse(battery.fresh(now: 32, available: false))
    }
    @MainActor
    func testBasicModeNeverStartsLiveConnectionAndPersistsChoice() {
        let suite = "SomnoireTests.BasicMode", prefs = UserDefaults(suiteName: "SomnoireTests.BasicMode")!
        prefs.removePersistentDomain(forName: suite)
        defer { prefs.removePersistentDomain(forName: suite) }
        let manager = BluetoothManager(preferences: prefs)
        defer { manager.shutdown() }
        XCTAssertEqual(manager.appMode, .percentageOnly)
        manager.panelVisibility(true); manager.settingsVisibility(true); manager.startLive(userID: "123")
        XCTAssertFalse(manager.isProbing)
        manager.setAppMode(.fullReadings); XCTAssertEqual(prefs.string(forKey: "appMode"), "fullReadings")
        manager.setAppMode(.percentageOnly); XCTAssertFalse(manager.isProbing)
    }

    private func profile(_ percent: UInt8 = 96) -> AdvertisementSnapshot {
        var bytes = Data([0xB5, 0xB5, 0x13]) + Data("P512000000000000".utf8) + Data(repeating: 0, count: 6)
        bytes[19] = percent; bytes[24] = 0xBE
        return AdvertisementSnapshot(manufacturerData: bytes)
    }
    private func receive(_ state: inout MonitoringState, _ id: UUID, at time: Double, advertisement: AdvertisementSnapshot? = nil) {
        XCTAssertTrue(state.receive(id: id, advertisement: advertisement ?? profile(), name: "Test bank", rssi: -40,
            observedAt: Date(timeIntervalSince1970: time), now: time))
    }
    func testAssociationWaitsThreeSecondsAndSelectsOnlyOneCandidate() {
        let id = UUID(); var state = MonitoringState(enabled: true)
        receive(&state, id, at: 0)
        state.settle(now: 2.99); XCTAssertNil(state.targetID)
        state.settle(now: 3); XCTAssertEqual(state.targetID, id)
        let ui = state.presentation(now: 3, availability: .ready, asleep: false, diagnosticBusy: false)
        XCTAssertEqual(ui.menuBarText, "96%"); XCTAssertEqual(ui.status, "Nearby · Monitoring")
        XCTAssertTrue(ui.accessibilityLabel.contains("power bank"))
        XCTAssertFalse(ui.accessibilityLabel.contains("Connected"))
    }
    func testAmbiguousCandidatesRequireSelectionAndDoNotSelectExpiredDevice() {
        let a = UUID(), b = UUID(); var state = MonitoringState(enabled: true)
        receive(&state, a, at: 0); receive(&state, b, at: 1); state.settle(now: 3)
        XCTAssertNil(state.targetID); XCTAssertTrue(state.choosing)
        XCTAssertFalse(state.select(a, now: 31))
        receive(&state, b, at: 32); XCTAssertTrue(state.select(b, now: 32)); XCTAssertEqual(state.candidates.count, 1)
    }
    func testRememberedDeviceDoesNotFallBackToOtherBanks() {
        let id = UUID(); var state = MonitoringState(enabled: true, targetID: id)
        XCTAssertFalse(state.receive(id: UUID(), advertisement: profile(), name: nil, rssi: nil, observedAt: Date(), now: 0))
        XCTAssertTrue(state.candidates.isEmpty)
        receive(&state, id, at: 0)
        XCTAssertEqual(state.presentation(now: 30, availability: .ready, asleep: false, diagnosticBusy: false).menuBarText, "—")
        XCTAssertEqual(state.targetID, id)
        state.forget(); XCTAssertNil(state.targetID); XCTAssertTrue(state.candidates.isEmpty)
    }
    func testFreshnessIgnoresMissingManufacturerDataAndInvalidatesMalformedValues() {
        let id = UUID(); var state = MonitoringState(enabled: true, targetID: id)
        receive(&state, id, at: 0)
        receive(&state, id, at: 29, advertisement: AdvertisementSnapshot(localName: "Renamed"))
        XCTAssertEqual(state.lastBatteryAt, 0)
        XCTAssertEqual(state.presentation(now: 30, availability: .ready, asleep: false, diagnosticBusy: false).menuBarText, "—")
        receive(&state, id, at: 31, advertisement: profile(95))
        XCTAssertEqual(state.presentation(now: 31, availability: .ready, asleep: false, diagnosticBusy: false).menuBarText, "95%")
        receive(&state, id, at: 32, advertisement: AdvertisementSnapshot(manufacturerData: Data()))
        XCTAssertNil(state.lastBatteryAt)
        XCTAssertEqual(state.presentation(now: 32, availability: .ready, asleep: false, diagnosticBusy: false).batteryText, "Battery unavailable")
    }
    func testPauseSleepBluetoothAndDiagnosticsNeverPresentFreshPercentages() {
        let id = UUID(); var state = MonitoringState(enabled: true, targetID: id)
        receive(&state, id, at: 0)
        for (availability, asleep, busy) in [(BluetoothAvailability.poweredOff, false, false), (.denied, false, false), (.ready, true, false), (.ready, false, true)] {
            XCTAssertEqual(state.presentation(now: 1, availability: availability, asleep: asleep, diagnosticBusy: busy).menuBarText, "—")
        }
        state.setEnabled(false); XCTAssertNil(state.lastBatteryAt)
        state.setEnabled(true)
        XCTAssertEqual(state.presentation(now: 2, availability: .ready, asleep: false, diagnosticBusy: false).menuBarText, "—")
        receive(&state, id, at: 3)
        XCTAssertEqual(state.presentation(now: 3, availability: .ready, asleep: false, diagnosticBusy: false).menuBarText, "96%")
        state.invalidateFreshness(); XCTAssertNil(state.nextDeadline(now: 4))
    }
    func testCandidateRetentionIsBoundedAndUnrelatedDevicesAreIgnored() {
        var state = MonitoringState(enabled: true)
        XCTAssertFalse(state.receive(id: UUID(), advertisement: AdvertisementSnapshot(localName: "Headphones"), name: nil, rssi: nil, observedAt: Date(), now: 0))
        for _ in 0..<8 { receive(&state, UUID(), at: 0) }
        XCTAssertFalse(state.receive(id: UUID(), advertisement: profile(), name: nil, rssi: nil, observedAt: Date(), now: 1))
        receive(&state, UUID(), at: 31); XCTAssertEqual(state.candidates.count, 1)
    }
    func testPublicationCoalescesBurstToOneDeadlineAndAllowsOnlyOnePerSecond() {
        var gate = MonitoringPublicationGate(); gate.published(now: 0)
        XCTAssertEqual(gate.request(now: 0.01), 1)
        for _ in 0..<1000 { XCTAssertNil(gate.request(now: 0.1)) }
        XCTAssertEqual(gate.coalesced, 1000)
        gate.published(now: 1); XCTAssertEqual(gate.request(now: 1.01), 2)
    }
    func testDiagnosticsRecordOutcomeTransitionsNotRepeatedPackets() {
        let id = UUID(); var tracker = BatteryOutcomeTracker(), log = Diagnostics()
        for _ in 0..<1000 {
            if tracker.changed(.decoded, id: id) { log.record(.advertisedBattery, fields: [.advertisedBattery(.decoded)]) }
        }
        XCTAssertEqual(log.events.count, 1)
        XCTAssertTrue(tracker.changed(.invalidValue, id: id)); XCTAssertTrue(tracker.changed(.decoded, id: id))
        let report = log.export(appVersion: "0.5.0", systemVersion: "test", services: [])
        for secret in ["96%", "P512", id.uuidString, "B5 B5"] { XCTAssertFalse(report.contains(secret)) }
        tracker.clear(); XCTAssertTrue(tracker.changed(.decoded, id: id))
    }
    @MainActor
    func testSavedPreferencesAndWindowLifecycleRemainHardwareFreeUntilActivation() {
        let suite = "SomnoireTests.\(UUID())", id = UUID()
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "monitoringEnabled"); preferences.set(id.uuidString, forKey: "selectedPeripheral")
        let manager = BluetoothManager(preferences: preferences, now: { 100 })
        XCTAssertTrue(manager.monitoringEnabled); XCTAssertEqual(manager.selectedTargetID, id)
        XCTAssertEqual(manager.availability, .notStarted); XCTAssertFalse(manager.isScanning)
        manager.diagnosticsClosed(); manager.systemSleep(); manager.systemWake()
        XCTAssertEqual(manager.availability, .notStarted); XCTAssertFalse(manager.isScanning)
        manager.pauseMonitoring(); XCTAssertFalse(preferences.bool(forKey: "monitoringEnabled"))
        manager.forgetPowerBank(); XCTAssertNil(preferences.string(forKey: "selectedPeripheral"))
        XCTAssertFalse(SomnoireAppDelegate.shouldRestoreMonitoring(isTestHost: true))
        manager.shutdown(); manager.startMonitoring(); XCTAssertFalse(manager.isScanning)
    }
    func testLiveMeasurementFreshnessPreservesZeroAndIndependentTimes() {
        let start = Date(timeIntervalSince1970: 100)
        let zero = BluetoothManager.LiveValue(value: 0, time: start)
        let voltage = BluetoothManager.LiveValue(value: 9.2, time: start.addingTimeInterval(3))
        XCTAssertEqual(zero.fresh(at: start.addingTimeInterval(4)), 0)
        XCTAssertNil(zero.fresh(at: start.addingTimeInterval(5)))
        XCTAssertEqual(voltage.fresh(at: start.addingTimeInterval(5)), 9.2)
    }
    @MainActor
    func testLocalSettingsRendering() throws {
        let manager = BluetoothManager(preferences: UserDefaults(suiteName: "SomnoireTests.SettingsRender")!)
        defer { manager.shutdown() }
        manager.panelVisibility(true); manager.settingsVisibility(true); manager.panelVisibility(false)
        XCTAssertFalse(manager.isProbing); manager.settingsVisibility(false)
        for pane in [0,1,2,3,4] {
        for dark in [false, true] {
            let height: CGFloat = 600
            manager.setAppMode(.fullReadings)
            let view = NSHostingView(rootView: SomnoireSettingsView(bluetooth: manager, pane: pane).frame(width: 760, height: height).background(dark ? Color(white: 0.12) : Color(white: 0.95))
                .environment(\.colorScheme, dark ? .dark : .light))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = view.appearance
            window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(pane)-\(dark).png"))
            window.close()
        }
        }
        for dark in [false, true] {
            let view = NSHostingView(rootView: FirstTimeSetupSheet().background(dark ? Color(white: 0.12) : Color(white: 0.95)).environment(\.colorScheme, dark ? .dark : .light))
            view.frame = NSRect(x: 0, y: 0, width: 560, height: 530)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(dark).png"))
        }
        XCTAssertTrue(ScreenField.chargingClockDuration.accepts(UInt32.max))
        XCTAssertFalse(ScreenField.clockDuration.accepts(UInt32.max))
        XCTAssertFalse(ScreenField.duration.accepts(81))
        XCTAssertFalse(ScreenField.brightness.accepts(101))
        XCTAssertEqual(HealthySettings(mode: 1, ceiling: 81, floor: 3).ceiling, 81)
        let delta = try P512TelemetryDecoder.decodePayload(Data([0x28,100,0x90,1,30]))
        XCTAssertEqual(delta.screen[.brightness], 100); XCTAssertEqual(delta.screen[.duration], 30)
    }

    @MainActor
    func testHealthyCardRenderingAndSchema() throws {
        let manager = BluetoothManager(preferences: UserDefaults(suiteName: "SomnoireTests.HealthyRender")!)
        defer { manager.shutdown() }
        let delta = try P512TelemetryDecoder.decodePayload(Data([0x80,0x35,1,0xf0,0x10,80,0xf8,0x10,20]))
        var settings = HealthySettings(); settings.receive(delta)
        XCTAssertTrue(settings.valid); XCTAssertEqual(settings.ceiling, 80); XCTAssertEqual(settings.floor, 20)
        XCTAssertFalse(HealthyChange(ceiling: 79).valid); XCTAssertFalse(HealthyChange(floor: 21).valid)
        XCTAssertFalse(HealthyChange(mode: 0).valid)
        for editing in [false, true] {
            let view = NSHostingView(rootView: HealthyChargingSection(bluetooth: manager, editing: editing, baseline: settings, draft: settings, expanded: true)
                .frame(width: 304).padding(12).background(Color(white: 0.12)).environment(\.colorScheme, .dark))
            view.appearance = NSAppearance(named: .darkAqua)
            view.frame = NSRect(origin: .zero, size: view.fittingSize); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("healthy-card-\(editing).png"))
        }
    }

    @MainActor
    func testBatteryInformationSectionRendering() throws {
        var info = BatteryInformation()
        info.receive(P512TelemetryDelta(health: 95, cycles: 32, temperatureCelsius: -4, energyInWh: 999, energyOutWh: 1001), at: Date().addingTimeInterval(-120))
        for expanded in [false, true] {
            for populated in [false, true] {
                let view = NSHostingView(rootView: BatteryInformationSection(information: populated ? info : BatteryInformation(), date: Date(), expanded: expanded)
                    .frame(width: 304).padding(12).background(Color(white: 0.12)).environment(\.colorScheme, .dark))
                view.appearance = NSAppearance(named: .darkAqua)
                view.frame = NSRect(origin: .zero, size: view.fittingSize); view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("battery-info-\(expanded)-\(populated).png"))
            }
        }
    }

    @MainActor
    func testDashboardNativeRendering() throws {
        let manager = BluetoothManager(preferences: UserDefaults(suiteName: "SomnoireTests.Dashboard")!)
        defer { manager.shutdown() }
        for large in [false, true] {
            let view = NSHostingView(rootView: SomnoireMenuView(bluetooth: manager)
                .environment(\.colorScheme, .dark)
                .environment(\.sizeCategory, large ? .accessibilityExtraExtraExtraLarge : .large))
            let size = view.fittingSize
            XCTAssertEqual(size.width, 328, accuracy: 1)
            view.frame = NSRect(origin: .zero, size: size); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("somnoire-dashboard-\(large).png"))
        }
    }

    @MainActor
    func testDiagnosticsWindowSizingInLightAndDarkAppearance() {
        let manager = BluetoothManager(preferences: UserDefaults(suiteName: "SomnoireTests.Sizing")!)
        defer { manager.shutdown() }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = NSHostingView(rootView: SomnoireDiagnosticsView(bluetooth: manager))
            hosting.appearance = NSAppearance(named: name)
            XCTAssertGreaterThanOrEqual(hosting.fittingSize.width, 560)
            XCTAssertGreaterThanOrEqual(hosting.fittingSize.height, 440)
            XCTAssertLessThan(hosting.fittingSize.width, 1000)
            XCTAssertLessThan(hosting.fittingSize.height, 1000)
        }
    }
    @MainActor
    func testHardwareContinuousMonitoringWithoutConnections() async throws {
        guard ProcessInfo.processInfo.environment["SOMNOIRE_CONTINUOUS_HARDWARE"] == "1" else { throw XCTSkip("Continuous hardware monitoring is opt-in.") }
        let suite = "SomnoireTests.Hardware.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = BluetoothManager(preferences: preferences)
        defer { manager.shutdown() }
        manager.startMonitoring(); manager.startMonitoring()
        for _ in 0..<450 {
            if manager.monitoring.percentage != nil && manager.monitoring.receipts >= 10 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard manager.availability == .ready else { throw XCTSkip("Bluetooth did not become ready for live acceptance") }
        XCTAssertNotNil(manager.monitoring.percentage, manager.monitoring.status)
        XCTAssertGreaterThanOrEqual(manager.monitoring.receipts, 10)
        XCTAssertEqual(manager.appMode, .percentageOnly)
        manager.panelVisibility(true); manager.settingsVisibility(true)
        XCTAssertEqual(manager.battery.text, manager.monitoring.menuBarText)
        XCTAssertTrue(manager.batteryIsFresh)
        XCTAssertFalse(manager.isProbing)
        let firstCount = manager.monitoring.receipts
        let firstTime = manager.monitoring.lastReading?.observedAt
        // Deliberately exceed the old 30-second scan deadline with no menu open.
        try await Task.sleep(for: .seconds(35))
        XCTAssertTrue(manager.isScanning)
        XCTAssertGreaterThan(manager.monitoring.receipts, firstCount)
        XCTAssertNotEqual(manager.monitoring.lastReading?.observedAt, firstTime)
        XCTAssertNotNil(manager.monitoring.percentage)
        XCTAssertEqual(manager.connection, .idle)
        XCTAssertEqual(manager.diagnostics.events.filter { $0.kind == .scanStarted }.count, 1)
        XCTAssertLessThanOrEqual(manager.diagnostics.events.filter { $0.kind == .advertisedBattery }.count, 2)
        XCTAssertFalse(manager.diagnostics.events.contains { [.connecting, .connected, .probeStarted, .subscription].contains($0.kind) })
        print("Continuous monitoring: received \(manager.monitoring.receipts) accepted advertisements; fresh percentage available; no GATT activity.")
        manager.pauseMonitoring(); XCTAssertFalse(manager.isScanning); XCTAssertEqual(manager.monitoring.menuBarText, "—")
        manager.startMonitoring()
        for _ in 0..<100 {
            if manager.monitoring.percentage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(manager.monitoring.percentage)
        let report = manager.diagnosticReport()
        XCTAssertTrue(report.contains("coalesced updates=")); XCTAssertFalse(report.contains("P512"))
    }

    @MainActor
    func testHardwareDiagnosticCloseResumesMonitoringAndRetainsGATT() async throws {
        guard ProcessInfo.processInfo.environment["SOMNOIRE_DIAGNOSTIC_HARDWARE"] == "1" else { throw XCTSkip("Read-only GATT lifecycle validation is opt-in.") }
        let suite = "SomnoireTests.DiagnosticHardware.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = BluetoothManager(preferences: preferences)
        defer { manager.shutdown() }
        func wait(_ seconds: Double, until predicate: () -> Bool) async throws -> Bool {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while !predicate() && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(100)) }
            return predicate()
        }
        manager.startMonitoring()
        let found = try await wait(15) { manager.monitoring.percentage != nil }
        guard found, let id = manager.selectedTargetID else { return XCTFail("No fresh selected bank; no GATT connection attempted.") }
        manager.connect(to: id) // Explicit test action: ordinary Phase 0 GATT inspection only.
        XCTAssertFalse(manager.isScanning)
        XCTAssertEqual(manager.monitoring.menuBarText, "—")
        let inspected = try await wait(10) { manager.discovery == .complete }
        XCTAssertTrue(inspected); XCTAssertFalse(manager.services.isEmpty)
        let count = manager.services.count
        manager.diagnosticsClosed()
        let resumed = try await wait(8) { manager.connection.isIdle && manager.isScanning && manager.monitoring.percentage != nil }
        XCTAssertTrue(resumed)
        XCTAssertTrue(manager.gattIsStale); XCTAssertEqual(manager.services.count, count)
        XCTAssertFalse(manager.diagnostics.events.contains { $0.kind == .probeStarted || $0.kind == .subscription })
        print("Explicit GATT inspection completed; close resumed passive monitoring and retained stale services; no probe or subscriptions.")
    }
}

final class PolishTests: XCTestCase {
    func testOnboardingRoutesAndResume() {
        XCTAssertEqual(OnboardingStep.bank.next(mode: .percentageOnly), .ready)
        XCTAssertEqual(OnboardingStep.ready.previous(mode: .percentageOnly), .bank)
        XCTAssertEqual(OnboardingStep.bank.next(mode: .fullReadings), .access)
        XCTAssertEqual(OnboardingStep.ready.previous(mode: .fullReadings), .access)
        XCTAssertFalse(OnboardingStep.bank.canAdvance(hasBank: false, live: false))
        XCTAssertTrue(OnboardingStep.bank.canAdvance(hasBank: true, live: false))
        XCTAssertFalse(OnboardingStep.access.canAdvance(hasBank: true, live: false))
        XCTAssertTrue(OnboardingStep.access.canAdvance(hasBank: true, live: true))
        let prefs = UserDefaults(suiteName: "SomnoireTests.SetupResume")!
        defer { prefs.removePersistentDomain(forName: "SomnoireTests.SetupResume") }
        prefs.set(OnboardingStep.access.rawValue, forKey: "onboardingStep")
        XCTAssertEqual(OnboardingStep(rawValue: prefs.integer(forKey: "onboardingStep")), .access)
    }

    func testRelativeAgeBoundaries() {
        let now = Date(timeIntervalSince1970: 10000)
        for (seconds, expected) in [(0,"recently"),(599,"recently"),(600,"10 minutes ago"),(899,"10 minutes ago"),(900,"15 minutes ago"),(3599,"55 minutes ago"),(3600,"a long time ago"),(-1,"recently")] {
            XCTAssertEqual(RelativeAge.text(since: now.addingTimeInterval(-Double(seconds)), at: now), expected)
        }
    }
    func testDiagnosticsUnlockOnlyAtThirteen() {
        var unlock = DiagnosticsUnlock()
        for _ in 0..<12 { XCTAssertFalse(unlock.activate()); XCTAssertFalse(unlock.unlocked) }
        XCTAssertTrue(unlock.activate()); XCTAssertTrue(unlock.unlocked)
        XCTAssertFalse(unlock.activate()); XCTAssertEqual(unlock.count, 13)
        XCTAssertFalse(DiagnosticsUnlock().unlocked)
    }
    @MainActor func testIdentityAndColorAssets() throws {
        XCTAssertNotNil(NSImage(named: "AppIcon"))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"))
        let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        XCTAssertEqual(iconFile, "AppIcon")
        XCTAssertNotNil(Bundle.main.url(forResource: iconFile, withExtension: "icns"))
        for awake in [false, true] {
            let icon = MenuBarArtwork.nouNou(awake: awake)
            XCTAssertFalse(icon.isTemplate); XCTAssertEqual(icon.size.height, 20)
            XCTAssertEqual(Set(icon.representations.map { $0.pixelsWide }), Set([20,40]))
            XCTAssertNotNil(icon.tiffRepresentation)
            let preview = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                icon.draw(in: NSRect(x: 5,y: 10,width: 20,height: 20))
                icon.draw(in: NSRect(x: 35,y: 2,width: 40,height: 40))
                return true
            }
            let bitmap = NSBitmapImageRep(data: try XCTUnwrap(preview.tiffRepresentation))!
            try bitmap.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("nounou-\(awake).png"))
        }
    }
    @MainActor func testRenderOnboardingAndAbout() throws {
        let prefs = UserDefaults(suiteName: "SomnoireTests.PolishRender")!
        prefs.removePersistentDomain(forName: "SomnoireTests.PolishRender")
        let manager = BluetoothManager(preferences: prefs)
        defer { manager.shutdown() }
        for dark in [false,true] {
            let views: [(String, AnyView)] = OnboardingStep.allCases.map { ("setup-\($0.rawValue)", AnyView(OnboardingView(bluetooth: manager).defaultAppStorage(prefs))) } + [("about",AnyView(AboutPane()))]
            for (name, root) in views {
                prefs.set(Int(name.split(separator: "-").last ?? "0") ?? 0, forKey: "onboardingStep")
                let view = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 580,height: 610), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = view
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("polish-\(name)-\(dark).png"))
                window.close()
            }
        }
    }
}

final class PercentagePrecisionTests: XCTestCase {
    let locale = Locale(identifier: "en_US")
    func testReportedFractionsAndWholeAdvertisements() {
        var battery = BatteryPresentation()
        let bank = UUID(), date = Date()
        battery.receive(bank: bank, value: 80.125, date: date, now: 0, source: "telemetry")
        XCTAssertEqual(battery.percentage, 80.125)
        for (precision, expected) in zip(PercentagePrecision.allCases, ["80%","80.1%","80.13%","80.125%"]) {
            XCTAssertEqual(battery.formatted(precision: precision, locale: locale), expected)
            XCTAssertEqual(battery.alertPercentage, 80)
            XCTAssertEqual(battery.sampledAt, 0)
        }
        battery.receive(bank: bank, value: 80, date: date.addingTimeInterval(1), now: 1, source: "advertisement")
        for precision in PercentagePrecision.allCases { XCTAssertEqual(battery.formatted(precision: precision, locale: locale), "80%") }
        XCTAssertEqual(battery.observedAt, date.addingTimeInterval(1))
        XCTAssertFalse(battery.fresh(now: 31, available: true))
    }
    func testRoundingValidationAndAlertIndependence() {
        var battery = BatteryPresentation(); let bank = UUID(), date = Date()
        XCTAssertEqual(PercentagePrecision.saved(4), .whole)
        XCTAssertEqual(PercentagePrecision.saved(-1), .whole)
        for value in [0.0, 20.499, 20.5, 99.9999, 100] {
            battery.receive(bank: bank, value: value, date: date, now: 1, source: "telemetry")
            for precision in PercentagePrecision.allCases {
                _ = battery.formatted(precision: precision, locale: locale)
                XCTAssertEqual(battery.alertPercentage, Int(value.rounded()))
            }
        }
        battery.receive(bank: bank, value: 99.9999, date: date, now: 2, source: "telemetry")
        XCTAssertEqual(battery.formatted(precision: .three, locale: locale), "100%")
        for invalid in [Double.nan, .infinity, -0.01, 100.01] {
            battery.receive(bank: bank, value: invalid, date: date, now: 3, source: "telemetry")
            XCTAssertEqual(battery.percentage, 99.9999); XCTAssertEqual(battery.sampledAt, 2)
        }
        XCTAssertEqual(battery.formatted(precision: .three, locale: Locale(identifier: "de_DE")), "100%")
    }
}

final class CredentialMigrationTests: XCTestCase {
    @MainActor func testNativeMigrationAndFailurePreservation() {
        for scenario in 0...7 { XCTAssertEqual(sn_probe_test_credential_migration(Int32(scenario)), 1, "Migration scenario \(scenario)") }
    }
}

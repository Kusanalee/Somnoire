import XCTest
import SwiftUI
import AppKit
@testable import Somnoire

final class MonitoringTests: XCTestCase {
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
        XCTAssertNotNil(manager.monitoring.percentage, manager.monitoring.status)
        XCTAssertGreaterThanOrEqual(manager.monitoring.receipts, 10)
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

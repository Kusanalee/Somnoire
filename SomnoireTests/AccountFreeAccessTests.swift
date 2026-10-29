import XCTest
@testable import Somnoire

@MainActor
private final class AccessFakeCrypto: ProbeCryptography {
    var validationSummary: PacketValidationSummary?
    let publicPoint = Data(repeating: 0xA1, count: 40)
    var cleared = false
    var settingsSequences: [UInt32] = []
    func healthyRequest(_ change: HealthyChange, sequence: UInt32) throws -> Data { settingsSequences.append(sequence); return Data(repeating: 0x55, count: 32) }
    var packet = AccessPacket(metadata: SessionPacketMetadata(source: 0x35, destination: 0x21,
        deviceSource: 1, deviceDestination: 1, commandSet: 0x35, command: 0x89, sequence: 0, payloadLength: 2),
        body: .status(AuthStatusSummary(action: .checkCredential, mode: .normal)))
    func acceptPeer(_ point: Data) throws {}
    func validateKeyInfo(_ ciphertext: Data) throws {}
    func deriveSession(_ ciphertext: Data) throws {}
    func statusRequest() throws -> Data { Data(repeating: 0xA5, count: 32) }
    func matchesStatusReply(_ ciphertext: Data) throws -> Bool { true }
    func inspectPacket(_ ciphertext: Data) throws -> SessionPacketMetadata { packet.metadata }
    func displayRequest() throws -> Data { Data(repeating: 0xD5, count: 32) }
    func credentialRequest(_ credential: ProbeCredential) throws -> Data {
        credential.clear()
        return Data(repeating: 0xC5, count: 64)
    }
    func accessReply(_ ciphertext: Data) throws -> AccessPacket {
        if ciphertext.first == 0xFF { throw ProbeFailure.invalidStatus }
        return packet
    }
    func clear() { validationSummary = nil; cleared = true }
}

@MainActor
private final class AccessHarness {
    final class Clock { var time = 0.0 }
    let clock = Clock()
    let crypto = AccessFakeCrypto()
    let probe: KeyExchangeProbe
    var writes: [(UUID, Data)] = []
    var actions: [ProbeAction] = []
    init(kind: ProbeKind = .accountFreeAccess, live: Bool = false) {
        let clock = clock, crypto = crypto
        let credential = kind == .authenticatedAccess ? ProbeCredential(userID: "123456789", serial: Data("P512000000000000".utf8)) : nil
        probe = KeyExchangeProbe(kind: kind, live: live, credential: credential, now: { clock.time }, makeCrypto: { crypto })
        probe.onAction = { [weak self] in
            self?.actions.append($0)
            if case .write(let id, let bytes) = $0 { self?.writes.append((id, bytes)) }
        }
    }
    func handshake() {
        probe.start(); probe.gattReady(); probe.subscribed(success: true)
        probe.writeCompleted(writes[0].0, success: true)
        probe.receive(ProbeFrameCodec.encode(Data([1, 0, 0]) + Data(repeating: 1, count: 40)))
        probe.writeCompleted(writes[1].0, success: true)
        probe.receive(ProbeFrameCodec.encode(Data([2]) + Data(repeating: 0, count: 32)))
    }
    func status(_ auth: AuthStatusSummary = AuthStatusSummary(action: .checkCredential, mode: .normal)) {
        handshake()
        crypto.packet.body = .status(auth)
        receive()
        XCTAssertEqual(probe.stage, .status) // Reply arrives before the write callback.
        probe.writeCompleted(writes[2].0, success: true)
    }
    func receive() { probe.receive(ProbeFrameCodec.encode(Data([1]), encrypted: true)) }
    func credentialReply(_ accepted: Bool, sequence: UInt32 = 2) {
        crypto.packet = AccessPacket(metadata: SessionPacketMetadata(source: 0x35, destination: 0x21,
            deviceSource: 1, deviceDestination: 1, commandSet: 0x35, command: 0x86, sequence: sequence, payloadLength: 1),
            body: .credentialReply(accepted))
        receive()
    }
    func telemetry(_ body: Data = Data([0xA2, 0x35, 5, 0x0D, 0, 0, 0x20, 0xC2])) {
        crypto.packet = AccessPacket(metadata: SessionPacketMetadata(source: 2, destination: 0x21,
            deviceSource: 0, deviceDestination: 0, commandSet: 0xFE, command: 0x15, sequence: 7,
            payloadLength: body.count), body: .telemetry(body))
        receive()
    }
}

final class AuthenticatedAccessTests: XCTestCase {
    @MainActor
    func testHardwareClockDiagnostic() async throws {
        guard ProcessInfo.processInfo.environment["SOMNOIRE_CLOCK_DIAGNOSTIC"] == "1" else { throw XCTSkip("Explicit clock diagnostic only") }
        let prefs = UserDefaults(suiteName: "SomnoireTests.BoundedClock")!
        prefs.removePersistentDomain(forName: "SomnoireTests.BoundedClock")
        prefs.set(UserDefaults.standard.string(forKey: "selectedPeripheral"), forKey: "selectedPeripheral")
        prefs.set(AppMode.fullReadings.rawValue, forKey: "appMode")
        let manager = BluetoothManager(preferences: prefs)
        defer { manager.shutdown() }
        manager.startMonitoring(); manager.panelVisibility(true)
        for _ in 0..<150 {
            if manager.liveStatus == .live { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard manager.liveStatus == .live else { throw XCTSkip("No live session (\(manager.availability.rawValue)); no clock write performed") }
        var finished = false, confirmed = false
        manager.diagnoseClockSync { confirmed = $0; finished = true }
        for _ in 0..<60 {
            if finished { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(finished)
        print("Clock diagnostic readback confirmed: \(confirmed)")
        print(manager.diagnosticReport().split(separator: "\n").filter { $0.contains("Clock") }.joined(separator: "\n"))
    }
    @MainActor
    func testDisabledClockMigrationAndNumericSetupValidation() {
        let prefs = UserDefaults(suiteName: "SomnoireTests.ClockGate")!
        prefs.set(true, forKey: "clockSyncEnabled")
        let manager = BluetoothManager(preferences: prefs)
        defer { manager.shutdown(); prefs.removePersistentDomain(forName: "SomnoireTests.ClockGate") }
        XCTAssertFalse(BluetoothManager.automaticClockSyncAvailable)
        XCTAssertFalse(manager.isProbing)
        for value in ["", " 12", "1e3", "１２", String(repeating: "1", count: 33)] { XCTAssertFalse(validEcoFlowID(value)) }
        XCTAssertTrue(validEcoFlowID("123456789"))
    }
    @MainActor
    func testClockCancellationAndMissingReadbackAreDistinct() {
        let h = AccessHarness(kind: .authenticatedAccess, live: true); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true); h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        var outcomes: [ClockSyncOutcome] = []
        h.probe.onClockSync = { outcomes.append($0) }
        h.probe.applyHealthy(HealthyChange(clock: ClockSyncRequest(utc: 100, offset: 800, zone: "Asia/Manila"))) { _ in }
        h.probe.cancelPaneSettings(); XCTAssertTrue(outcomes.isEmpty)
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        XCTAssertEqual(outcomes, [.sent])
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        h.clock.time = 6; h.probe.expire()
        XCTAssertEqual(outcomes.last, .readback(present: 0, matches: 0))
        h.probe.applyHealthy(HealthyChange(clock: ClockSyncRequest(utc: 100, offset: 800, zone: "Asia/Manila"))) { _ in }
        h.probe.cancelSettings(); XCTAssertEqual(outcomes.last, .cancelled)
    }

    @MainActor
    func testClockSyncRequiresFreshTimezoneReadbackAndSerializesSettings() throws {
        let h = AccessHarness(kind: .authenticatedAccess, live: true); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true); h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        let request = ClockSyncRequest(utc: 100, offset: 800, zone: "Asia/Manila")
        var result: Bool?, concurrent: Bool?
        h.probe.applyHealthy(HealthyChange(clock: request)) { result = $0 }
        h.probe.applyHealthy(HealthyChange(screen: [.brightness: 50])) { concurrent = $0 }
        XCTAssertEqual(concurrent, false)
        // 133=offset, 134=timezone ID, 135=automatic. Pre-ack data cannot confirm.
        let payload = Data([0xa8,0x08,0xa0,0x06,0xb2,0x08,11] + Array("Asia/Manila".utf8) + [0xb8,0x08,1])
        h.telemetry(payload); XCTAssertNil(result)
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        h.telemetry(Data([0xa8,0x08,0xa0,0x06])); XCTAssertNil(result)
        h.telemetry(payload); XCTAssertEqual(result, true)
    }
    func testClockOffsetsAndResourceValidation() throws {
        let date = Date(timeIntervalSince1970: 1800000000)
        XCTAssertEqual(ClockSyncRequest.make(date: date, timezone: TimeZone(secondsFromGMT: 28800)!)?.offset, 800)
        XCTAssertEqual(ClockSyncRequest.make(date: date, timezone: TimeZone(secondsFromGMT: -18000)!)?.offset, -500)
        XCTAssertNil(ClockSyncRequest.make(date: date, timezone: TimeZone(secondsFromGMT: 19800)!))
        XCTAssertNil(ClockSyncRequest.make(date: date, timezone: TimeZone(secondsFromGMT: 20700)!))
        XCTAssertFalse(ClockSyncRequest(utc: 1, offset: 800, zone: "bad\nzone").valid)
        let absent = try P512TelemetryDecoder.decodePayload(Data())
        XCTAssertNil(absent.timezoneOffset); XCTAssertNil(absent.timezoneID)
        XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(Data([0xb2,0x08,1,0xff])))
    }

    @MainActor
    func testCancelSettingsKeepsDashboardSessionAndRejectsLateAcknowledgement() {
        let h = AccessHarness(kind: .authenticatedAccess, live: true); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true); h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        var result: Bool?
        h.probe.applyHealthy(HealthyChange(screen: [.brightness: 50])) { result = $0 }
        let write = h.writes.last!.0, count = h.writes.count
        h.probe.cancelSettings(); XCTAssertEqual(result, false)
        XCTAssertTrue(h.probe.isActive)
        h.probe.writeCompleted(write, success: true)
        XCTAssertEqual(h.writes.count, count)
        h.telemetry(); XCTAssertNil(h.probe.result)
    }

    @MainActor
    func testScreenChangeUsesFreshReadbackWithoutHealthyBaseline() {
        let h = AccessHarness(kind: .authenticatedAccess, live: true); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true); h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        var result: Bool?
        h.probe.applyHealthy(HealthyChange(screen: [.brightness: 100])) { result = $0 }
        h.telemetry(Data([0x28,100])); XCTAssertNil(result)
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        h.telemetry(Data([0x28,99])); XCTAssertNil(result)
        h.telemetry(Data([0x28,100])); XCTAssertEqual(result, true)
    }

    @MainActor
    func testSettingsRequireAcknowledgementAndFreshReadbackAndNeverRetry() {
        let h = AccessHarness(kind: .authenticatedAccess, live: true); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true); h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        // Reported mode=1, ceiling=80, floor=0; all public synthetic varints.
        let body = Data([0x80,0x35,1,0xf0,0x10,80,0xf8,0x10,0])
        h.telemetry(body)
        var result: Bool?
        h.probe.applyHealthy(HealthyChange(ceiling: 80)) { result = $0 }
        h.telemetry(body); XCTAssertNil(result)
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        h.telemetry(body); XCTAssertNil(result) // Refresh write not acknowledged yet.
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        h.telemetry(body); XCTAssertEqual(result, true)
        XCTAssertEqual(h.crypto.settingsSequences, [3])
        result = nil
        h.probe.applyHealthy(HealthyChange(ceiling: 90)) { result = $0 }
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        h.probe.writeCompleted(h.writes.last!.0, success: true)
        h.telemetry(body); XCTAssertNil(result)
        let count = h.writes.count
        h.clock.time = 5; h.probe.expire(); XCTAssertEqual(result, false)
        XCTAssertEqual(h.writes.count, count)
        XCTAssertEqual(h.crypto.settingsSequences, [3,4])
        result = nil
        h.probe.applyHealthy(HealthyChange(mode: 2)) { result = $0 }
        h.probe.cancel(); XCTAssertEqual(result, false)
    }

    @MainActor
    func testLiveStreamExceedsDiagnosticWindowAndTimesOutOnSilence() {
        let h = AccessHarness(kind: .authenticatedAccess, live: true); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true); h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        for second in 1...90 {
            h.clock.time = Double(second); h.telemetry(); h.probe.expire()
            XCTAssertNil(h.probe.result)
        }
        h.clock.time = 105; h.probe.expire()
        XCTAssertEqual(h.probe.result?.outcome, .failed(.stageTimeout))
        XCTAssertTrue(h.crypto.cleared)
    }

    func testCredentialCopiesSurviveOriginalCleanup() throws {
        let credential = try XCTUnwrap(ProbeCredential(userID: "123", serial: Data("P512000000000000".utf8)))
        let copy = try XCTUnwrap(credential.copy())
        credential.clear()
        XCTAssertNotNil(copy.copy())
        XCTAssertNil(credential.copy())
        copy.clear(); XCTAssertNil(copy.copy())
    }

    @MainActor
    func testManagerRecordsAuthenticatedIntentWithoutConnectingAnUnseenBank() {
        let defaults = UserDefaults(suiteName: "Somnoire.AuthenticatedIntent.\(UUID().uuidString)")!
        let manager = BluetoothManager(preferences: defaults)
        XCTAssertFalse(manager.connectAndProbe(to: UUID(), kind: .authenticatedAccess, userID: "123456789"))
        XCTAssertEqual(manager.connection, .idle)
        XCTAssertEqual(manager.availability, .notStarted)
        XCTAssertEqual(manager.diagnostics.events.last?.kind, .probeRequested)
        XCTAssertEqual(manager.diagnostics.events.last?.fields, [.probeKind(.authenticatedAccess)])
        XCTAssertFalse(manager.diagnosticReport().contains("123456789"))
        manager.shutdown()
    }

    @MainActor
    func testAuthenticationAndReportBothWaitForWriteAcknowledgement() {
        let h = AccessHarness(kind: .authenticatedAccess); h.status()
        XCTAssertEqual(h.probe.stage, .checkingCredential)
        XCTAssertEqual(h.writes.count, 4)
        XCTAssertEqual(h.writes[3].1, ProbeFrameCodec.encode(Data(repeating: 0xC5, count: 64), encrypted: true))
        h.credentialReply(true)
        XCTAssertEqual(h.probe.stage, .checkingCredential)
        XCTAssertEqual(h.writes.count, 4)
        h.probe.writeCompleted(h.writes[3].0, success: true)
        XCTAssertEqual(h.probe.stage, .requestingDisplay)
        XCTAssertEqual(h.writes.count, 5)
        h.telemetry()
        XCTAssertFalse(h.actions.contains { if case .decodedTelemetry = $0 { true } else { false } })
        h.probe.writeCompleted(h.writes[4].0, success: true)
        XCTAssertEqual(h.probe.stage, .observing)
        h.clock.time = 30; h.probe.expire()
        XCTAssertEqual(h.probe.result?.outcome, .authenticatedTelemetryDecoded)
        XCTAssertEqual(h.probe.result?.access?.credentialAccepted, true)
        XCTAssertEqual(h.probe.result?.access?.portPowerUpdates, 1)
        XCTAssertEqual(h.probe.result?.access?.latestDelta?.ports[.usbC1]?.watts, -40)
        XCTAssertTrue(h.crypto.cleared)
        let result = h.probe.result
        h.credentialReply(false); h.telemetry(); h.probe.cancel()
        XCTAssertEqual(h.probe.result, result)
    }

    @MainActor
    func testOutOfRangeBatteryAllowsPortTelemetryAndCompletesBoundedSession() {
        let h = AccessHarness(kind: .authenticatedAccess); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true)
        h.credentialReply(true)
        let body = Data([0xb5, 0x10, 0, 0, 0xca, 0x42, 0xc2, 0x35, 5, 0x0d, 0, 0, 0x20, 0xc2])
        h.telemetry(body) // Early body waits for the report write acknowledgement.
        XCTAssertFalse(h.actions.contains { if case .telemetryValueUnavailable = $0 { true } else { false } })
        h.probe.writeCompleted(h.writes[4].0, success: true)
        h.clock.time = 30; h.probe.expire()
        XCTAssertEqual(h.probe.result?.outcome, .authenticatedTelemetryDecoded)
        XCTAssertEqual(h.probe.result?.access?.decodedPackets, 1)
        XCTAssertEqual(h.probe.result?.access?.portPowerUpdates, 1)
        XCTAssertEqual(h.probe.result?.access?.latestDelta?.ports[.usbC2]?.watts, -40)
        XCTAssertNil(h.probe.result?.access?.latestDelta?.batteryPercentage)
        XCTAssertTrue(h.crypto.cleared)
        let warnings = h.actions.compactMap { action -> TelemetryValidationSummary? in
            if case .telemetryValueUnavailable(let summary) = action { return summary }; return nil
        }
        XCTAssertEqual(warnings.count, 1)
        guard let summary = warnings.first else { return }
        var log = Diagnostics()
        log.record(.telemetryValueUnavailable, fields: [.telemetryValidation(summary)])
        let report = log.export(appVersion: "test", systemVersion: "test", services: [])
        XCTAssertTrue(report.contains("Telemetry measurement unavailable"))
        XCTAssertTrue(report.contains("reason=invalidBattery"))
        XCTAssertTrue(report.contains("field=262"))
        XCTAssertFalse(report.contains("101"))
        XCTAssertFalse(report.contains("-40"))
    }

    @MainActor
    func testRejectedTelemetryReportsStructureWithoutPartialCommit() {
        let h = AccessHarness(kind: .authenticatedAccess); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true)
        h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        // Valid top-level input power followed by a malformed C2 nested float.
        h.telemetry(Data([0x1d, 0, 0, 0x80, 0x3f, 0xc2, 0x35, 2, 0x0d, 0]))
        XCTAssertEqual(h.probe.result?.outcome, .failed(.invalidTelemetry))
        XCTAssertEqual(h.probe.result?.access?.decodedPackets, 0)
        XCTAssertEqual(h.probe.result?.access?.portPowerUpdates, 0)
        XCTAssertNil(h.probe.result?.access?.latestDelta)
        XCTAssertTrue(h.crypto.cleared)
        let summaries = h.actions.compactMap { action -> TelemetryValidationSummary? in
            if case .telemetryValidation(let summary) = action { return summary }; return nil
        }
        XCTAssertEqual(summaries.count, 1)
        guard let summary = summaries.first else { return }
        XCTAssertEqual(summary.port, .usbC2)
        XCTAssertEqual(summary.offset, 8)
        var log = Diagnostics()
        log.record(.telemetryValidation, fields: [.telemetryValidation(summary)])
        let report = log.export(appVersion: "test", systemVersion: "test", services: [])
        XCTAssertTrue(report.contains("location=port field 856"))
        XCTAssertTrue(report.contains("reason=malformed"))
        XCTAssertFalse(report.contains("1d0000803f"))
        XCTAssertFalse(report.contains("watts="))
        h.telemetry(); XCTAssertEqual(h.probe.result?.access?.decodedPackets, 0)
    }

    @MainActor
    func testDecodedTelemetryWithoutPortMeasurementsIsDistinctFromSilence() {
        let h = AccessHarness(kind: .authenticatedAccess); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true)
        h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        // Valid protobuf input sum, with no embedded port measurement.
        h.telemetry(Data([0x1D, 0, 0, 0x80, 0x3F]))
        h.clock.time = 30; h.probe.expire()
        XCTAssertEqual(h.probe.result?.outcome, .authenticatedTelemetryWithoutPortMeasurements)
        XCTAssertEqual(h.probe.result?.access?.credentialAccepted, true)
        XCTAssertEqual(h.probe.result?.access?.decodedPackets, 1)
        XCTAssertEqual(h.probe.result?.access?.portPowerUpdates, 0)
        XCTAssertEqual(h.probe.result?.access?.latestDelta?.inputWatts, 1)
        XCTAssertTrue(h.probe.result?.access?.latestDelta?.ports.isEmpty == true)
        XCTAssertTrue(h.crypto.cleared)
    }

    @MainActor
    func testRejectedCredentialCannotRequestReportOrAcceptTelemetry() {
        let h = AccessHarness(kind: .authenticatedAccess); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true)
        h.telemetry() // Valid telemetry before authentication cannot count.
        h.credentialReply(false)
        XCTAssertEqual(h.writes.count, 4)
        XCTAssertEqual(h.probe.result?.outcome, .failed(.credentialRejected))
        XCTAssertEqual(h.probe.result?.access?.credentialAccepted, false)
        XCTAssertEqual(h.probe.result?.access?.reportRequestIssued, false)
        XCTAssertNil(h.probe.result?.access?.latestDelta)
        XCTAssertTrue(h.crypto.cleared)
    }

    @MainActor
    func testCredentialStatusAndSequenceAreRequired() {
        for status in [AuthStatusSummary(action: .setCredential, mode: .normal),
                       AuthStatusSummary(action: .checkCredential, mode: .omos), AuthStatusSummary()] {
            let h = AccessHarness(kind: .authenticatedAccess); h.status(status)
            XCTAssertEqual(h.writes.count, 3)
            XCTAssertNotNil(h.probe.result)
            XCTAssertEqual(h.probe.result?.access?.credentialCheckIssued, false)
        }
        let h = AccessHarness(kind: .authenticatedAccess); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true)
        h.credentialReply(true, sequence: 1)
        XCTAssertEqual(h.probe.stage, .checkingCredential)
        XCTAssertEqual(h.writes.count, 4)
        h.clock.time = 3; h.probe.expire()
        XCTAssertEqual(h.probe.result?.outcome, .failed(.stageTimeout))
        XCTAssertNil(h.probe.result?.access?.credentialAccepted)
    }

    @MainActor
    func testAuthenticatedStatusOnlyIsNotTelemetrySuccess() {
        let h = AccessHarness(kind: .authenticatedAccess); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true); h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        h.clock.time = 30; h.probe.expire()
        XCTAssertEqual(h.probe.result?.outcome, .authenticatedWithoutTelemetry)
        XCTAssertEqual(h.probe.result?.access?.credentialAccepted, true)
        XCTAssertEqual(h.probe.result?.access?.portPowerUpdates, 0)
    }

    @MainActor
    func testCredentialStageCleanupAndBounds() {
        for failure in ["cancel", "disconnect", "write", "packet", "setup"] {
            let h = AccessHarness(kind: .authenticatedAccess); h.status()
            switch failure {
            case "cancel": h.probe.cancel()
            case "disconnect": h.probe.fail(.disconnected)
            case "write": h.probe.writeCompleted(h.writes[3].0, success: false)
            case "packet": h.probe.receive(ProbeFrameCodec.encode(Data([0xFF]), encrypted: true))
            default: h.clock.time = 16; h.probe.expire()
            }
            XCTAssertNotNil(h.probe.result); XCTAssertTrue(h.crypto.cleared)
            XCTAssertEqual(h.writes.count, 4); XCTAssertNil(h.probe.deadline)
            XCTAssertNil(h.probe.result?.access?.credentialAccepted)
        }
        let absent = KeyExchangeProbe(kind: .authenticatedAccess)
        absent.start()
        XCTAssertEqual(absent.result?.outcome, .failed(.invalidCredential))
        let credential = ProbeCredential(userID: "123456789", serial: Data("P512000000000000".utf8))!
        let cancelled = KeyExchangeProbe(kind: .authenticatedAccess, credential: credential)
        cancelled.start(); cancelled.cancel()
        // A cleared credential cannot be reused in any native request.
        let crypto = try? NativeProbeCrypto()
        XCTAssertThrowsError(try crypto?.credentialRequest(credential))
    }

    @MainActor
    func testFragmentedCredentialReplyAndFailureAfterAcceptance() {
        let h = AccessHarness(kind: .authenticatedAccess); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true)
        h.crypto.packet = AccessPacket(metadata: SessionPacketMetadata(source: 0x35, destination: 0x21,
            deviceSource: 1, deviceDestination: 1, commandSet: 0x35, command: 0x86, sequence: 2, payloadLength: 1),
            body: .credentialReply(true))
        for byte in ProbeFrameCodec.encode(Data([1]), encrypted: true) { h.probe.receive(Data([byte])) }
        XCTAssertEqual(h.probe.stage, .requestingDisplay)
        h.probe.fail(.disconnected)
        XCTAssertEqual(h.probe.result?.access?.credentialAccepted, true)
        XCTAssertEqual(h.probe.result?.outcome, .failed(.disconnected))
        XCTAssertNil(h.probe.result?.access?.latestDelta)
    }

    func testNativeCredentialPacketAndRepliesAgainstIndependentVectors() throws {
        struct Case: Decodable { let name: String, ciphertext: String, kind: Int32, accepted: UInt8 }
        struct Vector: Decodable {
            let local_private: String, peer_public: String, valid_info: String, credential_request: String
            let credential_cases: [Case]
        }
        struct Fixture: Decodable { let vectors: [Vector] }
        func bytes(_ s: String) -> [UInt8] {
            stride(from: 0, to: s.count, by: 2).map {
                let start = s.index(s.startIndex, offsetBy: $0)
                return UInt8(s[start..<s.index(start, offsetBy: 2)], radix: 16)!
            }
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ProbeVectors", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let tableURL = try XCTUnwrap(Bundle.main.url(forResource: "session_table", withExtension: "bin"))
        let table = [UInt8](try Data(contentsOf: tableURL))
        let id = Array("123456789".utf8), serial = Array("P512000000000000".utf8)
        for vector in fixtures.vectors {
            var point = [UInt8](repeating: 0, count: 40)
            let context = try XCTUnwrap(sn_probe_test_create(bytes(vector.local_private), &point))
            defer { sn_probe_destroy(context) }
            XCTAssertEqual(sn_probe_accept_peer(context, bytes(vector.peer_public)), 1)
            let info = bytes(vector.valid_info)
            XCTAssertEqual(sn_probe_derive_session(context, info, info.count, table, table.count), 1)
            var reply = SNAccessReply(), body = [UInt8](repeating: 0xCC, count: 984), length = 123
            let unsolicited = bytes(vector.credential_cases[0].ciphertext)
            XCTAssertEqual(sn_probe_access_reply(context, unsolicited, unsolicited.count, &reply, &body, body.count, &length), 0)
            let credential = try XCTUnwrap(sn_probe_credential_create(id, id.count, serial, serial.count))
            defer { sn_probe_credential_destroy(credential) }
            var request = [UInt8](repeating: 0, count: 64)
            XCTAssertEqual(sn_probe_credential_request(context, credential, &request), 1)
            XCTAssertEqual(request, bytes(vector.credential_request))
            for item in vector.credential_cases {
                let cipher = bytes(item.ciphertext)
                let result = sn_probe_access_reply(context, cipher, cipher.count, &reply, &body, body.count, &length)
                XCTAssertEqual(result, item.kind, item.name)
                XCTAssertEqual(reply.credential_accepted, item.accepted, item.name)
                let failure: [String: UInt8] = ["bad-padding": 1, "zero-padding-valid-prefix": 1,
                    "inconsistent-padding": 1, "short-inner": 2, "bad-header": 3,
                    "other-inner-version": 4, "wrong-version": 5, "bad-length": 6, "bad-crc": 7]
                XCTAssertEqual(reply.validation_failure, failure[item.name] ?? 0, item.name)
                XCTAssertEqual(length, 0); XCTAssertTrue(body.allSatisfy { $0 == 0 })
            }
            XCTAssertEqual(sn_probe_credential_request(context, credential, &request), 0)
            XCTAssertTrue(request.allSatisfy { $0 == 0 }) // One credential check per session.
        }
        for invalid in ["", " 123", "123 ", "-1", "１２３", "1e3", "password", String(repeating: "1", count: 33)] {
            let value = Array(invalid.utf8)
            XCTAssertNil(sn_probe_credential_create(value, value.count, serial, serial.count))
        }
        for invalid in ["P521000000000000", "P512", "P51200000000000!", "p512000000000000"] {
            let value = Array(invalid.utf8)
            XCTAssertNil(sn_probe_credential_create(id, id.count, value, value.count))
        }
    }

    func testV19RequiresAuthenticatedSessionAndValidatesIndependentFrames() throws {
        struct Case: Decodable {
            let name: String, ciphertext: String, telemetry: String
            let kind: Int32, failure: UInt8
        }
        struct CredentialCase: Decodable { let name: String, ciphertext: String }
        struct Vector: Decodable {
            let local_private: String, peer_public: String, valid_info: String
            struct HealthyCase: Decodable { let mode: Int32, ceiling: Int32, floor: Int32; let ciphertext: String }
            struct ScreenCase: Decodable { let field: UInt32, value: UInt32; let ciphertext: String }
            struct ClockCase: Decodable { let offset: Int32; let zone: String; let ciphertext: String }
            let clock_cases: [ClockCase]
            let screen_cases: [ScreenCase]
            let healthy_cases: [HealthyCase]
            let credential_cases: [CredentialCase], v19_cases: [Case]
        }
        struct Fixture: Decodable { let vectors: [Vector] }
        func bytes(_ s: String) -> [UInt8] {
            stride(from: 0, to: s.count, by: 2).map {
                let start = s.index(s.startIndex, offsetBy: $0)
                return UInt8(s[start..<s.index(start, offsetBy: 2)], radix: 16)!
            }
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ProbeVectors", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let tableURL = try XCTUnwrap(Bundle.main.url(forResource: "session_table", withExtension: "bin"))
        let table = [UInt8](try Data(contentsOf: tableURL))
        for vector in fixtures.vectors {
            var point = [UInt8](repeating: 0, count: 40)
            let context = try XCTUnwrap(sn_probe_test_create(bytes(vector.local_private), &point))
            defer { sn_probe_destroy(context) }
            XCTAssertEqual(sn_probe_accept_peer(context, bytes(vector.peer_public)), 1)
            let info = bytes(vector.valid_info)
            XCTAssertEqual(sn_probe_derive_session(context, info, info.count, table, table.count), 1)
            var reply = SNAccessReply(), body = [UInt8](repeating: 0xCC, count: 984), length = 123
            var refused = [UInt8](repeating: 0xcc, count: 32)
            XCTAssertEqual(sn_probe_healthy_request(context, 3, 1, -1, -1, &refused), 0)
            XCTAssertTrue(refused.allSatisfy { $0 == 0 })
            let display = bytes(vector.v19_cases[0].ciphertext)
            XCTAssertEqual(sn_probe_access_reply(context, display, display.count, &reply, &body, body.count, &length), -1)
            XCTAssertEqual(reply.validation_failure, 5)
            let mixedRoute = bytes(try XCTUnwrap(vector.v19_cases.first { $0.name == "observed-bank-route" }).ciphertext)
            XCTAssertEqual(sn_probe_access_reply(context, mixedRoute, mixedRoute.count, &reply, &body, body.count, &length), -1)
            XCTAssertEqual(reply.validation_failure, 5)
            let id = Array("123456789".utf8), serial = Array("P512000000000000".utf8)
            let credential = try XCTUnwrap(sn_probe_credential_create(id, id.count, serial, serial.count))
            defer { sn_probe_credential_destroy(credential) }
            var request = [UInt8](repeating: 0, count: 64)
            XCTAssertEqual(sn_probe_credential_request(context, credential, &request), 1)
            // Merely constructing the authentication request cannot enable V19.
            XCTAssertEqual(sn_probe_access_reply(context, display, display.count, &reply, &body, body.count, &length), -1)
            XCTAssertEqual(reply.validation_failure, 5)
            let acceptance = bytes(try XCTUnwrap(vector.credential_cases.first { $0.name == "accepted" }).ciphertext)
            XCTAssertEqual(sn_probe_access_reply(context, acceptance, acceptance.count, &reply, &body, body.count, &length), 4)
            XCTAssertEqual(reply.credential_accepted, 1)
            for item in vector.clock_cases {
                var output = [UInt8](repeating: 0, count: 256), length = 0
                XCTAssertEqual(sn_probe_clock_request(context, 3, 1800000000, item.offset, item.zone, &output, 256, &length), 1)
                XCTAssertEqual(Data(output.prefix(length)), Data(bytes(item.ciphertext)))
            }
            for field: UInt32 in [301,302,303,190] {
                var output = [UInt8](repeating: 0xcc, count: 32)
                XCTAssertEqual(sn_probe_screen_request(context, 3, field, 1, &output), 0)
                XCTAssertTrue(output.allSatisfy { $0 == 0 })
            }
            var clockOutput = [UInt8](repeating: 0, count: 256), clockLength = 0
            XCTAssertEqual(sn_probe_clock_request(context, 3, 1800000000, -500, "America/New_York", &clockOutput, 256, &clockLength), 1)
            XCTAssertGreaterThan(clockLength, 32)
            XCTAssertEqual(clockLength % 16, 0)
            XCTAssertEqual(sn_probe_clock_request(context, 2, 1800000000, 800, "Asia/Manila", &clockOutput, 256, &clockLength), 0)
            XCTAssertEqual(clockLength, 0); XCTAssertTrue(clockOutput.allSatisfy { $0 == 0 })
            XCTAssertEqual(sn_probe_clock_request(context, 3, 1800000000, 550, "Asia/Kolkata", &clockOutput, 256, &clockLength), 0)
            for item in vector.screen_cases {
                var output = [UInt8](repeating: 0, count: 32)
                XCTAssertEqual(sn_probe_screen_request(context, 3, item.field, item.value, &output), 1)
                XCTAssertEqual(output, bytes(item.ciphertext))
                XCTAssertEqual(sn_probe_screen_request(context, 3, 1, 1, &output), 0)
                XCTAssertTrue(output.allSatisfy { $0 == 0 })
                XCTAssertEqual(sn_probe_screen_request(context, 2, item.field, item.value, &output), 0)
            }
            for item in vector.healthy_cases {
                var output = [UInt8](repeating: 0, count: 32)
                XCTAssertEqual(sn_probe_healthy_request(context, 3, item.mode, item.ceiling, item.floor, &output), 1)
                XCTAssertEqual(output, bytes(item.ciphertext))
                XCTAssertEqual(sn_probe_healthy_request(context, 2, item.mode, item.ceiling, item.floor, &output), 0)
                XCTAssertTrue(output.allSatisfy { $0 == 0 })
                XCTAssertEqual(sn_probe_healthy_request(context, 3, 1, 79, 21, &output), 0)
            }
            for item in vector.v19_cases {
                let cipher = bytes(item.ciphertext)
                let result = sn_probe_access_reply(context, cipher, cipher.count, &reply, &body, body.count, &length)
                XCTAssertEqual(result, item.kind, item.name)
                XCTAssertEqual(reply.validation_failure, item.failure, item.name)
                if item.failure == 8 || item.failure == 9 {
                    XCTAssertGreaterThan(reply.observed_inner_length, 0)
                    XCTAssertGreaterThan(reply.declared_payload_length, 0)
                    XCTAssertLessThanOrEqual(reply.v19_marker_flags, 3)
                } else {
                    XCTAssertEqual(reply.observed_inner_length, 0)
                    XCTAssertEqual(reply.declared_payload_length, 0)
                    XCTAssertEqual(reply.v19_marker_flags, 0)
                }
                XCTAssertEqual(Array(body.prefix(length)), bytes(item.telemetry), item.name)
                if result >= 0 { XCTAssertEqual(reply.metadata.version, 19) }
                else { XCTAssertEqual(reply.metadata.version, 0); XCTAssertEqual(reply.metadata.payload_length, 0) }
                if item.kind == 3 {
                    let delta = try P512TelemetryDecoder.decodePayload(Data(body.prefix(length)))
                    XCTAssertEqual(delta.ports[.usbC1]?.watts, -40)
                    var small = [UInt8](repeating: 0xCC, count: 7)
                    XCTAssertEqual(sn_probe_access_reply(context, cipher, cipher.count, &reply, &small, small.count, &length), -1)
                    XCTAssertEqual(length, 0); XCTAssertTrue(small.allSatisfy { $0 == 0 })
                } else { XCTAssertEqual(length, 0); XCTAssertTrue(body.allSatisfy { $0 == 0 }) }
            }
            // Earlier probes remain V3-only even in a context that authenticated.
            var metadata = SNSessionPacketMetadata()
            XCTAssertEqual(sn_probe_inspect_packet(context, display, display.count, &metadata), -1)
            XCTAssertEqual(metadata.version, 0)
            XCTAssertEqual(sn_probe_status_reply(context, display, display.count), -1)
        }
    }

    @MainActor
    func testLayoutFailureEmitsOnlyTypedStructureBeforeCleanup() {
        let h = AccessHarness(kind: .authenticatedAccess); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true); h.credentialReply(true)
        h.probe.writeCompleted(h.writes[4].0, success: true)
        let summary = PacketValidationSummary(observedLength: 21, declaredLength: 1, marker: .plain)
        h.crypto.validationSummary = summary
        h.probe.receive(ProbeFrameCodec.encode(Data([0xFF]), encrypted: true))
        XCTAssertTrue(h.actions.contains { if case .packetValidation(let value) = $0 { value == summary } else { false } })
        XCTAssertNil(h.crypto.validationSummary); XCTAssertTrue(h.crypto.cleared)
        XCTAssertEqual(h.probe.result?.access?.credentialAccepted, true)
        XCTAssertEqual(h.probe.result?.access?.portPowerUpdates, 0)
        var log = Diagnostics()
        log.record(.packetValidation, fields: [.packetValidation(summary)])
        let report = log.export(appVersion: "test", systemVersion: "test", services: [])
        XCTAssertTrue(report.contains("inner bytes=21")); XCTAssertTrue(report.contains("declared bytes=1"))
        for secret in ["123456789", "P512000000000000", "sessionKey", "a235050d000020c2"] {
            XCTAssertFalse(report.contains(secret))
        }
    }

    func testSanitizedAuthenticationOutcome() {
        var log = Diagnostics()
        log.record(.authenticationStatus, fields: [.credentialAccepted(true)])
        let report = log.export(appVersion: "test", systemVersion: "test", services: [])
        XCTAssertTrue(report.contains("existing credential=accepted"))
        for secret in ["123456789", "P512000000000000", "MD5(", "sessionKey"] { XCTAssertFalse(report.contains(secret)) }
    }
}

final class AccountFreeAccessTests: XCTestCase {
    @MainActor
    func testSoleReportRequestAndEarlyTelemetryWaitForWriteAcknowledgement() {
        let h = AccessHarness(); h.status()
        XCTAssertEqual(h.writes.count, 4)
        XCTAssertEqual(h.writes[3].1, ProbeFrameCodec.encode(Data(repeating: 0xD5, count: 32), encrypted: true))
        XCTAssertEqual(h.probe.stage, .requestingDisplay)
        h.telemetry()
        XCTAssertFalse(h.actions.contains { if case .decodedTelemetry = $0 { true } else { false } })
        h.probe.writeCompleted(h.writes[3].0, success: true)
        XCTAssertEqual(h.probe.stage, .observing)
        XCTAssertEqual(h.probe.deadline, 30)
        h.clock.time = 4; h.telemetry() // No inherited three-second stage timeout.
        h.clock.time = 30; h.probe.expire()
        let result = h.probe.result
        XCTAssertEqual(result?.outcome, .portTelemetryDecoded)
        XCTAssertEqual(result?.access?.portPowerUpdates, 2)
        XCTAssertEqual(result?.access?.latestDelta?.ports[.usbC1]?.watts, -40)
        XCTAssertEqual(h.writes.count, 4); XCTAssertTrue(h.crypto.cleared)
        h.probe.writeCompleted(h.writes[3].0, success: false); h.telemetry()
        XCTAssertEqual(h.probe.result, result)
    }
    @MainActor
    func testUnknownOrUnsupportedStatusCannotIssueReportOrAuthentication() {
        for auth in [AuthStatusSummary(), AuthStatusSummary(action: .unknown, mode: .normal),
                     AuthStatusSummary(action: .checkCredential, mode: .unknown),
                     AuthStatusSummary(action: .checkCredential, mode: .omos)] {
            let h = AccessHarness(); h.status(auth)
            XCTAssertNotNil(h.probe.result); XCTAssertEqual(h.writes.count, 3)
            XCTAssertEqual(h.probe.result?.access?.authentication, auth)
            XCTAssertEqual(h.probe.result?.access?.reportRequestIssued, false)
            XCTAssertTrue(h.crypto.cleared)
        }
        let h = AccessHarness(); h.status(AuthStatusSummary(action: .setCredential, mode: .normal))
        // An unset credential still allows only the identical fixed report request.
        XCTAssertEqual(h.writes.count, 4)
        XCTAssertEqual(h.writes[3].1, ProbeFrameCodec.encode(Data(repeating: 0xD5, count: 32), encrypted: true))
        h.probe.cancel()
    }
    @MainActor
    func testStatusAndRequestRepliesAloneNeverProvePortTelemetry() {
        let h = AccessHarness(); h.status()
        h.probe.writeCompleted(h.writes[3].0, success: true)
        h.crypto.packet.body = .reportReply; h.receive()
        h.clock.time = 29; h.receive()
        XCTAssertEqual(h.probe.deadline, 30)
        h.clock.time = 30; h.probe.expire()
        XCTAssertEqual(h.probe.result?.outcome, .accessNotEstablished)
        XCTAssertEqual(h.probe.result?.access?.reportReplyReceived, true)
        XCTAssertEqual(h.probe.result?.access?.portPowerUpdates, 0)
        XCTAssertNil(h.probe.result?.access?.latestDelta)
        XCTAssertEqual(h.writes.count, 4)
    }
    @MainActor
    func testUnrelatedAuthenticationReplyDoesNotUnlockStatusOrResetDeadline() {
        let h = AccessHarness(); h.handshake()
        h.probe.writeCompleted(h.writes[2].0, success: true)
        h.crypto.packet = AccessPacket(metadata: SessionPacketMetadata(source: 0x35, destination: 0x21,
            deviceSource: 1, deviceDestination: 1, commandSet: 0x35, command: 0x86, sequence: 0, payloadLength: 1),
            body: .unrelated)
        h.clock.time = 2; h.receive(); XCTAssertEqual(h.probe.deadline, 3)
        h.clock.time = 3; h.probe.expire()
        XCTAssertEqual(h.probe.result?.outcome, .failed(.stageTimeout))
        XCTAssertEqual(h.writes.count, 3)
    }
    @MainActor
    func testFailureCancellationAndQueuedPayloadCleanup() {
        for failure in ["cancel", "disconnect", "write", "payload"] {
            let h = AccessHarness(); h.status()
            if failure != "payload" { h.telemetry() }
            switch failure {
            case "cancel": h.probe.cancel()
            case "disconnect": h.probe.fail(.disconnected)
            case "write": h.probe.writeCompleted(h.writes[3].0, success: false)
            default: h.telemetry(Data([0]))
            }
            XCTAssertNotNil(h.probe.result); XCTAssertTrue(h.crypto.cleared)
            XCTAssertEqual(h.probe.result?.access?.portPowerUpdates, 0)
            XCTAssertNil(h.probe.result?.access?.latestDelta)
            XCTAssertEqual(h.writes.count, 4); XCTAssertNil(h.probe.deadline)
            h.probe.writeCompleted(h.writes[3].0, success: true)
            XCTAssertEqual(h.probe.result?.access?.portPowerUpdates, 0)
        }
    }
    @MainActor
    func testPendingWriteAndOverallDeadlinesRemainBounded() {
        let h = AccessHarness(); h.status(); h.clock.time = 3; h.probe.expire()
        XCTAssertEqual(h.probe.result?.outcome, .failed(.stageTimeout))
        XCTAssertEqual(h.writes.count, 4)
        let setup = AccessHarness(); setup.probe.start(); setup.clock.time = 16; setup.probe.expire()
        XCTAssertEqual(setup.probe.result?.outcome, .failed(.overallTimeout))
    }
    func testNativeRequestAndPayloadAllowlistMatchIndependentVectors() throws {
        struct Case: Decodable { let name: String, ciphertext: String, kind: Int32, action: UInt8, mode: UInt8, telemetry: String }
        struct Vector: Decodable {
            let local_private: String, peer_public: String, valid_info: String, display_request: String
            let access_cases: [Case]
        }
        struct Fixture: Decodable { let vectors: [Vector] }
        func bytes(_ s: String) -> [UInt8] {
            stride(from: 0, to: s.count, by: 2).map {
                let start = s.index(s.startIndex, offsetBy: $0)
                return UInt8(s[start..<s.index(start, offsetBy: 2)], radix: 16)!
            }
        }
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ProbeVectors", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let tableURL = try XCTUnwrap(Bundle.main.url(forResource: "session_table", withExtension: "bin"))
        let table = [UInt8](try Data(contentsOf: tableURL))
        for vector in fixture.vectors {
            var point = [UInt8](repeating: 0, count: 40)
            let context = try XCTUnwrap(sn_probe_test_create(bytes(vector.local_private), &point))
            defer { sn_probe_destroy(context) }
            XCTAssertEqual(sn_probe_accept_peer(context, bytes(vector.peer_public)), 1)
            let info = bytes(vector.valid_info)
            XCTAssertEqual(sn_probe_derive_session(context, info, info.count, table, table.count), 1)
            var request = [UInt8](repeating: 0, count: 32)
            XCTAssertEqual(sn_probe_display_request(context, &request), 1)
            XCTAssertEqual(request, bytes(vector.display_request))
            for item in vector.access_cases {
                let ciphertext = bytes(item.ciphertext)
                var reply = SNAccessReply(), body = [UInt8](repeating: 0xCC, count: 984), length = 123
                let result = sn_probe_access_reply(context, ciphertext, ciphertext.count, &reply, &body, body.count, &length)
                XCTAssertEqual(result, item.kind, item.name)
                XCTAssertEqual(reply.auth_action, item.action, item.name)
                XCTAssertEqual(reply.auth_mode, item.mode, item.name)
                XCTAssertEqual(Array(body.prefix(length)), bytes(item.telemetry), item.name)
                if item.kind != 3 { XCTAssertEqual(length, 0); XCTAssertTrue(body.allSatisfy { $0 == 0 }, item.name) }
                if item.kind < 0 { XCTAssertEqual(reply.metadata.payload_length, 0) }
                if item.kind == 3 {
                    let delta = try P512TelemetryDecoder.decodePayload(Data(body.prefix(length)))
                    XCTAssertEqual(delta.ports[.usbC1]?.watts, -40)
                    var small = [UInt8](repeating: 0xCC, count: 7)
                    XCTAssertEqual(sn_probe_access_reply(context, ciphertext, ciphertext.count, &reply, &small, small.count, &length), -1)
                    XCTAssertEqual(length, 0); XCTAssertTrue(small.allSatisfy { $0 == 0 })
                }
            }
        }
    }
    func testDiagnosticsExportOnlyTypedStatusAndCounts() {
        var log = Diagnostics()
        log.record(.authenticationStatus, fields: [.authenticationStatus(AuthStatusSummary(action: .checkCredential, mode: .normal))])
        log.record(.candidateTelemetry, fields: [.count(.portPowerUpdates, 1)])
        let report = log.export(appVersion: "test", systemVersion: "test", services: [])
        XCTAssertTrue(report.contains("app would check an existing credential"))
        for value in ["a235050d000020c2", "watts=-40", "userId", "P512000000000000", "sessionKey"] {
            XCTAssertFalse(report.contains(value))
        }
    }

    @MainActor
    func testHardwareAccountFreeReportTwice() async throws {
        guard ProcessInfo.processInfo.environment["SOMNOIRE_HARDWARE_ACCOUNT_FREE_ACCESS"] == "1" else {
            throw XCTSkip("Use the explicit Somnoire Account-Free Access Check scheme.")
        }
        let suite = "org.somnoire.access-hardware.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let manager = BluetoothManager(preferences: preferences)
        defer {
            print(manager.diagnosticReport())
            manager.shutdown(); preferences.removePersistentDomain(forName: suite)
        }
        func wait(seconds: TimeInterval, until predicate: () -> Bool) async throws -> Bool {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while !predicate() && ProcessInfo.processInfo.systemUptime < end {
                try await Task.sleep(for: .milliseconds(100))
            }
            return predicate()
        }
        for attempt in 1...2 {
            manager.startScan()
            let found = try await wait(seconds: 15) {
                manager.devices.contains { $0.advertisement.supportsKeyExchangeProbe && manager.canConnect($0) }
            }
            guard found else { return XCTFail("No eligible nearby P512; \(manager.availability.rawValue)") }
            let candidates = manager.devices.filter { $0.advertisement.supportsKeyExchangeProbe && manager.canConnect($0) }
            guard candidates.count == 1 else { return XCTFail("Ambiguous bank selection; no request sent.") }
            manager.selectPowerBank(candidates[0].id)
            manager.startMonitoring(); manager.stopScan()
            manager.connectAndProbe(to: candidates[0].id, kind: .accountFreeAccess)
            let finished = try await wait(seconds: 70) { manager.probeResult != nil }
            XCTAssertTrue(finished)
            let result = try XCTUnwrap(manager.probeResult)
            let access = try XCTUnwrap(result.access)
            print("Access attempt \(attempt): \(result.outcome.label); auth=\(access.authentication.label); report issued=\(access.reportRequestIssued); report reply=\(access.reportReplyReceived); decoded packets=\(access.decodedPackets); port updates=\(access.portPowerUpdates)")
            if let delta = access.latestDelta, access.portPowerUpdates > 0 {
                for port in P512ProtocolPort.allCases {
                    if let watts = delta.ports[port]?.watts {
                        print("Local experiment only: protocol field \(port.rawValue) watts=\(watts). Physical mapping unverified.")
                    }
                }
            }
            // Experimental findings are allowed, but setup/decryption/transport errors
            // must not be reported as a successful access experiment.
            XCTAssertTrue(result.stage == .observing || result.outcome == .failed(.unknownAuthStatus) ||
                          result.outcome == .failed(.unsupportedAuthMode), result.outcome.label)
            let idle = try await wait(seconds: 5) { manager.connection.isIdle }
            XCTAssertTrue(idle)
            let resumed = try await wait(seconds: 3) { manager.isScanning }
            XCTAssertTrue(resumed, "Battery monitoring did not resume")
            manager.pauseMonitoring()
        }
    }
}

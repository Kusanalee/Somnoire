import XCTest
@testable import Somnoire

final class P512TelemetryTests: XCTestCase {
    @MainActor
    func testRememberedCredentialIsolationAndForget() {
        final class MemoryStore: BankCredentialStore {
            var values: [UUID: ProbeCredential] = [:]
            func load(bank: UUID) -> ProbeCredential? { values[bank]?.copy() }
            func save(_ credential: ProbeCredential, bank: UUID) -> Bool { values[bank] = credential.copy(); return values[bank] != nil }
            func forget(bank: UUID) -> Bool { values.removeValue(forKey: bank)?.clear(); return true }
        }
        let store = MemoryStore(), bank = UUID(), other = UUID()
        let credential = ProbeCredential(userID: "1234", serial: Data("P512000000000000".utf8))!
        XCTAssertTrue(store.save(credential, bank: bank))
        credential.clear()
        XCTAssertNotNil(store.load(bank: bank))
        XCTAssertNil(store.load(bank: other))
        XCTAssertTrue(store.forget(bank: bank))
        XCTAssertNil(store.load(bank: bank))
    }
    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    func testPaneDraftConflictRevertAndFeedback() {
        var draft = SettingsDraft<Int>()
        draft.sync(81); XCTAssertEqual(draft.value, 81); XCTAssertFalse(draft.dirty)
        draft.edit(85); XCTAssertEqual(draft.phase, .modified)
        draft.sync(90); XCTAssertEqual(draft.value, 85); XCTAssertEqual(draft.phase, .conflict)
        draft.revert(90); XCTAssertEqual(draft.value, 90); XCTAssertFalse(draft.dirty)
        XCTAssertEqual(paneFeedback(local: .modified, dirty: true, transaction: .applied), .modified)
        XCTAssertEqual(paneFeedback(local: .modified, dirty: true, transaction: .applying), .applying)
        XCTAssertEqual(paneFeedback(local: .clean, dirty: false, transaction: .applied).message, "Settings applied")
        XCTAssertEqual(paneFeedback(local: .modified, dirty: true, transaction: .partial), .partial)
    }

    private func integerField(_ number: UInt64, _ value: UInt64) -> Data {
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value, result: [UInt8] = []
            repeat { let byte = UInt8(value & 127); value >>= 7; result.append(byte | (value > 0 ? 128 : 0)) } while value > 0
            return result
        }
        return Data(varint(number << 3) + varint(value))
    }
    func testBatterySchemaSignedIntegersAndLimits() throws {
        var body = bytes("bd100000b942") // Health 92.5, independent synthetic float.
        body += integerField(102, UInt64(bitPattern: -12))
        body += integerField(1251, UInt64(UInt32.max))
        body += integerField(1275, 999); body += integerField(1274, 1000)
        let value = try P512TelemetryDecoder.decodePayload(body)
        XCTAssertEqual(value.health, 92.5); XCTAssertEqual(value.temperatureCelsius, -12)
        XCTAssertEqual(value.cycles, UInt32.max); XCTAssertEqual(value.energyInWh, 999); XCTAssertEqual(value.energyOutWh, 1000)
        for number in [UInt64(1251), 1275, 1274] {
            XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(integerField(number, UInt64(UInt32.max) + 1)))
            XCTAssertEqual(try P512TelemetryDecoder.decodePayload(integerField(number, 0)).merging(value).cycles, value.cycles)
        }
        for value in [Int64(Int32.min), Int64(Int32.max), 0] {
            XCTAssertEqual(try P512TelemetryDecoder.decodePayload(integerField(102, UInt64(bitPattern: value))).temperatureCelsius, Int32(value))
        }
        XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(integerField(102, 0x100000000)))
        XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(integerField(263, 1)))
        XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(body.dropLast()))
    }
    func testHealthIsolationAndBatterySnapshotAgesAndCounterDecrease() throws {
        let valid = try P512TelemetryDecoder.decodePayload(bytes("bd100000b942"))
        let invalid = try P512TelemetryDecoder.decodePayload(bytes("bd100000ca42c235050d000020c2"))
        XCTAssertEqual(invalid.rejectedHealth?.reason, .invalidHealth)
        XCTAssertEqual(invalid.ports[.usbC2]?.watts, -40)
        XCTAssertNil(valid.merging(invalid).health)
        XCTAssertEqual(invalid.merging(valid).health, 92.5)
        var info = BatteryInformation()
        let first = Date(timeIntervalSince1970: 100)
        info.receive(P512TelemetryDelta(cycles: 0, energyInWh: 2000, inputWatts: 0, outputWatts: 12), at: first)
        info.receive(valid, at: first.addingTimeInterval(3))
        XCTAssertEqual(info.samples[.cycles]?.value, 0)
        XCTAssertEqual(info.samples[.energyIn]?.reportedAt, first)
        XCTAssertEqual(info.power(.input, at: first.addingTimeInterval(4)), 0)
        XCTAssertNil(info.power(.output, at: first.addingTimeInterval(5)))
        info.receive(P512TelemetryDelta(energyInWh: 10), at: first.addingTimeInterval(6))
        XCTAssertEqual(info.samples[.energyIn]?.value, 10)
        info.disconnect(); XCTAssertNil(info.samples[.input]); XCTAssertNotNil(info.samples[.cycles])
        info.receive(invalid, at: first); XCTAssertNil(info.samples[.health]?.value)
        var diagnostics = Diagnostics()
        diagnostics.record(.batteryFields, fields: [.batteryFields([263, 1251, 102, 1275, 1274, 999])])
        XCTAssertEqual(diagnostics.events.first?.fields.first?.text, "fields=263,1251,102,1275,1274")
    }
    func testEnergyAndTemperatureUnits() {
        XCTAssertEqual(BatteryInformation.energy(999, unit: "Auto"), "999 Wh")
        XCTAssertEqual(BatteryInformation.energy(1000, unit: "Auto"), "1.000 kWh")
        XCTAssertEqual(BatteryInformation.energy(1, unit: "kWh"), "0.001 kWh")
        XCTAssertEqual(BatteryInformation.energy(1001, unit: "Wh"), "1001 Wh")
        XCTAssertEqual(BatteryInformation.temperature(0, unit: "°F"), "32.0 °F")
        XCTAssertEqual(BatteryInformation.temperature(-40, unit: "°C"), "-40.0 °C")
    }

    func testStructuralFailureDiagnostics() throws {
        let cases: [(String, TelemetryValidationSummary.Reason, Int?, Int?, Int)] = [
            ("1d00", .malformed, nil, 3, 0),
            ("1801", .wrongWireType, nil, 3, 0),
            ("1d0000c07f", .nonfinite, nil, 3, 0),
            ("c235020801", .wrongWireType, 856, 1, 3),
            ("c235050d0000807f", .nonfinite, 856, 1, 3),
            ("c235020d00", .malformed, 856, 1, 3),
            ("00", .malformed, nil, nil, 0)
        ]
        for (hex, reason, port, field, offset) in cases {
            XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(bytes(hex))) { error in
                guard let summary = error as? TelemetryValidationSummary else { return XCTFail("Missing typed summary") }
                XCTAssertEqual(summary.reason, reason)
                XCTAssertEqual(summary.port?.rawValue, port)
                XCTAssertEqual(summary.field, field)
                XCTAssertEqual(summary.offset, offset)
                if reason == .wrongWireType {
                    XCTAssertEqual(summary.expectedWire, 5)
                    XCTAssertEqual(summary.observedWire, 0)
                }
            }
        }
        XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(Data(repeating: 0, count: 4097))) {
            XCTAssertEqual(($0 as? TelemetryValidationSummary)?.reason, .sizeLimit)
        }
        // Valid C2 schema candidate retains its signed measurement.
        XCTAssertEqual(try P512TelemetryDecoder.decodePayload(bytes("c235050d000020c2")).ports[.usbC2]?.watts, -40)
    }

    func testOutOfRangeBatteryDoesNotDiscardValidPortsOrReuseOldPercentage() throws {
        for hex in ["b5100000ca42", "b510000080bf"] { // Synthetic 101 and -1.
            let delta = try P512TelemetryDecoder.decodePayload(bytes(hex + "c235050d000020c2"))
            XCTAssertNil(delta.batteryPercentage)
            XCTAssertEqual(delta.rejectedBattery?.reason, .invalidBattery)
            XCTAssertEqual(delta.rejectedBattery?.field, 262)
            XCTAssertEqual(delta.ports[.usbC2]?.watts, -40)
            let old = try P512TelemetryDecoder.decodePayload(bytes("b5100000b942"))
            let merged = old.merging(delta)
            XCTAssertNil(merged.batteryPercentage)
            XCTAssertNotNil(merged.rejectedBattery)
            XCTAssertNotNil(merged.merging(P512TelemetryDelta()).rejectedBattery)
            XCTAssertNil(merged.merging(old).rejectedBattery)
            XCTAssertEqual(merged.merging(old).batteryPercentage, 92.5)
        }
        for hex in ["b51000000000", "b5100000c842"] { // Inclusive 0 and 100.
            XCTAssertNotNil(try P512TelemetryDecoder.decodePayload(bytes(hex)).batteryPercentage)
        }
        let repeated = try P512TelemetryDecoder.decodePayload(bytes("b5100000ca42b5100000b942"))
        XCTAssertEqual(repeated.batteryPercentage, 92.5)
        XCTAssertNil(repeated.rejectedBattery)
        for suffix in ["c235020801", "c235050d0000807f", "c235020d00"] {
            XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(bytes("b5100000ca42" + suffix)))
        }
        XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(bytes("b5100000807f")))
    }

    func testIndependentSyntheticPayloadAndNonsequentialPortTags() throws {
        // Public synthetic values encoded independently with Python struct.pack('<f').
        let payload = bytes("b5100000b942d011021d00008a412500002042a2350f0d00004841150000a0411d0000203fc2350f0d000020c2150000a0411d000000c0aa350f0d00000000150000a0401d00000000b235051500009041ca350f0d0000a04315000000421d00002041")
        let value = try P512TelemetryDecoder.decodePayload(payload)
        XCTAssertEqual(value.batteryPercentage, 92.5)
        XCTAssertEqual(value.chargeDischargeState, 2)
        XCTAssertEqual(value.inputWatts, 17.25); XCTAssertEqual(value.outputWatts, 40)
        XCTAssertEqual(value.ports[.usbC1], P512PortMeasurement(watts: 12.5, volts: 20, amps: 0.625))
        XCTAssertEqual(value.ports[.usbC2], P512PortMeasurement(watts: -40, volts: 20, amps: -2))
        XCTAssertEqual(value.ports[.usbC3]?.watts, 0)
        XCTAssertEqual(value.ports[.usbC4]?.volts, 18); XCTAssertNil(value.ports[.usbC4]?.watts)
        XCTAssertEqual(value.ports[.pogo]?.watts, 320)
        XCTAssertEqual(value.ports[.usbC1]?.direction, .input)
        XCTAssertEqual(value.ports[.usbC2]?.direction, .output)
        XCTAssertEqual(value.ports[.usbC3]?.direction, .idle)
        XCTAssertNil(value.ports[.usbC4]?.direction)
        // Data may arrive as a slice with nonzero indices.
        XCTAssertEqual(try P512TelemetryDecoder.decodePayload((Data([1, 2]) + payload).dropFirst(2)), value)
    }
    func testMissingZeroAndIncrementalUpdatesRemainDistinct() throws {
        let empty = try P512TelemetryDecoder.decodePayload(Data())
        XCTAssertTrue(empty.ports.isEmpty); XCTAssertNil(empty.inputWatts)
        let initial = try P512TelemetryDecoder.decodePayload(bytes("a2350a0d000020c2150000a041c235050d00004841"))
        let update = try P512TelemetryDecoder.decodePayload(bytes("a235050d00000000"))
        let merged = initial.merging(update)
        XCTAssertEqual(merged.ports[.usbC1]?.watts, 0)
        XCTAssertEqual(merged.ports[.usbC1]?.volts, 20)
        XCTAssertEqual(merged.ports[.usbC2]?.watts, 12.5)
        XCTAssertNil(update.ports[.usbC2]); XCTAssertNil(update.ports[.usbC1]?.volts)
    }
    func testRepeatedMessagesMergeAndLastScalarWins() throws {
        let delta = try P512TelemetryDecoder.decodePayload(bytes("a235050d000020c2a23505150000a041a235050d0000a0c1"))
        XCTAssertEqual(delta.ports[.usbC1]?.watts, -20)
        XCTAssertEqual(delta.ports[.usbC1]?.volts, 20)
    }
    func testUnknownFieldsAreSkippedWithoutLosingKnownMeasurements() throws {
        let payload = bytes("087f0900000000000000000a036162630d0000803fa235070d000000002001")
        let delta = try P512TelemetryDecoder.decodePayload(payload)
        XCTAssertEqual(delta.ports[.usbC1]?.watts, 0)
        XCTAssertNil(delta.batteryPercentage)
        XCTAssertEqual(try P512TelemetryDecoder.decodePayload(bytes("0801")), P512TelemetryDelta())
    }
    func testTruncationAndMalformedWireDataAreRejected() {
        let complete = bytes("a235050d00004841")
        for length in 1..<complete.count {
            XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(complete.prefix(length)), "length=\(length)")
        }
        for hex in ["00", "0f", "08ffffffffffffffffffff02", "0affffffffffffffffff01", "a03501", "a235020801", "1a00"] {
            XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(bytes(hex)), hex)
        }
        XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(Data(repeating: 0, count: 4097)))
    }
    func testNonfiniteAndInvalidScalarValuesAreRejected() {
        for hex in ["1d0000c07f", "1d0000807f", "d011ffffffff1f"] {
            XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(bytes(hex)), hex)
        }
    }
}

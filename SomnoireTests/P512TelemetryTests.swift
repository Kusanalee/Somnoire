import XCTest
@testable import Somnoire

final class P512TelemetryTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
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
        for hex in ["1d0000c07f", "1d0000807f", "b5100000ca42", "b510000080bf", "d011ffffffff1f"] {
            XCTAssertThrowsError(try P512TelemetryDecoder.decodePayload(bytes(hex)), hex)
        }
    }
}

import Foundation

// App-derived research decoder for explicit diagnostic probes only. Production
// wattage UI remains gated on verified access and physical port mapping.
// Evidence: docs/P512-Protocol.md. No generated or proprietary app code is bundled.
enum P512ProtocolPort: Int, CaseIterable {
    case usbC1 = 852, usbC2 = 856, usbC3 = 853, usbC4 = 854, pogo = 857
}

struct P512PortMeasurement: Equatable {
    var watts: Float?
    var volts: Float?
    var amps: Float?

    enum Direction { case input, output, idle }
    // Convention established in the app; still requires comparison with this bank.
    var direction: Direction? {
        watts.map { $0 > 0 ? .input : $0 < 0 ? .output : .idle }
    }
    func merging(_ update: Self) -> Self {
        Self(watts: update.watts ?? watts, volts: update.volts ?? volts, amps: update.amps ?? amps)
    }
}

struct P512TelemetryDelta: Equatable {
    var batteryPercentage: Float?
    var chargeDischargeState: UInt32?
    var inputWatts: Float?
    var outputWatts: Float?
    var ports: [P512ProtocolPort: P512PortMeasurement] = [:]

    // Values alone are merged. A future live session must track freshness separately
    // for each reported measurement; omitted fields must not refresh retained values.
    func merging(_ update: Self) -> Self {
        var result = self
        result.batteryPercentage = update.batteryPercentage ?? batteryPercentage
        result.chargeDischargeState = update.chargeDischargeState ?? chargeDischargeState
        result.inputWatts = update.inputWatts ?? inputWatts
        result.outputWatts = update.outputWatts ?? outputWatts
        for (port, value) in update.ports {
            result.ports[port] = result.ports[port]?.merging(value) ?? value
        }
        return result
    }
}

enum P512TelemetryError: Error, Equatable {
    case sizeLimit, malformed, wrongWireType, invalidValue
}

enum P512TelemetryDecoder {
    // Accepts a decrypted, de-framed protobuf payload, never an encrypted envelope.
    static func decodePayload(_ payload: Data) throws -> P512TelemetryDelta {
        guard payload.count <= 4096 else { throw P512TelemetryError.sizeLimit }
        var cursor = Cursor(bytes: Array(payload)), result = P512TelemetryDelta()
        while let (field, wire) = try cursor.nextField() {
            if let port = P512ProtocolPort(rawValue: field) {
                guard wire == 2 else { throw P512TelemetryError.wrongWireType }
                let value = try decodePort(cursor.lengthDelimited())
                result.ports[port] = result.ports[port]?.merging(value) ?? value
            } else {
                switch field {
                case 3: result.inputWatts = try cursor.float(wire: wire)
                case 4: result.outputWatts = try cursor.float(wire: wire)
                case 262:
                    let value = try cursor.float(wire: wire)
                    guard (0...100).contains(value) else { throw P512TelemetryError.invalidValue }
                    result.batteryPercentage = value
                case 282:
                    guard wire == 0 else { throw P512TelemetryError.wrongWireType }
                    let value = try cursor.varint()
                    guard value <= UInt32.max else { throw P512TelemetryError.invalidValue }
                    result.chargeDischargeState = UInt32(value)
                default: try cursor.skip(wire: wire)
                }
            }
        }
        return result
    }

    private static func decodePort(_ bytes: [UInt8]) throws -> P512PortMeasurement {
        var cursor = Cursor(bytes: bytes), result = P512PortMeasurement()
        while let (field, wire) = try cursor.nextField() {
            switch field {
            case 1: result.watts = try cursor.float(wire: wire)
            case 2: result.volts = try cursor.float(wire: wire)
            case 3: result.amps = try cursor.float(wire: wire)
            default: try cursor.skip(wire: wire)
            }
        }
        return result
    }

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0
        var remaining: Int { bytes.count - index }

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for byteIndex in 0..<10 {
                guard remaining > 0 else { throw P512TelemetryError.malformed }
                let byte = bytes[index]; index += 1
                guard byteIndex != 9 || byte <= 1 else { throw P512TelemetryError.malformed }
                value |= UInt64(byte & 0x7F) << (byteIndex * 7)
                if byte & 0x80 == 0 { return value }
            }
            throw P512TelemetryError.malformed
        }
        mutating func nextField() throws -> (Int, UInt8)? {
            guard remaining > 0 else { return nil }
            let key = try varint(), field = key >> 3
            guard field > 0, field <= 0x1FFF_FFFF else { throw P512TelemetryError.malformed }
            return (Int(field), UInt8(key & 7))
        }
        mutating func float(wire: UInt8) throws -> Float {
            guard wire == 5 else { throw P512TelemetryError.wrongWireType }
            guard remaining >= 4 else { throw P512TelemetryError.malformed }
            let bits = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 |
                UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
            index += 4
            let value = Float(bitPattern: bits)
            guard value.isFinite else { throw P512TelemetryError.invalidValue }
            return value
        }
        mutating func lengthDelimited() throws -> [UInt8] {
            let length = try varint()
            guard length <= UInt64(remaining) else { throw P512TelemetryError.malformed }
            let end = index + Int(length)
            defer { index = end }
            return Array(bytes[index..<end])
        }
        mutating func skip(wire: UInt8) throws {
            let length: Int
            switch wire {
            case 0: _ = try varint(); return
            case 1: length = 8
            case 2: _ = try lengthDelimited(); return
            case 5: length = 4
            default: throw P512TelemetryError.malformed
            }
            guard remaining >= length else { throw P512TelemetryError.malformed }
            index += length
        }
    }
}

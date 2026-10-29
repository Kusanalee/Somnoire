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
    var timezoneOffset: Int32?
    var timezoneID: String?
    var timezoneAutomatic: Bool?
    var batteryPercentage: Float?
    var rejectedBattery: TelemetryValidationSummary?
    var screen: [ScreenField: UInt32] = [:]
    var healthyMode: UInt32?
    var chargeCeiling: UInt32?
    var dischargeFloor: UInt32?
    var health: Float?
    var rejectedHealth: TelemetryValidationSummary?
    var cycles: UInt32?
    var temperatureCelsius: Int32?
    var energyInWh: UInt32?
    var energyOutWh: UInt32?
    var chargeDischargeState: UInt32?
    var inputWatts: Float?
    var outputWatts: Float?
    var ports: [P512ProtocolPort: P512PortMeasurement] = [:]

    // Values alone are merged. A future live session must track freshness separately
    // for each reported measurement; omitted fields must not refresh retained values.
    func merging(_ update: Self) -> Self {
        var result = self
        if let rejected = update.rejectedBattery {
            result.batteryPercentage = nil
            result.rejectedBattery = rejected
        } else if let percentage = update.batteryPercentage {
            result.batteryPercentage = percentage
            result.rejectedBattery = nil
        }
        if let rejected = update.rejectedHealth {
            result.health = nil; result.rejectedHealth = rejected
        } else if let health = update.health {
            result.health = health; result.rejectedHealth = nil
        }
        result.timezoneOffset = update.timezoneOffset ?? timezoneOffset
        result.timezoneID = update.timezoneID ?? timezoneID
        result.timezoneAutomatic = update.timezoneAutomatic ?? timezoneAutomatic
        result.screen.merge(update.screen) { _, new in new }
        result.healthyMode = update.healthyMode ?? healthyMode
        result.chargeCeiling = update.chargeCeiling ?? chargeCeiling
        result.dischargeFloor = update.dischargeFloor ?? dischargeFloor
        result.cycles = update.cycles ?? cycles
        result.temperatureCelsius = update.temperatureCelsius ?? temperatureCelsius
        result.energyInWh = update.energyInWh ?? energyInWh
        result.energyOutWh = update.energyOutWh ?? energyOutWh
        result.chargeDischargeState = update.chargeDischargeState ?? chargeDischargeState
        result.inputWatts = update.inputWatts ?? inputWatts
        result.outputWatts = update.outputWatts ?? outputWatts
        for (port, value) in update.ports {
            result.ports[port] = result.ports[port]?.merging(value) ?? value
        }
        return result
    }
}

enum P512TelemetryError: String, Error, Equatable {
    case sizeLimit, malformed, wrongWireType, invalidValue, nonfinite, invalidBattery, invalidHealth
}

struct TelemetryValidationSummary: Error, Equatable {
    typealias Reason = P512TelemetryError
    let reason: Reason
    let port: P512ProtocolPort?
    let field: Int?
    let offset: Int
    let expectedWire: UInt8?
    let observedWire: UInt8?
    var label: String {
        let location = port.map { "port field \($0.rawValue)" } ?? "top-level"
        return "reason=\(reason.rawValue) · location=\(location) · field=\(field.map(String.init) ?? "unknown") · byte offset=\(offset)" +
            (expectedWire.map { " · expected wire=\($0)" } ?? "") +
            (observedWire.map { " · observed wire=\($0)" } ?? "")
    }
}

enum P512TelemetryDecoder {
    // Accepts a decrypted, de-framed protobuf payload, never an encrypted envelope.
    static func decodePayload(_ payload: Data) throws -> P512TelemetryDelta {
        guard payload.count <= 4096 else { throw TelemetryValidationSummary(reason: .sizeLimit, port: nil, field: nil, offset: 0, expectedWire: nil, observedWire: nil) }
        var cursor = Cursor(bytes: Array(payload)), result = P512TelemetryDelta()
        do {
            while let (field, wire) = try cursor.nextField() {
                if let port = P512ProtocolPort(rawValue: field) {
                    guard wire == 2 else { throw P512TelemetryError.wrongWireType }
                    let bytes = try cursor.lengthDelimited()
                    let value = try decodePort(bytes, port: port, baseOffset: cursor.index - bytes.count)
                    result.ports[port] = result.ports[port]?.merging(value) ?? value
                } else {
                    switch field {
                    case 133:
                        guard wire == 0 else { throw P512TelemetryError.wrongWireType }
                        let value = try cursor.varint()
                        guard value <= UInt64(Int32.max) || value >= UInt64.max - UInt64(Int32.max) else { throw P512TelemetryError.invalidValue }
                        result.timezoneOffset = Int32(truncatingIfNeeded: value)
                    case 134: result.timezoneID = try cursor.string(wire: wire)
                    case 135:
                        let value = try cursor.uint32(wire: wire)
                        guard value <= 1 else { throw P512TelemetryError.invalidValue }
                        result.timezoneAutomatic = value == 1
                    case 3: result.inputWatts = try cursor.float(wire: wire)
                    case 4: result.outputWatts = try cursor.float(wire: wire)
                    case 262:
                        let value = try cursor.float(wire: wire)
                        // Official PB501 consumer clamps this scalar for display. Keep
                        // valid port fields, but never clamp or expose an invalid SOC.
                        if (0...100).contains(value) {
                            result.batteryPercentage = value
                            result.rejectedBattery = nil
                        } else {
                            result.batteryPercentage = nil
                            result.rejectedBattery = cursor.summary(.invalidBattery, port: nil)
                        }
                    case 848: result.healthyMode = try cursor.uint32(wire: wire)
                    case 270: result.chargeCeiling = try cursor.uint32(wire: wire)
                    case 271: result.dischargeFloor = try cursor.uint32(wire: wire)
                    case 263:
                        let value = try cursor.float(wire: wire)
                        if (0...100).contains(value) {
                            result.health = value; result.rejectedHealth = nil
                        } else {
                            result.health = nil; result.rejectedHealth = cursor.summary(.invalidHealth, port: nil)
                        }
                    case 102:
                        guard wire == 0 else { throw P512TelemetryError.wrongWireType }
                        let value = try cursor.varint()
                        guard value <= UInt32.max || value >= UInt64.max - UInt64(Int32.max) else { throw P512TelemetryError.invalidValue }
                        result.temperatureCelsius = Int32(bitPattern: UInt32(truncatingIfNeeded: value))
                    case 1251: result.cycles = try cursor.uint32(wire: wire)
                    case 1275: result.energyInWh = try cursor.uint32(wire: wire)
                    case 1274: result.energyOutWh = try cursor.uint32(wire: wire)
                    case 282:
                        guard wire == 0 else { throw P512TelemetryError.wrongWireType }
                        let value = try cursor.varint()
                        guard value <= UInt32.max else { throw P512TelemetryError.invalidValue }
                        result.chargeDischargeState = UInt32(value)
                    default:
                        if let setting = ScreenField(rawValue: field) { result.screen[setting] = try cursor.uint32(wire: wire) }
                        else { try cursor.skip(wire: wire) }
                    }
                }
            }
        } catch let summary as TelemetryValidationSummary { throw summary }
        catch let error as P512TelemetryError { throw cursor.summary(error, port: nil) }
        return result
    }

    private static func decodePort(_ bytes: [UInt8], port: P512ProtocolPort, baseOffset: Int) throws -> P512PortMeasurement {
        var cursor = Cursor(bytes: bytes), result = P512PortMeasurement()
        do {
            while let (field, wire) = try cursor.nextField() {
                switch field {
                case 1: result.watts = try cursor.float(wire: wire)
                case 2: result.volts = try cursor.float(wire: wire)
                case 3: result.amps = try cursor.float(wire: wire)
                default: try cursor.skip(wire: wire)
                }
            }
        } catch let error as P512TelemetryError { throw cursor.summary(error, port: port, baseOffset: baseOffset) }
        return result
    }

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0
        var field: Int?
        var wire: UInt8?
        var fieldOffset = 0
        func summary(_ error: P512TelemetryError, port: P512ProtocolPort?, baseOffset: Int = 0) -> TelemetryValidationSummary {
            let recognized = port == nil ? [3, 4, 262, 263, 848, 270, 271, 102, 1251, 1275, 1274, 282, 852, 856, 853, 854, 857] : [1, 2, 3]
            let known = field.flatMap { recognized.contains($0) ? $0 : nil }
            let expected: UInt8? = known.map { port != nil ? 5 : P512ProtocolPort(rawValue: $0) != nil ? 2 : [282, 848, 270, 271, 102, 1251, 1275, 1274].contains($0) ? 0 : 5 }
            return TelemetryValidationSummary(reason: error, port: port,
                field: known, offset: baseOffset + fieldOffset, expectedWire: expected, observedWire: wire)
        }
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
            fieldOffset = index; field = nil; wire = nil
            let key = try varint(), field = key >> 3
            self.field = Int(exactly: field); wire = UInt8(key & 7)
            guard field > 0, field <= 0x1FFF_FFFF else { throw P512TelemetryError.malformed }
            return (Int(field), UInt8(key & 7))
        }
        mutating func string(wire: UInt8) throws -> String {
            guard wire == 2 else { throw P512TelemetryError.wrongWireType }
            let bytes = try lengthDelimited()
            guard bytes.count <= 128, let value = String(bytes: bytes, encoding: .utf8) else { throw P512TelemetryError.invalidValue }
            return value
        }
        mutating func uint32(wire: UInt8) throws -> UInt32 {
            guard wire == 0 else { throw P512TelemetryError.wrongWireType }
            let value = try varint()
            guard value <= UInt32.max else { throw P512TelemetryError.invalidValue }
            return UInt32(value)
        }
        mutating func float(wire: UInt8) throws -> Float {
            guard wire == 5 else { throw P512TelemetryError.wrongWireType }
            guard remaining >= 4 else { throw P512TelemetryError.malformed }
            let bits = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 |
                UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
            index += 4
            let value = Float(bitPattern: bits)
            guard value.isFinite else { throw P512TelemetryError.nonfinite }
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

// In-memory per-field snapshots. Power is live; battery details retain their own age.
struct BatteryInformation {
    enum Metric: String, CaseIterable {
        case input, output, health, cycles, temperature, energyIn, energyOut
        var label: String {
            switch self {
            case .input: return "In"
            case .output: return "Out"
            case .health: return "Health"
            case .cycles: return "Cycles"
            case .temperature: return "Temperature"
            case .energyIn: return "Total energy in"
            case .energyOut: return "Total energy out"
            }
        }
    }
    struct Sample { let value: Double?; let reportedAt: Date }
    private(set) var samples: [Metric: Sample] = [:]
    mutating func receive(_ delta: P512TelemetryDelta, at date: Date) {
        let values: [(Metric, Double?)] = [(.input, delta.inputWatts.map(Double.init)), (.output, delta.outputWatts.map(Double.init)),
            (.health, delta.health.map(Double.init)), (.cycles, delta.cycles.map(Double.init)),
            (.temperature, delta.temperatureCelsius.map(Double.init)), (.energyIn, delta.energyInWh.map(Double.init)), (.energyOut, delta.energyOutWh.map(Double.init))]
        for (metric, value) in values { if let value { samples[metric] = Sample(value: value, reportedAt: date) } }
        if delta.rejectedHealth != nil { samples[.health] = Sample(value: nil, reportedAt: date) }
    }
    mutating func disconnect() { samples[.input] = nil; samples[.output] = nil }
    func power(_ metric: Metric, at date: Date) -> Double? {
        guard let sample = samples[metric], date.timeIntervalSince(sample.reportedAt) < 5 else { return nil }
        return sample.value
    }
    static func energy(_ wh: Double, unit: String) -> String {
        if unit == "Wh" || (unit == "Auto" && wh < 1000) { return String(format: "%.0f Wh", wh) }
        return String(format: "%.3f kWh", wh / 1000)
    }
    static func temperature(_ celsius: Double, unit: String) -> String {
        String(format: "%.1f %@", unit == "°F" ? celsius * 9 / 5 + 32 : celsius, unit)
    }
}

struct HealthySettings: Equatable {
    var timezone = ClockReadback()
    var screen: [ScreenField: UInt32] = [:]
    var mode: UInt32?
    var ceiling: UInt32?
    var floor: UInt32?
    var valid: Bool { (mode == 1 || mode == 2) && ceiling.map { (80...100).contains($0) } == true && floor.map { $0 <= 20 } == true }
    mutating func receive(_ delta: P512TelemetryDelta) {
        timezone.receive(delta)
        screen.merge(delta.screen) { _, new in new }
        mode = delta.healthyMode ?? mode; ceiling = delta.chargeCeiling ?? ceiling; floor = delta.dischargeFloor ?? floor
    }
    func matches(_ change: HealthyChange) -> Bool {
        (change.clock.map { timezone.timezoneOffset == $0.offset && timezone.timezoneID == $0.zone && timezone.timezoneAutomatic == true } ?? true) && change.screen.allSatisfy { screen[$0.key] == $0.value } && (change.mode == nil || change.mode == mode) && (change.ceiling == nil || change.ceiling == ceiling) && (change.floor == nil || change.floor == floor)
    }
}
struct HealthyChange {
    var clock: ClockSyncRequest?
    var screen: [ScreenField: UInt32] = [:]
    var mode: UInt32?
    var ceiling: UInt32?
    var floor: UInt32?
    var valid: Bool {
        if let clock { return clock.valid && screen.isEmpty && mode == nil && ceiling == nil && floor == nil }
        if !screen.isEmpty { return screen.count == 1 && mode == nil && ceiling == nil && floor == nil && screen.allSatisfy { $0.key.accepts($0.value) } }
        return
        (mode == nil || mode == 1 || mode == 2) && (ceiling == nil || (80...100).contains(ceiling!)) &&
        (floor == nil || floor! <= 20) && (mode != nil || ceiling != nil || floor != nil)
    }
}

enum ScreenField: Int, CaseIterable {
    case duration = 18, brightness = 5
    case clockEnabled = 825, clockDuration = 826, clockFormat = 827, chargingClockDuration = 1259
    var writeField: UInt32 {
        switch self {
        case .duration: return 12
        case .brightness: return 14
        case .clockEnabled: return 304
        case .clockDuration: return 305
        case .clockFormat: return 306
        case .chargingClockDuration: return 554
        }
    }
    var label: String {
        switch self {
        case .duration: return "Information display duration"
        case .brightness: return "Brightness"
        case .clockEnabled: return "Clock"
        case .clockDuration: return "Clock duration on battery"
        case .clockFormat: return "Clock format"
        case .chargingClockDuration: return "Clock duration while charging"
        }
    }
    static let durations: [UInt32] = [30,60,300,600,1800,3600]
    func accepts(_ value: UInt32) -> Bool {
        switch self {
        case .brightness: return value <= 100
        case .clockEnabled, .clockFormat: return value == 1 || value == 2
        case .chargingClockDuration: return value == UInt32.max || Self.durations.contains(value)
        default: return Self.durations.contains(value)
        }
    }
    func text(_ value: UInt32) -> String {
        switch self {
        case .brightness: return "\(value)%"
        case .clockEnabled: return value == 1 ? "Enabled" : "Disabled"
        case .clockFormat: return value == 1 ? "12-hour" : "24-hour"
        default: return value == UInt32.max ? "Never" : value < 60 ? "\(value) seconds" : "\(value/60) minutes"
        }
    }
}

enum SettingsPane: Int, Hashable { case charging, screen }
enum PanePhase: Equatable {
    case clean, modified, applying, applied, conflict, partial, notConfirmed
    var message: String {
        switch self {
        case .clean: return ""
        case .modified: return "Unapplied changes"
        case .applying: return "Applying settings…"
        case .applied: return "Settings applied"
        case .conflict: return "Bank settings changed. Revert to review current values."
        case .partial: return "Some settings applied. Reconnect and review."
        case .notConfirmed: return "Not confirmed. Reconnect and review."
        }
    }
}
struct SettingsDraft<Value: Equatable> {
    var baseline: Value?
    var value: Value?
    var phase: PanePhase = .clean
    var dirty: Bool { value != baseline }
    mutating func sync(_ reported: Value) {
        if dirty { if baseline != reported { phase = .conflict } }
        else { baseline = reported; value = reported }
    }
    mutating func edit(_ value: Value) { self.value = value; phase = dirty ? .modified : .clean }
    mutating func revert(_ reported: Value) { baseline = reported; value = reported; phase = .clean }
}

func paneFeedback(local: PanePhase, dirty: Bool, transaction: PanePhase?) -> PanePhase {
    if let transaction, transaction == .applying || transaction == .partial || transaction == .notConfirmed { return transaction }
    return dirty ? local : transaction ?? local
}

// The installed Android helper encodes whole-hour offsets as hours * 100.
// Fractional offsets are refused until their P512 representation is established.
struct ClockSyncRequest: Equatable {
    let utc: UInt32
    let offset: Int32
    let zone: String
    var valid: Bool { (-1200...1400).contains(offset) && offset % 100 == 0 && !zone.isEmpty && zone.utf8.count <= 128 && zone.utf8.allSatisfy { (33...126).contains($0) } }
    static func make(date: Date, timezone: TimeZone) -> Self? {
        let seconds = timezone.secondsFromGMT(for: date)
        guard seconds % 3600 == 0, let utc = UInt32(exactly: floor(date.timeIntervalSince1970)) else { return nil }
        let request = Self(utc: utc, offset: Int32(seconds / 3600 * 100), zone: timezone.identifier)
        return request.valid ? request : nil
    }
}

struct ClockReadback: Equatable {
    var timezoneOffset: Int32?
    var timezoneID: String?
    var timezoneAutomatic: Bool?
    mutating func receive(_ delta: P512TelemetryDelta) {
        timezoneOffset = delta.timezoneOffset ?? timezoneOffset
        timezoneID = delta.timezoneID ?? timezoneID
        timezoneAutomatic = delta.timezoneAutomatic ?? timezoneAutomatic
    }
    func outcome(for request: ClockSyncRequest) -> ClockSyncOutcome {
        let present = (timezoneOffset != nil ? 1 : 0) | (timezoneID != nil ? 2 : 0) | (timezoneAutomatic != nil ? 4 : 0)
        let matches = (timezoneOffset == request.offset ? 1 : 0) | (timezoneID == request.zone ? 2 : 0) | (timezoneAutomatic == true ? 4 : 0)
        return present == 7 && matches == 7 ? .confirmed : .readback(present: present, matches: matches)
    }
}
enum ClockSyncOutcome: Equatable {
    case refused, sent, transportFailure, cancelled, confirmed
    case readback(present: Int, matches: Int)
    var label: String {
        switch self {
        case .refused: return "Clock request refused"
        case .sent: return "Clock write completed; device acceptance unverified"
        case .transportFailure: return "Clock transport failed"
        case .cancelled: return "Clock sync cancelled"
        case .confirmed: return "Timezone readback confirmed; physical clock comparison required"
        case .readback(let present, let matches): return "Clock readback unconfirmed; presence=\(present), matching=\(matches)"
        }
    }
}

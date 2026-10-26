import Foundation

// Snapshots contain no CoreBluetooth objects. Protocol decoding belongs downstream
// of the notification callback in a later phase, after hardware verification.
enum BluetoothAvailability: String {
    case notStarted = "Bluetooth starts when you click Scan."
    case unknown = "Waiting for Bluetooth…"
    case resetting = "Bluetooth is resetting."
    case unsupported = "Bluetooth LE is unavailable on this Mac."
    case denied = "Bluetooth access denied. Enable Somnoire in System Settings → Privacy & Security → Bluetooth."
    case restricted = "Bluetooth access is restricted by system policy."
    case poweredOff = "Bluetooth is off. Enable it in System Settings."
    case ready = "Bluetooth ready."
}

enum ConnectionState: Equatable {
    case idle, connecting(UUID), connected(UUID), disconnecting(UUID)
    var identifier: UUID? {
        switch self {
        case .idle: nil
        case .connecting(let id), .connected(let id), .disconnecting(let id): id
        }
    }
    var isIdle: Bool { self == .idle }
    var isConnected: Bool { if case .connected = self { true } else { false } }
    var label: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected · GATT inspection"
        case .disconnecting: "Disconnecting…"
        }
    }
}

// Small, synchronous lifecycle helper shared by the transport and hardware-free tests.
struct ConnectionLifecycle {
    private(set) var state: ConnectionState = .idle
    mutating func begin(_ id: UUID) -> Bool {
        guard state.isIdle else { return false }
        state = .connecting(id)
        return true
    }
    mutating func established(_ id: UUID) -> Bool {
        guard state == .connecting(id) else { return false }
        state = .connected(id)
        return true
    }
    mutating func cancel() -> UUID? {
        guard let id = state.identifier, state != .disconnecting(id) else { return nil }
        state = .disconnecting(id)
        return id
    }
    mutating func finished(_ id: UUID) -> Bool {
        guard state.identifier == id else { return false }
        state = .idle
        return true
    }
    mutating func reset() { state = .idle }
}

struct AdvertisementSnapshot: Equatable {
    var localName: String?
    var manufacturerData: Data?
    var serviceUUIDs: [String] = []
    var overflowServiceUUIDs: [String] = []
    var solicitedServiceUUIDs: [String] = []
    var serviceData: [String: Data] = [:]
    var isConnectable: Bool?
    var transmitPower: Int?

    /// Observed profile only. Serial bytes are checked, never extracted for authentication.
    var matchesObservedRapidProProfile: Bool {
        guard let data = manufacturerData, data.count >= 25 else { return false }
        let b = Array(data)
        return manufacturerID == 0xB5B5 && b[2] == 0x13 &&
            Array(b[3..<7]) == Array("P512".utf8) &&
            b[3..<19].allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) } &&
            (b[24] >> 3) & 7 == 7
    }

    var manufacturerID: UInt16? {
        guard let data = manufacturerData, data.count >= 2 else { return nil }
        let bytes = Array(data.prefix(2))
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }
    mutating func merge(_ update: Self) {
        if let value = update.localName, !value.isEmpty { localName = value }
        if let value = update.manufacturerData { manufacturerData = value }
        serviceUUIDs = Array(Set(serviceUUIDs + update.serviceUUIDs)).sorted()
        overflowServiceUUIDs = Array(Set(overflowServiceUUIDs + update.overflowServiceUUIDs)).sorted()
        solicitedServiceUUIDs = Array(Set(solicitedServiceUUIDs + update.solicitedServiceUUIDs)).sorted()
        serviceData.merge(update.serviceData) { _, new in new }
        if let value = update.isConnectable { isConnectable = value }
        if let value = update.transmitPower { transmitPower = value }
    }
    func ecoFlowHints(fallbackName: String?) -> [String] {
        var hints: [String] = []
        if let id = manufacturerID, id == 0xB5B5 || id == 0xA4A8 {
            hints.append(String(format: "Reported EcoFlow manufacturer marker 0x%04X", id))
        }
        let services = serviceUUIDs + overflowServiceUUIDs + solicitedServiceUUIDs + Array(serviceData.keys)
        let known = ["00000005-0000-1000-8000-00805F9B34FB", "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"]
        if services.contains(where: { known.contains(canonicalUUID($0)) }) {
            hints.append("Service reported in EcoFlow research (also used by other devices)")
        }
        let name = localName ?? fallbackName ?? ""
        if name.uppercased().hasPrefix("EF-") || name.localizedCaseInsensitiveContains("EcoFlow") || name.localizedCaseInsensitiveContains("RAPID") {
            hints.append("Name resembles an EcoFlow product")
        }
        return hints
    }
}

enum AdvertisedBatteryOutcome: String {
    case decoded = "candidate decoded"
    case unsupportedProfile = "unsupported or incomplete profile"
    case invalidValue = "candidate outside percentage range"
}

struct AdvertisedBatteryReading: Equatable {
    // Observed P512 profile matched the physical screen at 100% and 96%.
    // Evidence and limitations are recorded in docs/Phase2A.md; not a universal layout.
    static let hardwareValidated = true
    let percentage: Int
    let observedAt: Date
    var label: String { "Battery \(percentage)% · advertised" }
    var symbolName: String {
        switch percentage {
        case ..<15: "battery.0percent"
        case ..<40: "battery.25percent"
        case ..<65: "battery.50percent"
        case ..<90: "battery.75percent"
        default: "battery.100percent"
        }
    }

    static func decode(_ advertisement: AdvertisementSnapshot, observedAt: Date) -> Self? {
        guard advertisement.matchesObservedRapidProProfile,
              let data = advertisement.manufacturerData else { return nil }
        // CoreBluetooth includes the two manufacturer-ID bytes. No status-bit masking.
        let candidate = Int(data[data.startIndex + 19])
        guard (0...100).contains(candidate) else { return nil }
        return Self(percentage: candidate, observedAt: observedAt)
    }
}

func canonicalUUID(_ value: String) -> String {
    let upper = value.uppercased()
    if upper.count == 4 { return "0000\(upper)-0000-1000-8000-00805F9B34FB" }
    if upper.count == 8 { return "\(upper)-0000-1000-8000-00805F9B34FB" }
    return upper
}

struct DiscoveredDevice: Identifiable {
    let id: UUID
    var peripheralName: String?
    var rssi: Int?
    var advertisement: AdvertisementSnapshot
    private(set) var advertisedBattery: AdvertisedBatteryReading?
    var name: String { advertisement.localName ?? peripheralName ?? "Unnamed device" }
    var hints: [String] { advertisement.ecoFlowHints(fallbackName: peripheralName) }
    func visibleBatteryReading(hardwareValidated: Bool = AdvertisedBatteryReading.hardwareValidated) -> AdvertisedBatteryReading? {
        hardwareValidated ? advertisedBattery : nil
    }
    @discardableResult
    mutating func updateAdvertisement(_ update: AdvertisementSnapshot, observedAt: Date) -> AdvertisedBatteryOutcome? {
        advertisement.merge(update)
        // A name/RSSI-only callback must not refresh a retained sample's age.
        guard update.manufacturerData != nil else { return nil }
        advertisedBattery = AdvertisedBatteryReading.decode(update, observedAt: observedAt)
        if advertisedBattery != nil { return .decoded }
        return update.matchesObservedRapidProProfile ? .invalidValue : .unsupportedProfile
    }
    static func validRSSI(_ value: Int) -> Int? { (-127 ... 20).contains(value) ? value : nil }
}

enum DiscoveryProgress: Equatable {
    case notStarted, discovering, complete, partial, failed
    var label: String {
        switch self {
        case .notStarted: "Connect to inspect GATT."
        case .discovering: "Discovering services and characteristics…"
        case .complete: "GATT discovery complete."
        case .partial: "GATT discovery incomplete. See diagnostics."
        case .failed: "Service discovery failed. See diagnostics."
        }
    }
}

enum SubscriptionState: String {
    case off = "Not subscribed", enabling = "Subscribing…", on = "Subscribed", disabling = "Unsubscribing…", failed = "Subscription failed"
    var isPending: Bool { self == .enabling || self == .disabling }
}

struct GATTCharacteristic: Identifiable {
    let id: UUID
    let uuid: String
    let properties: UInt
    var subscription: SubscriptionState = .off
    var payloadHex: String?
    var payloadByteCount = 0
    var payloadTruncated = false
    var supportsSubscription: Bool { properties & (0x10 | 0x20 | 0x100 | 0x200) != 0 }
    var needsEncryption: Bool { properties & (0x100 | 0x200) != 0 }
    var propertyLabels: [String] { Self.labels(for: properties) }
    static func labels(for raw: UInt) -> [String] {
        let flags: [(UInt, String)] = [
            (1, "broadcast"), (2, "read"), (4, "write without response"), (8, "write"),
            (16, "notify"), (32, "indicate"), (64, "authenticated signed writes"),
            (128, "extended properties"), (256, "notify requires encryption"), (512, "indicate requires encryption")
        ]
        var names = flags.filter { raw & $0.0 != 0 }.map(\.1)
        let unknown = raw & ~UInt(0x3FF)
        if unknown != 0 { names.append(String(format: "unknown 0x%lX", unknown)) }
        return names.isEmpty ? ["none"] : names
    }
}

struct GATTService: Identifiable {
    let id: UUID
    let uuid: String
    let isPrimary: Bool
    var characteristics: [GATTCharacteristic] = []
    var discoveryFailed = false
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

struct PayloadPreview: Equatable {
    let hex: String
    let byteCount: Int
    let truncated: Bool
    init(_ data: Data) {
        hex = Data(data.prefix(Diagnostics.payloadLimit)).hex
        byteCount = data.count
        truncated = data.count > Diagnostics.payloadLimit
    }
}

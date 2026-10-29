import Foundation

// No free-form names, advertisements, error descriptions, or packet bodies enter
// this log. Export is built from typed fields, never by redacting rendered text.
enum DiagnosticKind: String {
    case clockSync = "Clock sync diagnostic"
    case monitoringStarted = "Automatic monitoring enabled", monitoringPaused = "Automatic monitoring paused", targetSelected = "Power bank selected"
    case advertisedBattery = "Advertisement battery decoding"
    case unrelatedStatus = "Valid unrelated encrypted packet discarded"
    case sessionPacket = "Validated encrypted packet header"
    case authenticationStatus = "App-derived authentication status"
    case batteryFields = "Battery information fields present"
    case candidateTelemetry = "Candidate telemetry body decoded"
    case telemetryValueUnavailable = "Telemetry measurement unavailable"
    case telemetryValidation = "Telemetry payload validation"
    case packetValidation = "Packet structure validation"
    case probeRequested = "Probe requested"
    case probeStarted = "Probe started", probeStageChanged = "Probe stage", probeFinished = "Probe finished"
    case bluetooth = "Bluetooth state", scanStarted = "Scan started", scanStopped = "Scan stopped"
    case discovered = "Peripheral discovered", advertisement = "Advertisement updated"
    case connecting = "Connecting", connected = "Connected", disconnecting = "Disconnect requested"
    case disconnected = "Disconnected", connectionFailed = "Connection failed", connectionTimeout = "Connection timed out"
    case services = "Services discovered", service = "Service", characteristic = "Characteristic"
    case discoveryFailed = "GATT discovery error", discoveryTimeout = "GATT discovery timed out"
    case invalidated = "Services invalidated", subscription = "Subscription changed"
    case notification = "Notification received", error = "Bluetooth error", sleep = "System sleep"
}
enum DiagnosticSeverity: String { case info, warning, error }
enum DiagnosticCounter: String { case services, characteristics, bytes, advertisedServices, serviceDataEntries, milliseconds, observedPackets, telemetryPackets, portPowerUpdates }
enum DiagnosticField: Equatable {
    case clockSync(ClockSyncOutcome)
    case advertisedBattery(AdvertisedBatteryOutcome)
    case probeKind(ProbeKind)
    case probeStage(ProbeStage)
    case probeOutcome(ProbeOutcome)
    case sessionPacket(SessionPacketMetadata)
    case authenticationStatus(AuthStatusSummary)
    case credentialAccepted(Bool)
    case batteryFields([UInt16])
    case telemetryValidation(TelemetryValidationSummary)
    case packetValidation(PacketValidationSummary)
    case availability(BluetoothAvailability)
    case uuid(String)
    case properties(UInt)
    case manufacturer(UInt16)
    case rssi(Int)
    case count(DiagnosticCounter, Int)
    case connectable(Bool)
    case subscribed(Bool)
    case transmitPower(Int)
    case error(domain: String, code: Int)

    var text: String {
        switch self {
        case .clockSync(let outcome): return outcome.label
        case .advertisedBattery(let outcome): return "source=advertisement · \(outcome.rawValue)"
        case .probeKind(let kind): return "probe=\(kind.rawValue)"
        case .probeStage(let stage): return "stage=\(stage.rawValue)"
        case .probeOutcome(let outcome): return outcome.label
        case .authenticationStatus(let summary): return summary.label
        case .batteryFields(let fields): return "fields=" + fields.filter { [263, 1251, 102, 1275, 1274].contains($0) }.map(String.init).joined(separator: ",")
        case .credentialAccepted(let accepted): return "existing credential=\(accepted ? "accepted" : "rejected")"
        case .telemetryValidation(let summary): return summary.label
        case .packetValidation(let summary): return summary.label
        case .sessionPacket(let packet):
            return String(format: "inner=V%u · route=%02X/%02X→%02X/%02X · command=%02X/%02X · payload bytes=%d",
                packet.version, packet.source, packet.deviceSource, packet.destination, packet.deviceDestination,
                packet.commandSet, packet.command, packet.payloadLength)
        case .availability(let state): return state.rawValue
        case .uuid(let uuid):
            // Accept UUID syntax only; never allow arbitrary data through this field.
            let canonical = canonicalUUID(uuid)
            return UUID(uuidString: canonical) == nil ? "UUID=<invalid>" : "UUID=\(canonical)"
        case .properties(let raw): return "properties=\(GATTCharacteristic.labels(for: raw).joined(separator: ", "))"
        case .manufacturer(let id): return String(format: "manufacturer=0x%04X", id)
        case .rssi(let value): return "RSSI=\(value) dBm"
        case .count(let kind, let count): return "\(kind.rawValue)=\(count)"
        case .connectable(let value): return "connectable=\(value)"
        case .subscribed(let value): return "subscribed=\(value)"
        case .transmitPower(let value): return "Tx=\(value) dBm"
        case .error(let domain, let code):
            let allowed = ["CBErrorDomain", "CBATTErrorDomain", "NSPOSIXErrorDomain", "NSCocoaErrorDomain"]
            return "error=\(allowed.contains(domain) ? domain : "Other")/\(code)"
        }
    }
}
struct DiagnosticEvent: Identifiable {
    let id = UUID()
    let elapsed: TimeInterval
    let severity: DiagnosticSeverity
    let kind: DiagnosticKind
    let alias: String?
    let fields: [DiagnosticField]
    var line: String {
        let details = fields.map(\.text).joined(separator: " · ")
        return String(format: "+%.2fs", elapsed) + " [\(severity.rawValue)] " + (alias.map { "\($0) · " } ?? "") + kind.rawValue + (details.isEmpty ? "" : " · \(details)")
    }
}
struct Diagnostics {
    static let capacity = 1_000
    static let payloadLimit = 512
    private(set) var events: [DiagnosticEvent] = []
    private var aliases: [UUID: String] = [:]
    private var nextAlias = 1
    private var started = ProcessInfo.processInfo.systemUptime
    mutating func record(_ kind: DiagnosticKind, severity: DiagnosticSeverity = .info, peripheral: UUID? = nil, fields: [DiagnosticField] = []) {
        var alias: String?
        if let peripheral {
            if aliases[peripheral] == nil {
                // Bound the alias map too, retaining only aliases needed by the log.
                if aliases.count >= Self.capacity {
                    let used = Set(events.suffix(Self.capacity - 1).compactMap(\.alias))
                    aliases = aliases.filter { used.contains($0.value) }
                }
                aliases[peripheral] = "Device \(nextAlias)"
                nextAlias += 1
            }
            alias = aliases[peripheral]
        }
        events.append(DiagnosticEvent(elapsed: ProcessInfo.processInfo.systemUptime - started, severity: severity, kind: kind, alias: alias, fields: fields))
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
    }
    mutating func clear() { self = Diagnostics() }
    func export(appVersion: String, systemVersion: String, services: [GATTService], gattIsStale: Bool = false) -> String {
        // Version arguments originate in the app bundle/OS, never BLE data.
        var lines = ["Somnoire \(appVersion) · Phase 2E", "macOS \(systemVersion)", "Privacy: names, peripheral identifiers, raw advertisements, packet payloads, credentials, account IDs, battery and power readings, and absolute timestamps excluded.", "", "Events:"]
        lines += events.map(\.line)
        lines += ["", gattIsStale ? "Last GATT snapshot (stale / disconnected):" : "Current GATT snapshot:"]
        for service in services {
            lines.append("Service \(DiagnosticField.uuid(service.uuid).text) · primary=\(service.isPrimary)")
            for characteristic in service.characteristics {
                lines.append("  \(DiagnosticField.uuid(characteristic.uuid).text) · \(DiagnosticField.properties(characteristic.properties).text) · \(characteristic.subscription.rawValue)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

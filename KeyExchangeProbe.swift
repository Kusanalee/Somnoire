import Foundation

extension AdvertisementSnapshot {
    var supportsKeyExchangeProbe: Bool {
        matchesObservedRapidProProfile
    }
}

enum ProbeKind: String, CaseIterable {
    case keyExchange = "Key exchange only", sessionStatus = "Session + status"
    case telemetryAccess = "Account-free telemetry check"
    case accountFreeAccess = "Account-free access check"
    case authenticatedAccess = "Authenticated telemetry check"
    var requestsDisplay: Bool { self == .accountFreeAccess || self == .authenticatedAccess }
}
enum ProbeStage: String, Equatable {
    case discovering = "Checking GATT", subscribing = "Enabling notifications"
    case publicKey = "Exchanging public keys", keyInfo = "Validating key-info reply", finished = "Finished"
    case sessionKey = "Deriving encrypted session", status = "Waiting for encrypted status reply"
    case observing = "Observing telemetry notifications"
    case requestingDisplay = "Requesting one display report"
    case checkingCredential = "Checking existing credential"
}
enum ProbeFailure: String, Error, Equatable {
    case unsupportedGATT = "unsupported GATT"
    case subscription = "subscription failed"
    case randomOrKeyGeneration = "randomness or key generation failed"
    case invalidPublicPoint = "invalid peer public point"
    case writeRejected = "supported write rejected"
    case invalidFrame = "invalid frame"
    case frameTooLarge = "frame limit exceeded"
    case bufferLimit = "receive buffer limit exceeded"
    case unexpectedReply = "unexpected reply"
    case invalidKeyInfo = "key-info decryption or validation failed"
    case sessionDerivation = "session derivation or protocol table validation failed"
    case invalidStatus = "encrypted status packet validation failed"
    case stageTimeout = "stage deadline exceeded"
    case overallTimeout = "overall deadline exceeded"
    case disconnected = "connection lost"
    case bluetoothUnavailable = "Bluetooth unavailable"
    case servicesChanged = "services changed"
    case unknownAuthStatus = "unsupported authentication status; no report requested"
    case unsupportedAuthMode = "unsupported authentication mode; no report requested"
    case invalidTelemetry = "candidate telemetry payload validation failed"
    case invalidCredential = "a numeric account ID for this P512 is required"
    case credentialState = "bank is not in normal check-existing-credential state"
    case credentialRejected = "existing credential rejected; no telemetry report requested"
    case packetDecryption = "packet AES decryption or PKCS#7 padding failed"
    case packetPrefix = "decrypted packet prefix or minimum length invalid"
    case packetHeaderCRC = "decrypted packet header CRC8 invalid"
    case packetVersion = "decrypted packet uses an unsupported inner version"
    case packetV19 = "decrypted packet uses unsupported V19 framing"
    case packetLength = "decrypted V3 packet length invalid"
    case packetCRC = "decrypted V3 packet CRC16 invalid"
    case packetV19Length = "decrypted V19 packet length invalid"
    case packetV19Sentinel = "decrypted V19 packet checksum or encoding invalid"
}
enum ProbeOutcome: Equatable {
    case verified, sessionVerified, observationComplete, accessNotEstablished, portTelemetryDecoded, authenticatedWithoutTelemetry, authenticatedTelemetryWithoutPortMeasurements, authenticatedTelemetryDecoded, cancelled, failed(ProbeFailure)
    var label: String {
        switch self {
        case .verified: "Key exchange verified — authentication not attempted."
        case .sessionVerified: "Encrypted session verified — status reply received; login not attempted."
        case .observationComplete: "Account-free observation completed — port power access remains unverified; login not attempted."
        case .accessNotEstablished: "One-shot display report did not establish account-free port telemetry. No login or credential changes."
        case .portTelemetryDecoded: "Candidate port telemetry decoded — physical comparison still required. No login or credential changes."
        case .authenticatedWithoutTelemetry: "Existing credential accepted; no display telemetry decoded."
        case .authenticatedTelemetryWithoutPortMeasurements: "Existing credential accepted; display telemetry decoded without port-power measurements. Missing values are not zero."
        case .authenticatedTelemetryDecoded: "Existing credential accepted; candidate port telemetry decoded. Physical comparison still required."
        case .cancelled: "Probe cancelled."
        case .failed(let error): "Probe failed: \(error.rawValue)."
        }
    }
}
struct ProbeResult: Equatable {
    let outcome: ProbeOutcome
    let stage: ProbeStage
    let elapsed: TimeInterval
    var kind: ProbeKind = .keyExchange
    var observedPacketCount: Int = 0
    var access: AccountFreeAccessSummary?
}

struct AuthStatusSummary: Equatable {
    enum Action: Int { case unknown = 0, setCredential = 1, checkCredential = 2 }
    enum Mode: Int { case unknown = 0, normal = 1, omos = 2 }
    var action: Action = .unknown
    var mode: Mode = .unknown
    var label: String {
        let actionText = switch action {
        case .unknown: "unknown credential state"
        case .setCredential: "app would set a credential"
        case .checkCredential: "app would check an existing credential"
        }
        let modeText = switch mode {
        case .unknown: "unknown mode"
        case .normal: "normal mode"
        case .omos: "OMOS mode"
        }
        return "\(actionText) · \(modeText)"
    }
}

struct AccountFreeAccessSummary: Equatable {
    var authentication = AuthStatusSummary()
    var credentialCheckIssued = false
    var credentialAccepted: Bool?
    var reportRequestIssued = false
    var reportReplyReceived = false
    var decodedPackets = 0
    var portPowerUpdates = 0
    // Volatile experiment data only. Not exported, persisted or presented as live UI.
    var latestDelta: P512TelemetryDelta?
}

struct AccessPacket: Equatable {
    enum Body: Equatable {
        case unrelated, status(AuthStatusSummary), credentialReply(Bool), reportReply, telemetry(Data)
    }
    let metadata: SessionPacketMetadata
    var body: Body
}

// Only validated protocol headers cross the crypto boundary during access research.
// A valid header, or an unsolicited notification, does not prove usable telemetry.
struct SessionPacketMetadata: Equatable, Hashable {
    let source: UInt8, destination: UInt8, deviceSource: UInt8, deviceDestination: UInt8
    let commandSet: UInt8, command: UInt8
    let sequence: UInt32
    let payloadLength: Int
    var version: UInt8 = 3
    var isStatusReply: Bool {
        version == 3 && source == 0x35 && destination == 0x21 && deviceSource == 1 && deviceDestination == 1 &&
            commandSet == 0x35 && command == 0x89 && sequence == 0
    }
    var isCredentialReply: Bool {
        version == 3 && source == 0x35 && destination == 0x21 && deviceSource == 1 && deviceDestination == 1 &&
            commandSet == 0x35 && command == 0x86 && sequence == 2 && payloadLength > 0
    }
}

struct PacketValidationSummary: Equatable {
    let observedLength: UInt16, declaredLength: UInt16
    enum Marker: UInt8 { case absent = 0, plain = 1, sequenceXOR = 2, both = 3 }
    let marker: Marker
    var label: String {
        let description = switch marker {
        case .absent: "neither marker check matched"
        case .plain: "raw sentinel matched"
        case .sequenceXOR: "sequence-XOR sentinel matched"
        case .both: "both sentinel checks matched"
        }
        return "V19 structure: inner bytes=\(observedLength) · declared bytes=\(declaredLength) · \(description)"
    }
}

// Only an opaque derived token is retained. Swift's SecureField/String storage
// cannot promise memory zeroization; the C token is explicitly wiped on disposal.
final class ProbeCredential {
    fileprivate private(set) var pointer: OpaquePointer?
    init?(userID: String, serial: Data) {
        var identity = Array(userID.utf8)
        defer { _ = identity.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        pointer = identity.withUnsafeBufferPointer { id in
            serial.withUnsafeBytes {
                sn_probe_credential_create(id.baseAddress, id.count, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
            }
        }
        if pointer == nil { return nil }
    }
    private init(pointer: OpaquePointer) { self.pointer = pointer }
    enum LoadFailure: Error { case missing, deniedOrLocked, malformed, saveFailed, unavailable }
    static func loadResult(bank: UUID) -> Result<ProbeCredential, LoadFailure> {
        var status: Int32 = 0
        if let pointer = bank.uuidString.withCString({ sn_probe_credential_load_status($0, &status) }) { return .success(ProbeCredential(pointer: pointer)) }
        switch status {
        case -25300: return .failure(.missing)
        case -25293, -25308, -128: return .failure(.deniedOrLocked)
        case -26275: return .failure(.malformed)
        case 1001: return .failure(.saveFailed)
        default: return .failure(.unavailable)
        }
    }
    static func load(bank: UUID) -> ProbeCredential? { try? loadResult(bank: bank).get() }
    func save(bank: UUID) -> Bool {
        bank.uuidString.withCString { sn_probe_credential_save($0, pointer) != 0 }
    }
    static func forget(bank: UUID) -> Bool {
        bank.uuidString.withCString { sn_probe_credential_forget($0) != 0 }
    }
    func copy() -> ProbeCredential? {
        guard let pointer, let copy = sn_probe_credential_clone(pointer) else { return nil }
        return ProbeCredential(pointer: copy)
    }
    func clear() { sn_probe_credential_destroy(pointer); pointer = nil }
    deinit { sn_probe_credential_destroy(pointer) }
}

struct ProbeFrame { let marker: UInt8; let payload: Data }
struct ProbeFrameCodec {
    static let bufferLimit = 4096
    static let frameLimit = 1024
    private var buffer = Data()
    static func crc(_ data: Data) -> UInt16 {
        var result: UInt16 = 0
        for byte in data {
            result ^= UInt16(byte)
            for _ in 0..<8 { result = result & 1 == 1 ? (result >> 1) ^ 0xA001 : result >> 1 }
        }
        return result
    }
    static func encode(_ payload: Data, encrypted: Bool = false) -> Data {
        precondition(payload.count + 8 <= frameLimit)
        let size = payload.count + 2
        var frame = Data([0x5A, 0x5A, encrypted ? 0x10 : 0, 1, UInt8(size & 255), UInt8(size >> 8)])
        frame.append(payload)
        let checksum = crc(frame)
        frame.append(contentsOf: [UInt8(checksum & 255), UInt8(checksum >> 8)])
        return frame
    }
    mutating func append(_ data: Data) throws -> [Data] {
        try appendFrames(data).map(\.payload)
    }
    mutating func appendFrames(_ data: Data, allowEncrypted: Bool = false) throws -> [ProbeFrame] {
        guard buffer.count + data.count <= Self.bufferLimit else { throw ProbeFailure.bufferLimit }
        buffer.append(data)
        var frames: [ProbeFrame] = []
        while buffer.count >= 6 {
            // Rebase indices after consuming prior frames (Data slices need not start at zero).
            let bytes = Array(buffer.prefix(6))
            guard bytes[0] == 0x5A, bytes[1] == 0x5A, bytes[3] == 1,
                  bytes[2] == 0 || (allowEncrypted && bytes[2] == 0x10) else { throw ProbeFailure.invalidFrame }
            let size = Int(bytes[4]) | Int(bytes[5]) << 8
            guard size >= 3 else { throw ProbeFailure.invalidFrame }
            let total = 6 + size
            guard total <= Self.frameLimit else { throw ProbeFailure.frameTooLarge }
            guard buffer.count >= total else { break }
            let frame = Data(buffer.prefix(total))
            let checksum = UInt16(frame[total - 2]) | UInt16(frame[total - 1]) << 8
            guard Self.crc(Data(frame.dropLast(2))) == checksum else { throw ProbeFailure.invalidFrame }
            frames.append(ProbeFrame(marker: bytes[2], payload: frame.subdata(in: 6..<(total - 2))))
            buffer = Data(buffer.dropFirst(total))
        }
        return frames
    }
    mutating func clear() {
        buffer.resetBytes(in: buffer.startIndex..<buffer.endIndex)
        buffer.removeAll(keepingCapacity: false)
    }
}

@MainActor
protocol ProbeCryptography: AnyObject {
    var validationSummary: PacketValidationSummary? { get }
    var publicPoint: Data { get }
    func acceptPeer(_ point: Data) throws
    func validateKeyInfo(_ ciphertext: Data) throws
    func deriveSession(_ ciphertext: Data) throws
    func statusRequest() throws -> Data
    func matchesStatusReply(_ ciphertext: Data) throws -> Bool
    func inspectPacket(_ ciphertext: Data) throws -> SessionPacketMetadata
    func displayRequest() throws -> Data
    func accessReply(_ ciphertext: Data) throws -> AccessPacket
    func credentialRequest(_ credential: ProbeCredential) throws -> Data
    func healthyRequest(_ change: HealthyChange, sequence: UInt32) throws -> Data
    func clear()
}
extension ProbeCryptography {
    func healthyRequest(_ change: HealthyChange, sequence: UInt32) throws -> Data { throw ProbeFailure.invalidStatus }
    var validationSummary: PacketValidationSummary? { nil }
    func credentialRequest(_ credential: ProbeCredential) throws -> Data { throw ProbeFailure.invalidCredential }
}
// Separate RAII storage permits nonisolated destruction without escaping an actor.
private final class CryptoStorage {
    var pointer: OpaquePointer?
    deinit { sn_probe_destroy(pointer) }
    func clear() { sn_probe_destroy(pointer); pointer = nil }
}
@MainActor
final class NativeProbeCrypto: ProbeCryptography {
    private(set) var validationSummary: PacketValidationSummary?
    private let storage = CryptoStorage()
    private(set) var publicPoint = Data()
    init() throws {
        var point = [UInt8](repeating: 0, count: 40)
        storage.pointer = point.withUnsafeMutableBufferPointer { sn_probe_create($0.baseAddress) }
        guard storage.pointer != nil else { throw ProbeFailure.randomOrKeyGeneration }
        publicPoint = Data(point)
    }
    func acceptPeer(_ point: Data) throws {
        guard point.count == 40, let pointer = storage.pointer else { throw ProbeFailure.invalidPublicPoint }
        let ok = point.withUnsafeBytes { sn_probe_accept_peer(pointer, $0.bindMemory(to: UInt8.self).baseAddress) }
        guard ok == 1 else { throw ProbeFailure.invalidPublicPoint }
    }
    func validateKeyInfo(_ ciphertext: Data) throws {
        guard let pointer = storage.pointer else { throw ProbeFailure.invalidKeyInfo }
        let ok = ciphertext.withUnsafeBytes { sn_probe_validate_info(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard ok == 1 else { throw ProbeFailure.invalidKeyInfo }
    }
    func deriveSession(_ ciphertext: Data) throws {
        guard let pointer = storage.pointer,
              let url = Bundle.main.url(forResource: "session_table", withExtension: "bin"),
              let table = try? Data(contentsOf: url), table.count == 65280 else { throw ProbeFailure.sessionDerivation }
        let ok = table.withUnsafeBytes { tableBytes in
            ciphertext.withUnsafeBytes { bytes in
                sn_probe_derive_session(pointer, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                    tableBytes.bindMemory(to: UInt8.self).baseAddress, tableBytes.count)
            }
        }
        guard ok == 1 else { throw ProbeFailure.sessionDerivation }
    }
    func statusRequest() throws -> Data {
        guard let pointer = storage.pointer else { throw ProbeFailure.sessionDerivation }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard sn_probe_status_request(pointer, &bytes) == 1 else { throw ProbeFailure.sessionDerivation }
        return Data(bytes)
    }
    func matchesStatusReply(_ ciphertext: Data) throws -> Bool {
        guard let pointer = storage.pointer else { throw ProbeFailure.invalidStatus }
        let result = ciphertext.withUnsafeBytes { sn_probe_status_reply(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard result >= 0 else { throw ProbeFailure.invalidStatus }
        return result == 1
    }
    func inspectPacket(_ ciphertext: Data) throws -> SessionPacketMetadata {
        guard let pointer = storage.pointer else { throw ProbeFailure.invalidStatus }
        var metadata = SNSessionPacketMetadata()
        let result = ciphertext.withUnsafeBytes {
            sn_probe_inspect_packet(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &metadata)
        }
        guard result == 1 else { throw ProbeFailure.invalidStatus }
        return SessionPacketMetadata(source: metadata.source, destination: metadata.destination,
            deviceSource: metadata.device_source, deviceDestination: metadata.device_destination,
            commandSet: metadata.command_set, command: metadata.command, sequence: metadata.sequence,
            payloadLength: metadata.payload_length, version: metadata.version)
    }
    func displayRequest() throws -> Data {
        guard let pointer = storage.pointer else { throw ProbeFailure.sessionDerivation }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard sn_probe_display_request(pointer, &bytes) == 1 else { throw ProbeFailure.sessionDerivation }
        return Data(bytes)
    }
    func healthyRequest(_ change: HealthyChange, sequence: UInt32) throws -> Data {
        guard change.valid, let pointer = storage.pointer else { throw ProbeFailure.invalidStatus }
        if let clock = change.clock {
            var bytes = [UInt8](repeating: 0, count: 256), count = 0
            let success = clock.zone.withCString { sn_probe_clock_request(pointer, sequence, clock.utc, clock.offset, $0, &bytes, bytes.count, &count) }
            guard success == 1 else { throw ProbeFailure.writeRejected }
            return Data(bytes.prefix(count))
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        if let (field, value) = change.screen.first {
            guard sn_probe_screen_request(pointer, sequence, field.writeField, value, &bytes) == 1 else { throw ProbeFailure.writeRejected }
            return Data(bytes)
        }
        guard sn_probe_healthy_request(pointer, sequence, change.mode.map(Int32.init) ?? -1, change.ceiling.map(Int32.init) ?? -1, change.floor.map(Int32.init) ?? -1, &bytes) == 1 else { throw ProbeFailure.writeRejected }
        return Data(bytes)
    }
    func credentialRequest(_ credential: ProbeCredential) throws -> Data {
        defer { credential.clear() }
        guard let pointer = storage.pointer, let token = credential.pointer else { throw ProbeFailure.invalidCredential }
        var bytes = [UInt8](repeating: 0, count: 64)
        guard sn_probe_credential_request(pointer, token, &bytes) == 1 else { throw ProbeFailure.invalidCredential }
        return Data(bytes)
    }
    func accessReply(_ ciphertext: Data) throws -> AccessPacket {
        validationSummary = nil
        guard let pointer = storage.pointer else { throw ProbeFailure.invalidStatus }
        var reply = SNAccessReply(), length = 0
        var bytes = [UInt8](repeating: 0, count: 984)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let result = ciphertext.withUnsafeBytes {
            sn_probe_access_reply(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count,
                &reply, &bytes, bytes.count, &length)
        }
        guard result >= 0 else {
            if reply.validation_failure == 8 || reply.validation_failure == 9 {
                validationSummary = PacketValidationSummary(observedLength: reply.observed_inner_length,
                    declaredLength: reply.declared_payload_length, marker: .init(rawValue: reply.v19_marker_flags) ?? .absent)
            }
            switch reply.validation_failure {
            case 1: throw ProbeFailure.packetDecryption
            case 2: throw ProbeFailure.packetPrefix
            case 3: throw ProbeFailure.packetHeaderCRC
            case 4: throw ProbeFailure.packetVersion
            case 5: throw ProbeFailure.packetV19
            case 6: throw ProbeFailure.packetLength
            case 7: throw ProbeFailure.packetCRC
            case 8: throw ProbeFailure.packetV19Length
            case 9: throw ProbeFailure.packetV19Sentinel
            default: throw ProbeFailure.invalidStatus
            }
        }
        let m = reply.metadata
        let metadata = SessionPacketMetadata(source: m.source, destination: m.destination,
            deviceSource: m.device_source, deviceDestination: m.device_destination,
            commandSet: m.command_set, command: m.command, sequence: m.sequence, payloadLength: m.payload_length, version: m.version)
        let body: AccessPacket.Body = switch result {
        case 1: .status(AuthStatusSummary(action: .init(rawValue: Int(reply.auth_action)) ?? .unknown,
                                       mode: .init(rawValue: Int(reply.auth_mode)) ?? .unknown))
        case 2: .reportReply
        case 3: .telemetry(Data(bytes.prefix(length)))
        case 4: .credentialReply(reply.credential_accepted == 1)
        default: .unrelated
        }
        return AccessPacket(metadata: metadata, body: body)
    }
    func clear() { validationSummary = nil; storage.clear(); publicPoint.resetBytes(in: 0..<publicPoint.count); publicPoint.removeAll() }
}

enum ProbeAction {
    case subscribe
    case write(UUID, Data)
    case unrelatedStatus(Int)
    case observedPacket(SessionPacketMetadata)
    case authenticationStatus(AuthStatusSummary)
    case decodedTelemetry
    case batteryFields([UInt16])
    case telemetryValueUnavailable(TelemetryValidationSummary)
    case telemetryValidation(TelemetryValidationSummary)
    case packetValidation(PacketValidationSummary)
    case finished(ProbeResult)
}

/// One explicitly requested experiment. No CoreBluetooth types, cloud login, or retries.
@MainActor
final class KeyExchangeProbe {
    private(set) var stage: ProbeStage = .discovering
    private(set) var result: ProbeResult?
    var onAction: ((ProbeAction) -> Void)?
    var onChange: (() -> Void)?
    private let now: () -> TimeInterval
    private let makeCrypto: () throws -> any ProbeCryptography
    let kind: ProbeKind
    private var startedAt: TimeInterval?
    private var stageStartedAt: TimeInterval = 0
    private var crypto: (any ProbeCryptography)?
    private var codec = ProbeFrameCodec()
    private var writeID: UUID?
    private var acknowledged = false
    private var reply: Data?
    private var observedPacketCount = 0
    private var observedHeaders: Set<SessionPacketMetadata> = []
    private var access: AccountFreeAccessSummary?
    private var pendingTelemetry: [P512TelemetryDelta] = []
    private var credential: ProbeCredential?
    private var pendingCredentialAccepted: Bool?
    let live: Bool
    var onTelemetry: ((P512TelemetryDelta) -> Void)?
    private var settingsID: UUID?
    private var settingsPhase = 0
    private var settingsDeadline: TimeInterval?
    private var settingsExpectedMode: UInt32?
    private var settingsChange: HealthyChange?
    private var settingsReadback = HealthySettings()
    private var settingsCompletion: ((Bool) -> Void)?
    private var settingsSequence: UInt32 = 3
    var onClockSync: ((ClockSyncOutcome) -> Void)?
    func applyHealthy(_ change: HealthyChange, completion: @escaping (Bool) -> Void) {
        guard live, isActive, stage == .observing, access?.credentialAccepted == true, settingsID == nil, change.valid, settingsSequence < UInt32.max, let crypto else { if change.clock != nil { onClockSync?(.refused) }; completion(false); return }
        do {
            let bytes = try crypto.healthyRequest(change, sequence: settingsSequence); settingsSequence += 1
            settingsExpectedMode = change.mode ?? access?.latestDelta?.healthyMode
            settingsChange = change; settingsCompletion = completion; settingsPhase = 1
            settingsDeadline = now() + 3; settingsID = UUID()
            onAction?(.write(settingsID!, ProbeFrameCodec.encode(bytes, encrypted: true))); onChange?()
        } catch { if change.clock != nil { onClockSync?(.refused) }; completion(false) }
    }
    func cancelPaneSettings() { if settingsChange?.clock == nil { cancelSettings() } }
    func cancelSettings() { finishSettings(false) }
    private func finishSettings(_ confirmed: Bool, clockOutcome: ClockSyncOutcome? = nil) {
        if settingsChange?.clock != nil { onClockSync?(clockOutcome ?? (confirmed ? .confirmed : .cancelled)) }
        let callback = settingsCompletion
        settingsCompletion = nil; settingsID = nil; settingsDeadline = nil; settingsChange = nil; settingsPhase = 0
        callback?(confirmed); onChange?()
    }
    private var lastUpload: TimeInterval?
    private var observationInterval: TimeInterval { kind.requestsDisplay ? 30 : 8 }
    private var overallInterval: TimeInterval {
        kind.requestsDisplay ? 46 : kind == .telemetryAccess ? 16 : 8
    }
    var isActive: Bool { startedAt != nil && result == nil }
    var elapsed: TimeInterval { result?.elapsed ?? startedAt.map { max(0, now() - $0) } ?? 0 }
    var deadline: TimeInterval? {
        guard isActive, let startedAt else { return nil }
        if live && stage == .observing { return min((lastUpload ?? stageStartedAt) + 15, settingsDeadline ?? .infinity) }
        let setupLimit = kind.requestsDisplay && stage != .observing ? startedAt + 16 : startedAt + overallInterval
        return min(setupLimit, stageStartedAt + (stage == .observing ? observationInterval : 3))
    }
    init(kind: ProbeKind = .keyExchange, live: Bool = false, credential: ProbeCredential? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, makeCrypto: @escaping () throws -> any ProbeCryptography = { try NativeProbeCrypto() }) {
        self.live = live
        self.kind = kind; self.now = now; self.makeCrypto = makeCrypto
        self.credential = credential
        if kind.requestsDisplay { access = AccountFreeAccessSummary() }
    }
    func start() {
        guard startedAt == nil else { return }
        startedAt = now(); transition(.discovering)
        if kind == .authenticatedAccess && credential == nil { fail(.invalidCredential) }
    }
    func gattReady() {
        guard isActive, stage == .discovering else { return }
        guard checkDeadline() else { return }
        transition(.subscribing); onAction?(.subscribe)
    }
    func subscribed(success: Bool) {
        guard isActive, stage == .subscribing else { return }
        guard checkDeadline() else { return }
        guard success else { fail(.subscription); return }
        do {
            crypto = try makeCrypto()
            guard let point = crypto?.publicPoint, point.count == 40 else { throw ProbeFailure.randomOrKeyGeneration }
            issue(.publicKey, payload: Data([1, 0]) + point)
        } catch { fail(.randomOrKeyGeneration) }
    }
    func writeCompleted(_ id: UUID, success: Bool) {
        if isActive, settingsID == id {
            guard success else { finishSettings(false, clockOutcome: .transportFailure); return }
            if settingsPhase == 1 {
                if settingsChange?.clock != nil { onClockSync?(.sent) }
                do {
                    let bytes = try crypto!.displayRequest(); settingsPhase = 2; settingsID = UUID(); settingsDeadline = now() + 3
                    onAction?(.write(settingsID!, ProbeFrameCodec.encode(bytes, encrypted: true)))
                } catch { finishSettings(false, clockOutcome: .transportFailure) }
            } else { settingsPhase = 3; settingsReadback = HealthySettings(); settingsDeadline = now() + 5 }
            onChange?(); return
        }
        guard isActive, writeID == id, !acknowledged else { return }
        guard checkDeadline() else { return }
        guard success else { fail(.writeRejected); return }
        acknowledged = true; advance()
    }
    func receive(_ data: Data) {
        guard isActive else { return }
        guard checkDeadline() else { return }
        guard stage == .publicKey || stage == .keyInfo || stage == .status || stage == .checkingCredential || stage == .requestingDisplay || stage == .observing else { fail(.unexpectedReply); return }
        do {
            for frame in try codec.appendFrames(data, allowEncrypted: kind != .keyExchange) {
                guard isActive else { break }
                let payload = frame.payload
                if stage == .status || stage == .checkingCredential || stage == .observing || stage == .requestingDisplay {
                    guard frame.marker == 0x10, let crypto else { throw ProbeFailure.unexpectedReply }
                    if kind.requestsDisplay {
                        try receiveAccess(crypto.accessReply(payload))
                        continue
                    }
                    if kind == .telemetryAccess {
                        let metadata = try crypto.inspectPacket(payload)
                        // Bound both observation work and header summaries. No raw previews.
                        guard live || observedPacketCount < 1000 else { throw ProbeFailure.bufferLimit }
                        if !metadata.isStatusReply { observedPacketCount += 1 }
                        if observedHeaders.count < 32, observedHeaders.insert(metadata).inserted {
                            onAction?(.observedPacket(metadata))
                        }
                        if stage == .status && metadata.isStatusReply { reply = Data(); advance() }
                        continue
                    }
                    // Valid unrelated traffic never completes the request or resets a deadline.
                    if try crypto.matchesStatusReply(payload) { reply = Data(); advance() }
                    else { onAction?(.unrelatedStatus(payload.count)) }
                    continue
                }
                guard frame.marker == 0 else { throw ProbeFailure.unexpectedReply }
                guard reply == nil else { throw ProbeFailure.unexpectedReply }
                if stage == .publicKey {
                    guard payload.count == 43, payload.prefix(3).elementsEqual([1, 0, 0]) else { throw ProbeFailure.unexpectedReply }
                } else {
                    guard payload.count == 33, payload.first == 2 else { throw ProbeFailure.unexpectedReply }
                }
                reply = payload
                advance()
            }
        } catch let error as ProbeFailure {
            if let summary = crypto?.validationSummary { onAction?(.packetValidation(summary)) }
            fail(error)
        }
        catch { fail(.invalidFrame) }
    }
    func expire() { if isActive { _ = checkDeadline() } }
    func cancel() { if isActive { finish(.cancelled) } }
    func fail(_ error: ProbeFailure) { if isActive { finish(.failed(error)) } }
    private func issue(_ stage: ProbeStage, payload: Data, encrypted: Bool = false) {
        reply = nil; acknowledged = false
        let id = UUID(); writeID = id
        transition(stage)
        onAction?(.write(id, ProbeFrameCodec.encode(payload, encrypted: encrypted)))
    }
    private func advance() {
        if kind.requestsDisplay, stage == .requestingDisplay, acknowledged {
            writeID = nil; transition(.observing)
            for delta in pendingTelemetry { commitTelemetry(delta) }
            pendingTelemetry.removeAll()
            return
        }
        guard acknowledged, let response = reply, let crypto else { return }
        reply = nil
        do {
            if stage == .publicKey {
                try crypto.acceptPeer(Data(response.dropFirst(3)))
                issue(.keyInfo, payload: Data([2]))
            } else if stage == .keyInfo {
                if kind == .keyExchange {
                    try crypto.validateKeyInfo(Data(response.dropFirst()))
                    finish(.verified)
                } else {
                    transition(.sessionKey)
                    try crypto.deriveSession(Data(response.dropFirst()))
                    guard checkDeadline() else { return }
                    issue(.status, payload: try crypto.statusRequest(), encrypted: true)
                }
            } else if stage == .status {
                if kind.requestsDisplay {
                    guard let auth = access?.authentication, auth.action != .unknown else { fail(.unknownAuthStatus); return }
                    guard auth.mode == .normal else { fail(.unsupportedAuthMode); return }
                    if kind == .authenticatedAccess {
                        guard auth.action == .checkCredential else { fail(.credentialState); return }
                        guard let credential else { fail(.invalidCredential); return }
                        let request = try crypto.credentialRequest(credential)
                        credential.clear(); self.credential = nil
                        access?.credentialCheckIssued = true
                        issue(.checkingCredential, payload: request, encrypted: true)
                    } else { try requestDisplay(crypto) }
                } else if kind == .telemetryAccess { writeID = nil; transition(.observing) }
                else { finish(.sessionVerified) }
            } else if stage == .checkingCredential {
                guard let accepted = pendingCredentialAccepted else { throw ProbeFailure.invalidStatus }
                pendingCredentialAccepted = nil
                access?.credentialAccepted = accepted
                guard accepted else { fail(.credentialRejected); return }
                try requestDisplay(crypto)
            }
        } catch let error as ProbeFailure { fail(error) }
        catch { fail(.invalidKeyInfo) }
    }
    private func requestDisplay(_ crypto: any ProbeCryptography) throws {
        let payload = try crypto.displayRequest()
        access?.reportRequestIssued = true
        issue(.requestingDisplay, payload: payload, encrypted: true)
    }
    private func receiveAccess(_ packet: AccessPacket) throws {
        guard live || observedPacketCount < 1000 else { throw ProbeFailure.bufferLimit }
        if !packet.metadata.isStatusReply { observedPacketCount += 1 }
        if observedHeaders.count < 32, observedHeaders.insert(packet.metadata).inserted {
            onAction?(.observedPacket(packet.metadata))
        }
        switch packet.body {
        case .status(let summary):
            guard stage == .status, packet.metadata.isStatusReply, reply == nil else { return }
            access?.authentication = summary; onAction?(.authenticationStatus(summary))
            reply = Data(); advance()
        case .credentialReply(let accepted):
            guard kind == .authenticatedAccess, stage == .checkingCredential,
                  access?.credentialCheckIssued == true, packet.metadata.isCredentialReply, reply == nil else { return }
            pendingCredentialAccepted = accepted
            reply = Data(); advance()
        case .reportReply:
            guard access?.reportRequestIssued == true else { return }
            access?.reportReplyReceived = true
        case .telemetry(var payload):
            defer { payload.resetBytes(in: payload.startIndex..<payload.endIndex) }
            guard stage == .requestingDisplay || stage == .observing else { return }
            let delta: P512TelemetryDelta
            do { delta = try P512TelemetryDecoder.decodePayload(payload) }
            catch let summary as TelemetryValidationSummary {
                onAction?(.telemetryValidation(summary))
                throw ProbeFailure.invalidTelemetry
            }
            catch { throw ProbeFailure.invalidTelemetry }
            if stage == .observing { commitTelemetry(delta) }
            else {
                guard pendingTelemetry.count < 32 else { throw ProbeFailure.bufferLimit }
                pendingTelemetry.append(delta)
            }
        case .unrelated: break
        }
    }
    private func commitTelemetry(_ delta: P512TelemetryDelta) {
        let fields: [UInt16] = [(UInt16(263), delta.health != nil || delta.rejectedHealth != nil), (1251, delta.cycles != nil), (102, delta.temperatureCelsius != nil), (1275, delta.energyInWh != nil), (1274, delta.energyOutWh != nil)].compactMap { $0.1 ? $0.0 : nil }
        if !fields.isEmpty { onAction?(.batteryFields(fields)) }
        let latest = access?.latestDelta?.merging(delta) ?? delta
        access?.latestDelta = latest
        lastUpload = now(); onTelemetry?(delta)
        if settingsPhase == 3, let change = settingsChange {
            settingsReadback.receive(delta)
            if (change.screen.isEmpty && change.clock == nil ? settingsReadback.valid && settingsReadback.mode == settingsExpectedMode : true) && settingsReadback.matches(change) { finishSettings(true) }
        }

        if live { onChange?() }
        if let rejected = delta.rejectedHealth { onAction?(.telemetryValueUnavailable(rejected)) }
        if let rejected = delta.rejectedBattery { onAction?(.telemetryValueUnavailable(rejected)) }
        access?.decodedPackets += 1
        access?.portPowerUpdates += delta.ports.values.filter { $0.watts != nil }.count
        onAction?(.decodedTelemetry)
    }
    private func transition(_ next: ProbeStage) {
        stage = next; stageStartedAt = now(); onChange?()
    }
    private func checkDeadline() -> Bool {
        if let deadline = settingsDeadline, now() >= deadline {
            let outcome = settingsChange?.clock.map { settingsPhase == 3 ? settingsReadback.timezone.outcome(for: $0) : .transportFailure }
            finishSettings(false, clockOutcome: outcome)
        }
        guard let startedAt else { return false }
        if live && stage == .observing {
            if now() >= (lastUpload ?? stageStartedAt) + 15 { fail(.stageTimeout); return false }
            return true
        }
        if stage == .observing, now() >= stageStartedAt + observationInterval {
            let hasPower = (access?.portPowerUpdates ?? 0) > 0
            let authenticatedOutcome: ProbeOutcome = hasPower ? .authenticatedTelemetryDecoded :
                (access?.decodedPackets ?? 0) > 0 ? .authenticatedTelemetryWithoutPortMeasurements : .authenticatedWithoutTelemetry
            finish(kind == .authenticatedAccess ? authenticatedOutcome :
                kind == .accountFreeAccess ? (hasPower ? .portTelemetryDecoded : .accessNotEstablished) : .observationComplete)
            return false
        }
        if now() >= startedAt + overallInterval || (kind.requestsDisplay && stage != .observing && now() >= startedAt + 16) { fail(.overallTimeout); return false }
        if stage != .observing, now() >= stageStartedAt + 3 { fail(.stageTimeout); return false }
        return true
    }
    private func finish(_ outcome: ProbeOutcome) {
        finishSettings(false)
        let value = ProbeResult(outcome: outcome, stage: stage, elapsed: elapsed, kind: kind,
            observedPacketCount: observedPacketCount, access: access)
        crypto?.clear(); crypto = nil; codec.clear()
        credential?.clear(); credential = nil; pendingCredentialAccepted = nil
        let replyCount = reply?.count ?? 0
        reply?.resetBytes(in: 0..<replyCount); reply = nil; writeID = nil
        observedHeaders.removeAll(); observedPacketCount = 0
        pendingTelemetry.removeAll(); access = nil
        result = value; stage = .finished
        onChange?(); onAction?(.finished(value))
    }
}

@MainActor
protocol BankCredentialStore {
    func loadResult(bank: UUID) -> Result<ProbeCredential, ProbeCredential.LoadFailure>
    func load(bank: UUID) -> ProbeCredential?
    func save(_ credential: ProbeCredential, bank: UUID) -> Bool
    func forget(bank: UUID) -> Bool
}
extension BankCredentialStore {
    func loadResult(bank: UUID) -> Result<ProbeCredential, ProbeCredential.LoadFailure> {
        load(bank: bank).map { .success($0) } ?? .failure(.missing)
    }
}
@MainActor
struct KeychainBankCredentialStore: BankCredentialStore {
    func loadResult(bank: UUID) -> Result<ProbeCredential, ProbeCredential.LoadFailure> { ProbeCredential.loadResult(bank: bank) }
    func load(bank: UUID) -> ProbeCredential? { ProbeCredential.load(bank: bank) }
    func save(_ credential: ProbeCredential, bank: UUID) -> Bool { credential.save(bank: bank) }
    func forget(bank: UUID) -> Bool { ProbeCredential.forget(bank: bank) }
}

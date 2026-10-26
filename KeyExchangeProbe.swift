import Foundation

extension AdvertisementSnapshot {
    var supportsKeyExchangeProbe: Bool {
        matchesObservedRapidProProfile
    }
}

enum ProbeKind: String, CaseIterable {
    case keyExchange = "Key exchange only", sessionStatus = "Session + status"
}
enum ProbeStage: String, Equatable {
    case discovering = "Checking GATT", subscribing = "Enabling notifications"
    case publicKey = "Exchanging public keys", keyInfo = "Validating key-info reply", finished = "Finished"
    case sessionKey = "Deriving encrypted session", status = "Waiting for encrypted status reply"
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
}
enum ProbeOutcome: Equatable {
    case verified, sessionVerified, cancelled, failed(ProbeFailure)
    var label: String {
        switch self {
        case .verified: "Key exchange verified — authentication not attempted."
        case .sessionVerified: "Encrypted session verified — status reply received; login not attempted."
        case .cancelled: "Probe cancelled — authentication not attempted."
        case .failed(let error): "Probe failed: \(error.rawValue) — authentication not attempted."
        }
    }
}
struct ProbeResult: Equatable {
    let outcome: ProbeOutcome
    let stage: ProbeStage
    let elapsed: TimeInterval
    var kind: ProbeKind = .keyExchange
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
    var publicPoint: Data { get }
    func acceptPeer(_ point: Data) throws
    func validateKeyInfo(_ ciphertext: Data) throws
    func deriveSession(_ ciphertext: Data) throws
    func statusRequest() throws -> Data
    func matchesStatusReply(_ ciphertext: Data) throws -> Bool
    func clear()
}
// Separate RAII storage permits nonisolated destruction without escaping an actor.
private final class CryptoStorage {
    var pointer: OpaquePointer?
    deinit { sn_probe_destroy(pointer) }
    func clear() { sn_probe_destroy(pointer); pointer = nil }
}
@MainActor
final class NativeProbeCrypto: ProbeCryptography {
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
    func clear() { storage.clear(); publicPoint.resetBytes(in: 0..<publicPoint.count); publicPoint.removeAll() }
}

enum ProbeAction {
    case subscribe
    case write(UUID, Data)
    case unrelatedStatus(Int)
    case finished(ProbeResult)
}

/// One explicitly requested experiment. No CoreBluetooth types, login, or retries.
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
    var isActive: Bool { startedAt != nil && result == nil }
    var elapsed: TimeInterval { result?.elapsed ?? startedAt.map { max(0, now() - $0) } ?? 0 }
    var deadline: TimeInterval? {
        guard isActive, let startedAt else { return nil }
        return min(startedAt + 8, stageStartedAt + 3)
    }
    init(kind: ProbeKind = .keyExchange, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, makeCrypto: @escaping () throws -> any ProbeCryptography = { try NativeProbeCrypto() }) {
        self.kind = kind; self.now = now; self.makeCrypto = makeCrypto
    }
    func start() {
        guard startedAt == nil else { return }
        startedAt = now(); transition(.discovering)
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
        guard isActive, writeID == id, !acknowledged else { return }
        guard checkDeadline() else { return }
        guard success else { fail(.writeRejected); return }
        acknowledged = true; advance()
    }
    func receive(_ data: Data) {
        guard isActive else { return }
        guard checkDeadline() else { return }
        guard stage == .publicKey || stage == .keyInfo || stage == .status else { fail(.unexpectedReply); return }
        do {
            for frame in try codec.appendFrames(data, allowEncrypted: kind == .sessionStatus) {
                guard isActive else { break }
                let payload = frame.payload
                if stage == .status {
                    guard frame.marker == 0x10, let crypto else { throw ProbeFailure.unexpectedReply }
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
        } catch let error as ProbeFailure { fail(error) }
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
                finish(.sessionVerified)
            }
        } catch let error as ProbeFailure { fail(error) }
        catch { fail(.invalidKeyInfo) }
    }
    private func transition(_ next: ProbeStage) {
        stage = next; stageStartedAt = now(); onChange?()
    }
    private func checkDeadline() -> Bool {
        guard let startedAt else { return false }
        if now() >= startedAt + 8 { fail(.overallTimeout); return false }
        if now() >= stageStartedAt + 3 { fail(.stageTimeout); return false }
        return true
    }
    private func finish(_ outcome: ProbeOutcome) {
        let value = ProbeResult(outcome: outcome, stage: stage, elapsed: elapsed, kind: kind)
        crypto?.clear(); crypto = nil; codec.clear()
        let replyCount = reply?.count ?? 0
        reply?.resetBytes(in: 0..<replyCount); reply = nil; writeID = nil
        result = value; stage = .finished
        onChange?(); onAction?(.finished(value))
    }
}

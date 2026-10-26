import XCTest
@testable import Somnoire

@MainActor
private final class FakeCrypto: ProbeCryptography {
    let publicPoint = Data(repeating: 0xA1, count: 40)
    var accepted = false
    var cleared = false
    var rejectInfo = false
    var derived = false
    func acceptPeer(_ point: Data) throws { accepted = true }
    func validateKeyInfo(_ ciphertext: Data) throws { if rejectInfo { throw ProbeFailure.invalidKeyInfo } }
    func deriveSession(_ ciphertext: Data) throws {
        if rejectInfo { throw ProbeFailure.sessionDerivation }; derived = true
    }
    func statusRequest() throws -> Data { Data(repeating: 0xA5, count: 32) }
    func matchesStatusReply(_ ciphertext: Data) throws -> Bool {
        if ciphertext.first == 0xFF { throw ProbeFailure.invalidStatus }
        return ciphertext.first == 1
    }
    func clear() { cleared = true }
}

final class ProbeTests: XCTestCase {
    private func profile() -> AdvertisementSnapshot {
        var data = Data([0xB5, 0xB5, 0x13])
        data.append(Data("P512000000000000".utf8))
        data.append(Data(repeating: 0, count: 6))
        data[24] = 0xBE
        return AdvertisementSnapshot(manufacturerData: data)
    }
    func testProbeRequiresCompleteSpecificAdvertisementProfile() {
        XCTAssertTrue(profile().supportsKeyExchangeProbe)
        for size in 0..<25 {
            XCTAssertFalse(AdvertisementSnapshot(manufacturerData: profile().manufacturerData!.prefix(size)).supportsKeyExchangeProbe)
        }
        for index in [0, 1, 2, 3, 4, 5, 6, 24] {
            var adv = profile(); adv.manufacturerData![index] = 0
            XCTAssertFalse(adv.supportsKeyExchangeProbe)
        }
    }
    func testCRCMatchesStandardARCCheckValue() {
        XCTAssertEqual(ProbeFrameCodec.crc(Data("123456789".utf8)), 0xBB3D)
    }
    func testFramesSupportArbitraryFragmentationAndCoalescing() throws {
        let first = Data([1, 0, 0]) + Data(repeating: 0xAA, count: 40)
        let second = Data([2]) + Data(repeating: 0xBB, count: 32)
        let stream = ProbeFrameCodec.encode(first) + ProbeFrameCodec.encode(second)
        for split in 0...stream.count {
            var codec = ProbeFrameCodec()
            let a = try codec.append(Data(stream.prefix(split)))
            let b = try codec.append(Data(stream.dropFirst(split)))
            XCTAssertEqual(a + b, [first, second])
        }
        var codec = ProbeFrameCodec(); var decoded: [Data] = []
        for byte in stream { decoded += try codec.append(Data([byte])) }
        XCTAssertEqual(decoded, [first, second])
    }
    func testFrameValidationAndLimits() {
        var crc = ProbeFrameCodec.encode(Data([2])); crc[6] ^= 1
        var codec = ProbeFrameCodec()
        XCTAssertThrowsError(try codec.append(crc))
        codec.clear()
        XCTAssertThrowsError(try codec.append(Data([0x5A, 0x5A, 0, 1, 1, 0])))
        codec.clear()
        XCTAssertThrowsError(try codec.append(Data([0x5A, 0x5A, 0, 1, 0xFF, 0xFF])))
        codec.clear()
        XCTAssertThrowsError(try codec.append(Data(repeating: 0, count: 4097)))
        codec.clear()
        XCTAssertThrowsError(try codec.append(Data([0x5A, 0x5A, 0x10, 1, 3, 0])))
    }

    @MainActor
    func testEarlyRepliesWaitForWriteAcknowledgementAndOnlyTwoCommands() {
        let crypto = FakeCrypto(); var actions: [ProbeAction] = []
        let probe = KeyExchangeProbe(makeCrypto: { crypto })
        probe.onAction = { actions.append($0) }
        probe.start(); probe.start(); probe.gattReady(); probe.subscribed(success: true)
        guard case .write(let firstID, let firstData) = actions.last else { return XCTFail("Missing first write") }
        XCTAssertEqual(firstData.count, 50)
        probe.receive(ProbeFrameCodec.encode(Data([1, 0, 0]) + Data(repeating: 1, count: 40)))
        XCTAssertFalse(crypto.accepted)
        probe.writeCompleted(firstID, success: true)
        XCTAssertTrue(crypto.accepted)
        guard case .write(let secondID, let secondData) = actions.last else { return XCTFail("Missing second write") }
        XCTAssertEqual(secondData, ProbeFrameCodec.encode(Data([2])))
        probe.writeCompleted(firstID, success: false) // stale callback cannot fail the new stage
        probe.receive(ProbeFrameCodec.encode(Data([2]) + Data(repeating: 0, count: 32)))
        XCTAssertNil(probe.result)
        probe.writeCompleted(secondID, success: true)
        XCTAssertEqual(probe.result?.outcome, .verified)
        XCTAssertTrue(crypto.cleared)
        XCTAssertEqual(actions.filter { if case .write = $0 { true } else { false } }.count, 2)
        probe.receive(Data([0])); probe.cancel()
        XCTAssertEqual(probe.result?.outcome, .verified)
    }

    @MainActor
    func testSubscriptionAndWriteFailureStopWithoutFallback() {
        let subscription = KeyExchangeProbe(makeCrypto: { XCTFail("Crypto should not be created"); return FakeCrypto() })
        subscription.start(); subscription.gattReady(); subscription.subscribed(success: false)
        XCTAssertEqual(subscription.result?.outcome, .failed(.subscription))
        let crypto = FakeCrypto(); let probe = KeyExchangeProbe(makeCrypto: { crypto })
        var writes: [(UUID, Data)] = []
        probe.onAction = { if case .write(let id, let data) = $0 { writes.append((id, data)) } }
        probe.start(); probe.gattReady(); probe.subscribed(success: true)
        probe.writeCompleted(writes[0].0, success: false)
        XCTAssertEqual(probe.result?.outcome, .failed(.writeRejected))
        XCTAssertEqual(writes.count, 1); XCTAssertTrue(crypto.cleared)
    }

    @MainActor
    func testDeadlinesAndCancellationClearCrypto() {
        var clock = 0.0; let crypto = FakeCrypto()
        let probe = KeyExchangeProbe(now: { clock }, makeCrypto: { crypto })
        probe.start(); clock = 2; probe.gattReady(); clock = 4; probe.subscribed(success: true)
        XCTAssertEqual(probe.deadline, 7)
        clock = 7; probe.expire()
        XCTAssertEqual(probe.result?.outcome, .failed(.stageTimeout)); XCTAssertTrue(crypto.cleared)
        clock = 0
        let overall = KeyExchangeProbe(now: { clock }, makeCrypto: { FakeCrypto() })
        overall.start(); clock = 2.9; overall.gattReady(); clock = 5.8; overall.subscribed(success: true)
        XCTAssertEqual(overall.deadline, 8)
        clock = 8; overall.expire()
        XCTAssertEqual(overall.result?.outcome, .failed(.overallTimeout))
        let cancelledCrypto = FakeCrypto(); let cancelled = KeyExchangeProbe(makeCrypto: { cancelledCrypto })
        cancelled.start(); cancelled.gattReady(); cancelled.subscribed(success: true); cancelled.cancel()
        XCTAssertEqual(cancelled.result?.outcome, .cancelled); XCTAssertTrue(cancelledCrypto.cleared)
    }

    @MainActor
    func testUnexpectedReplyAndInvalidDecryptionAreFailures() {
        let crypto = FakeCrypto(); crypto.rejectInfo = true
        let probe = KeyExchangeProbe(makeCrypto: { crypto }); var id: UUID?
        probe.onAction = { if case .write(let next, _) = $0 { id = next } }
        probe.start(); probe.gattReady(); probe.subscribed(success: true)
        probe.writeCompleted(id!, success: true)
        probe.receive(ProbeFrameCodec.encode(Data([1, 0, 0]) + Data(repeating: 1, count: 40)))
        probe.writeCompleted(id!, success: true)
        probe.receive(ProbeFrameCodec.encode(Data([2]) + Data(repeating: 0, count: 32)))
        XCTAssertEqual(probe.result?.outcome, .failed(.invalidKeyInfo)); XCTAssertTrue(crypto.cleared)
        let invalid = KeyExchangeProbe(makeCrypto: { FakeCrypto() })
        invalid.start(); invalid.gattReady(); invalid.subscribed(success: true)
        invalid.receive(ProbeFrameCodec.encode(Data([1, 1, 0]) + Data(repeating: 0, count: 40)))
        XCTAssertEqual(invalid.result?.outcome, .failed(.unexpectedReply))
    }

    @MainActor
    func testNativeCryptoFailsClosedForRejectedScalarEdgeCase() {
        // Pinned micro-ecc rejects scalar one in its co-Z multiplication path.
        // Production make_key retries rejected generated points; explicit failures
        // never produce an accepted key or shared secret.
        var scalar = [UInt8](repeating: 0, count: 21); scalar[20] = 1
        var point = [UInt8](repeating: 0, count: 40)
        XCTAssertNil(sn_probe_test_create(scalar, &point))
    }

    @MainActor
    func testNativeCryptoRandomnessAndInvalidPointHandling() throws {
        let first = try NativeProbeCrypto(); let second = try NativeProbeCrypto()
        defer { first.clear(); second.clear() }
        XCTAssertNotEqual(first.publicPoint, second.publicPoint)
        XCTAssertThrowsError(try first.acceptPeer(Data(repeating: 0, count: 40)))
        XCTAssertThrowsError(try first.acceptPeer(Data(repeating: 0xFF, count: 40)))
        sn_probe_test_rng_failure(1)
        defer { sn_probe_test_rng_failure(0) }
        XCTAssertThrowsError(try NativeProbeCrypto())
    }

    @MainActor
    func testNativeCryptoMatchesIndependentOpenSSLVectorsAndStrictPadding() throws {
        struct Vector: Decodable {
            struct StatusCase: Decodable { let name: String, ciphertext: String; let result: Int32 }
            let local_private: String, peer_public: String, shared_secret: String
            let valid_info: String, wrong_length_info: String, invalid_padding_info: String
            let session_key: String, status_request: String, invalid_seed_info: String
            let status_cases: [StatusCase]
        }
        struct Fixture: Decodable { let vectors: [Vector] }
        func bytes(_ hex: String) -> [UInt8] {
            stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ProbeVectors", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for vector in fixture.vectors {
            let scalar = bytes(vector.local_private), peer = bytes(vector.peer_public)
            var secret = [UInt8](repeating: 0, count: 20)
            XCTAssertEqual(sn_probe_test_shared(scalar, peer, &secret), 1)
            XCTAssertEqual(secret, bytes(vector.shared_secret))
            var publicPoint = [UInt8](repeating: 0, count: 40)
            let context = try XCTUnwrap(sn_probe_test_create(scalar, &publicPoint))
            defer { sn_probe_destroy(context) }
            XCTAssertEqual(sn_probe_accept_peer(context, peer), 1)
            for (hex, expected) in [(vector.valid_info, 1), (vector.wrong_length_info, 0), (vector.invalid_padding_info, 0)] {
                let ciphertext = bytes(hex)
                XCTAssertEqual(sn_probe_validate_info(context, ciphertext, ciphertext.count), Int32(expected))
            }
            XCTAssertEqual(sn_probe_validate_info(context, [UInt8](repeating: 0, count: 16), 16), 0)
            let tableURL = try XCTUnwrap(Bundle.main.url(forResource: "session_table", withExtension: "bin"))
            let table = [UInt8](try Data(contentsOf: tableURL)), info = bytes(vector.valid_info)
            var altered = table; altered[0] ^= 1
            XCTAssertEqual(sn_probe_derive_session(context, info, info.count, altered, altered.count), 0)
            XCTAssertEqual(sn_probe_derive_session(context, info, info.count, table, table.count - 1), 0)
            let bad = bytes(vector.invalid_padding_info)
            XCTAssertEqual(sn_probe_derive_session(context, bad, bad.count, table, table.count), 0)
            for value in [vector.wrong_length_info, vector.invalid_seed_info] {
                let invalid = bytes(value)
                XCTAssertEqual(sn_probe_derive_session(context, invalid, invalid.count, table, table.count), 0)
            }
            XCTAssertEqual(sn_probe_derive_session(context, info, info.count, table, table.count), 1)
            var sessionKey = [UInt8](repeating: 0, count: 16)
            XCTAssertEqual(sn_probe_test_session_key(context, &sessionKey), 1)
            XCTAssertEqual(sessionKey, bytes(vector.session_key))
            var request = [UInt8](repeating: 0, count: 32)
            XCTAssertEqual(sn_probe_status_request(context, &request), 1)
            XCTAssertEqual(request, bytes(vector.status_request))
            for item in vector.status_cases {
                let ciphertext = bytes(item.ciphertext)
                XCTAssertEqual(sn_probe_status_reply(context, ciphertext, ciphertext.count), item.result, item.name)
            }
            XCTAssertEqual(sn_probe_status_reply(context, request, 31), -1)
            XCTAssertEqual(sn_probe_status_reply(context, [UInt8](repeating: 0, count: 1024), 1024), -1)
            XCTAssertEqual(sn_probe_derive_session(context, info, info.count, table, table.count), 0)
        }
        XCTAssertEqual(bytes(fixture.vectors[1].shared_secret).first, 0)
    }

    func testProtocolTableOffsetAllSeedCombinationsHaveCheckedBounds() {
        for first in 0...255 {
            for second in 0...255 {
                let expected = first * 16 + ((second + 255) % 256) * 256
                var offset = 123456
                let ok = sn_probe_test_offset(UInt8(first), UInt8(second), &offset)
                if expected <= 65264 {
                    XCTAssertEqual(ok, 1); XCTAssertEqual(offset, expected)
                } else { XCTAssertEqual(ok, 0); XCTAssertEqual(offset, 123456) }
            }
        }
    }

    @MainActor
    private func statusProbe(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> (KeyExchangeProbe, FakeCrypto, UUID) {
        let crypto = FakeCrypto(), probe = KeyExchangeProbe(kind: .sessionStatus, now: clock, makeCrypto: { crypto })
        var writes: [(UUID, Data)] = []
        probe.onAction = { if case .write(let id, let data) = $0 { writes.append((id, data)) } }
        probe.start(); probe.start(); probe.gattReady(); probe.subscribed(success: true)
        probe.writeCompleted(writes[0].0, success: true)
        probe.receive(ProbeFrameCodec.encode(Data([1, 0, 0]) + Data(repeating: 1, count: 40)))
        probe.writeCompleted(writes[1].0, success: true)
        probe.receive(ProbeFrameCodec.encode(Data([2]) + Data(repeating: 0, count: 32)))
        XCTAssertTrue(crypto.derived); XCTAssertEqual(writes.count, 3)
        XCTAssertEqual(writes[2].1[2], 0x10)
        return (probe, crypto, writes[2].0)
    }

    @MainActor
    func testSessionStatusIgnoresUnrelatedRepliesAndWaitsForWriteACK() {
        let (probe, crypto, id) = statusProbe()
        probe.receive(ProbeFrameCodec.encode(Data(repeating: 2, count: 32), encrypted: true))
        XCTAssertNil(probe.result)
        probe.receive(ProbeFrameCodec.encode(Data(repeating: 1, count: 32), encrypted: true))
        XCTAssertNil(probe.result)
        probe.writeCompleted(UUID(), success: false)
        XCTAssertNil(probe.result)
        probe.writeCompleted(id, success: true)
        XCTAssertEqual(probe.result?.outcome, .sessionVerified)
        XCTAssertEqual(probe.result?.kind, .sessionStatus); XCTAssertTrue(crypto.cleared)
    }

    @MainActor
    func testSessionFailureCancellationAndDeadlineCleanup() {
        let (rejected, rejectedCrypto, id) = statusProbe()
        rejected.receive(ProbeFrameCodec.encode(Data(repeating: 1, count: 32), encrypted: true))
        rejected.writeCompleted(id, success: false)
        XCTAssertEqual(rejected.result?.outcome, .failed(.writeRejected)); XCTAssertTrue(rejectedCrypto.cleared)
        let (malformed, malformedCrypto, _) = statusProbe()
        malformed.receive(ProbeFrameCodec.encode(Data(repeating: 0xFF, count: 32), encrypted: true))
        XCTAssertEqual(malformed.result?.outcome, .failed(.invalidStatus)); XCTAssertTrue(malformedCrypto.cleared)
        let (cancelled, cancelledCrypto, _) = statusProbe()
        cancelled.cancel(); XCTAssertEqual(cancelled.result?.outcome, .cancelled); XCTAssertTrue(cancelledCrypto.cleared)
        var time = 0.0
        let (expired, expiredCrypto, _) = statusProbe(clock: { time })
        time = 2.9
        expired.receive(ProbeFrameCodec.encode(Data(repeating: 2, count: 32), encrypted: true))
        XCTAssertEqual(expired.deadline, 3)
        time = 3; expired.expire()
        XCTAssertEqual(expired.result?.outcome, .failed(.stageTimeout)); XCTAssertTrue(expiredCrypto.cleared)
    }

    @MainActor
    func testSessionReplyAfterACKCanBeFragmentedAndCoalescedWithUnrelatedPackets() {
        let (probe, crypto, id) = statusProbe()
        probe.writeCompleted(id, success: true)
        let unrelated = ProbeFrameCodec.encode(Data(repeating: 2, count: 32), encrypted: true)
        let matching = ProbeFrameCodec.encode(Data(repeating: 1, count: 32), encrypted: true)
        probe.receive(Data(unrelated.prefix(7)))
        XCTAssertNil(probe.result)
        probe.receive(Data(unrelated.dropFirst(7)) + matching)
        XCTAssertEqual(probe.result?.outcome, .sessionVerified); XCTAssertTrue(crypto.cleared)
        probe.writeCompleted(id, success: false); probe.start(); probe.cancel()
        XCTAssertEqual(probe.result?.outcome, .sessionVerified)
    }

    func testEncryptedFramesFragmentCoalesceAndRequireExplicitCodecPermission() throws {
        let data = Data(repeating: 0x42, count: 32)
        let stream = ProbeFrameCodec.encode(data, encrypted: true) + ProbeFrameCodec.encode(data, encrypted: true)
        for split in 0...stream.count {
            var codec = ProbeFrameCodec()
            let a = try codec.appendFrames(Data(stream.prefix(split)), allowEncrypted: true)
            let b = try codec.appendFrames(Data(stream.dropFirst(split)), allowEncrypted: true)
            XCTAssertEqual((a + b).map(\.marker), [0x10, 0x10])
            XCTAssertEqual((a + b).map(\.payload), [data, data])
        }
        var codec = ProbeFrameCodec()
        XCTAssertThrowsError(try codec.append(stream))
        codec.clear()
        var bad = stream; bad[7] ^= 1
        XCTAssertThrowsError(try codec.appendFrames(bad, allowEncrypted: true))
    }

    // Opt-in only: the dedicated hardware scheme enables this environment flag.
    @MainActor
    func testHardwareKeyExchangeTwice() async throws {
        guard ProcessInfo.processInfo.environment["SOMNOIRE_HARDWARE_PROBES"] == "1" else {
            throw XCTSkip("Hardware probes require the explicit Somnoire Hardware Probe scheme.")
        }
        let manager = BluetoothManager()
        defer { manager.shutdown() }
        func wait(seconds: TimeInterval, until predicate: () -> Bool) async throws -> Bool {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while !predicate() && ProcessInfo.processInfo.systemUptime < end {
                try await Task.sleep(for: .milliseconds(100))
            }
            return predicate()
        }
        let sessionStatus = ProcessInfo.processInfo.environment["SOMNOIRE_HARDWARE_SESSION_STATUS"] == "1"
        var failures: [String] = []
        for attempt in 1...2 {
            manager.startScan()
            let found = try await wait(seconds: 15) {
                manager.devices.contains { $0.advertisement.supportsKeyExchangeProbe && manager.canConnect($0) }
            }
            guard found else {
                XCTFail("Hardware attempt \(attempt): no eligible peripheral; \(manager.availability.rawValue)")
                return
            }
            let candidates = manager.devices.filter { $0.advertisement.supportsKeyExchangeProbe && manager.canConnect($0) }
            guard candidates.count == 1 else { XCTFail("Hardware selection is ambiguous; no probe sent."); return }
            manager.connectAndProbe(to: candidates[0].id, kind: sessionStatus ? .sessionStatus : .keyExchange)
            let finished = try await wait(seconds: 30) { manager.probeResult != nil }
            guard finished, let result = manager.probeResult else { XCTFail("Hardware probe did not complete."); return }
            if result.outcome != (sessionStatus ? .sessionVerified : .verified) {
                failures.append("Hardware attempt \(attempt): \(result.outcome.label); stage=\(result.stage.rawValue)")
            }
            print("Hardware attempt \(attempt): \(result.outcome.label); stage=\(result.stage.rawValue); duration=\(result.elapsed)")
            let disconnected = try await wait(seconds: 5) { manager.connection.isIdle }
            guard disconnected else { XCTFail("Intentional disconnect did not finish."); return }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testExportLabelsRetainedDisconnectedSnapshot() {
        let log = Diagnostics()
        let report = log.export(appVersion: "test", systemVersion: "test", services: [], gattIsStale: true)
        XCTAssertTrue(report.contains("Last GATT snapshot (stale / disconnected):"))
        XCTAssertFalse(report.contains("Current GATT snapshot:"))
    }

    @MainActor
    func testProbeDiagnosticsContainOnlySanitizedOutcome() {
        var log = Diagnostics()
        log.record(.probeFinished, fields: [.probeStage(.keyInfo), .probeOutcome(.verified), .count(.milliseconds, 1600)])
        let text = log.export(appVersion: "0.2.0", systemVersion: "test", services: [])
        XCTAssertTrue(text.contains("Key exchange verified — authentication not attempted."))
        XCTAssertTrue(text.contains("milliseconds=1600"))
        XCTAssertFalse(text.contains("P512"))
        log.record(.probeFinished, fields: [.probeKind(.sessionStatus), .probeStage(.status), .probeOutcome(.sessionVerified)])
        let session = log.export(appVersion: "0.3.0", systemVersion: "test", services: [])
        XCTAssertTrue(session.contains("Encrypted session verified — status reply received; login not attempted."))
        for secret in ["session_key", "seed=", "srand", "ciphertext=", "private_key", "serial="] {
            XCTAssertFalse(session.contains(secret))
        }
    }
}

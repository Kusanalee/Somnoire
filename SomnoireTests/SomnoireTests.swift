import XCTest
import SwiftUI
import AppKit
import CoreBluetooth
@testable import Somnoire

final class SomnoireTests: XCTestCase {
    private func batteryProfile(_ percentage: UInt8 = 100) -> AdvertisementSnapshot {
        var data = Data([0xB5, 0xB5, 0x13])
        data.append(Data("P512000000000000".utf8))
        data.append(Data(repeating: 0, count: 6))
        data[19] = percentage; data[24] = 0xBE
        return AdvertisementSnapshot(manufacturerData: data)
    }

    func testAdvertisedBatteryChecksProfileAndEveryTruncatedLength() {
        let now = Date(timeIntervalSince1970: 1234), profile = batteryProfile()
        for count in 0..<25 {
            XCTAssertNil(AdvertisedBatteryReading.decode(AdvertisementSnapshot(manufacturerData: Data(profile.manufacturerData!.prefix(count))), observedAt: now))
        }
        XCTAssertNil(AdvertisedBatteryReading.decode(AdvertisementSnapshot(), observedAt: now))
        for index in [0, 1, 2, 3, 4, 5, 6, 18, 24] {
            var invalid = profile; invalid.manufacturerData![index] = 0
            XCTAssertNil(AdvertisedBatteryReading.decode(invalid, observedAt: now))
            XCTAssertFalse(invalid.supportsKeyExchangeProbe)
        }
        XCTAssertEqual(AdvertisedBatteryReading.decode(profile, observedAt: now)?.observedAt, now)
        // Data views need not have zero-based indices.
        let prefixed = Data([0, 0]) + profile.manufacturerData!
        XCTAssertEqual(AdvertisedBatteryReading.decode(AdvertisementSnapshot(manufacturerData: prefixed.dropFirst(2)), observedAt: now)?.percentage, 100)
    }

    func testAdvertisedBatteryAcceptsOnlyWholeByteValuesZeroThroughOneHundred() {
        let now = Date(timeIntervalSince1970: 1234)
        for value in 0...255 {
            let reading = AdvertisedBatteryReading.decode(batteryProfile(UInt8(value)), observedAt: now)
            if value <= 100 { XCTAssertEqual(reading?.percentage, value) }
            else { XCTAssertNil(reading, "Do not clamp, substitute zero, or mask flag bits.") }
        }
    }

    func testBatterySampleTracksOnlyNewManufacturerPayloadsAndInvalidatesBadData() {
        let first = Date(timeIntervalSince1970: 100), later = Date(timeIntervalSince1970: 200)
        var device = DiscoveredDevice(id: UUID(), advertisement: AdvertisementSnapshot())
        XCTAssertEqual(device.updateAdvertisement(batteryProfile(), observedAt: first), .decoded)
        XCTAssertEqual(device.advertisedBattery?.percentage, 100)
        XCTAssertNil(device.updateAdvertisement(AdvertisementSnapshot(localName: "EF-test", serviceUUIDs: ["180A"]), observedAt: later))
        XCTAssertEqual(device.advertisedBattery?.observedAt, first)
        XCTAssertEqual(device.advertisement.serviceUUIDs, ["180A"])
        XCTAssertEqual(device.name, "EF-test")
        XCTAssertEqual(device.updateAdvertisement(batteryProfile(99), observedAt: later), .decoded)
        XCTAssertEqual(device.advertisedBattery?.percentage, 99)
        XCTAssertEqual(device.advertisedBattery?.observedAt, later)
        XCTAssertEqual(device.updateAdvertisement(batteryProfile(255), observedAt: later), .invalidValue)
        XCTAssertNil(device.advertisedBattery)
        device.updateAdvertisement(batteryProfile(), observedAt: first)
        XCTAssertEqual(device.updateAdvertisement(AdvertisementSnapshot(manufacturerData: Data()), observedAt: later), .unsupportedProfile)
        XCTAssertNil(device.advertisedBattery)
    }

    @MainActor
    func testMalformedCoreBluetoothManufacturerValueInvalidatesBattery() {
        var device = DiscoveredDevice(id: UUID(), advertisement: AdvertisementSnapshot())
        device.updateAdvertisement(batteryProfile(), observedAt: Date())
        let missing = BluetoothManager.advertisement(from: [:])
        device.updateAdvertisement(missing, observedAt: Date())
        XCTAssertNotNil(device.advertisedBattery)
        let malformed = BluetoothManager.advertisement(from: [CBAdvertisementDataManufacturerDataKey: "bad"])
        device.updateAdvertisement(malformed, observedAt: Date())
        XCTAssertNil(device.advertisedBattery)
    }

    func testBatteryPresentationHonorsHardwareGateAndLabelsSource() {
        var device = DiscoveredDevice(id: UUID(), advertisement: AdvertisementSnapshot())
        XCTAssertNil(device.visibleBatteryReading(hardwareValidated: true))
        device.updateAdvertisement(batteryProfile(), observedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNil(device.visibleBatteryReading(hardwareValidated: false))
        XCTAssertEqual(device.visibleBatteryReading(hardwareValidated: true)?.label, "Battery 100% · advertised")
    }

    func testBatteryDiagnosticsExportOnlyFixedOutcomesAndSource() {
        var log = Diagnostics()
        for outcome in [AdvertisedBatteryOutcome.decoded, .invalidValue, .unsupportedProfile] {
            log.record(.advertisedBattery, fields: [.advertisedBattery(outcome)])
        }
        let report = log.export(appVersion: "0.4.0", systemVersion: "test", services: [])
        XCTAssertTrue(report.contains("source=advertisement"))
        XCTAssertTrue(report.contains("candidate decoded"))
        for excluded in ["Battery 100%", "percentage=", "P512", "observedAt=", "B5 B5", "1970"] {
            XCTAssertFalse(report.contains(excluded))
        }
    }

    @MainActor
    func testHardwareAdvertisementBatterySample() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SOMNOIRE_BATTERY_HARDWARE_SAMPLE"] == "1" else {
            throw XCTSkip("Advertisement-only hardware sampling is explicitly opt-in.")
        }
        let manager = BluetoothManager()
        defer { manager.shutdown() }
        manager.startScan()
        let end = ProcessInfo.processInfo.systemUptime + 15
        while !manager.devices.contains(where: { $0.advertisement.matchesObservedRapidProProfile }) && ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(for: .milliseconds(100))
        }
        manager.stopScan()
        let candidates = manager.devices.filter { $0.advertisement.matchesObservedRapidProProfile }
        guard candidates.count == 1 else {
            let manufacturerCount = manager.devices.filter { $0.advertisement.manufacturerID == 0xB5B5 }.count
            return XCTFail("No unambiguous matching advertisement; matches=\(candidates.count), manufacturerMatches=\(manufacturerCount), peripherals=\(manager.devices.count), availability=\(manager.availability.rawValue). No connection attempted.")
        }
        let reading = try XCTUnwrap(candidates[0].advertisedBattery, "Candidate is absent or outside the supported range.")
        print("Advertisement-only candidate percentage: \(reading.percentage); production label enabled: \(AdvertisedBatteryReading.hardwareValidated)")
        if let expected = environment["SOMNOIRE_BATTERY_EXPECTED_PERCENT"].flatMap(Int.init) {
            XCTAssertTrue((0...100).contains(expected)); XCTAssertEqual(reading.percentage, expected)
        }
        XCTAssertEqual(manager.connection, .idle)
        XCTAssertFalse(manager.diagnostics.events.contains { [.connecting, .connected, .probeStarted, .subscription].contains($0.kind) })
    }

    func testManufacturerDecodingIsBoundsCheckedAndLittleEndian() {
        XCTAssertNil(AdvertisementSnapshot().manufacturerID)
        XCTAssertNil(AdvertisementSnapshot(manufacturerData: Data()).manufacturerID)
        XCTAssertNil(AdvertisementSnapshot(manufacturerData: Data([0xB5])).manufacturerID)
        XCTAssertEqual(AdvertisementSnapshot(manufacturerData: Data([0xA8, 0xA4, 1])).manufacturerID, 0xA4A8)
        XCTAssertEqual(AdvertisementSnapshot(manufacturerData: Data([0xB5, 0xB5])).manufacturerID, 0xB5B5)
        XCTAssertTrue(AdvertisementSnapshot(manufacturerData: Data([0xA4, 0xA8])).ecoFlowHints(fallbackName: nil).isEmpty)
    }

    func testClassificationWorksWithoutNamesAndDoesNotClaimModel() {
        let manufacturer = AdvertisementSnapshot(manufacturerData: Data([0xB5, 0xB5]))
        XCTAssertEqual(manufacturer.ecoFlowHints(fallbackName: nil).count, 1)
        XCTAssertEqual(AdvertisementSnapshot(serviceUUIDs: ["00000005"]).ecoFlowHints(fallbackName: nil).count, 1)
        XCTAssertEqual(AdvertisementSnapshot(serviceUUIDs: ["6e400001-b5a3-f393-e0a9-e50e24dcca9e"]).ecoFlowHints(fallbackName: nil).count, 1)
        XCTAssertTrue(AdvertisementSnapshot(serviceUUIDs: ["180F"]).ecoFlowHints(fallbackName: "Headphones").isEmpty)
        XCTAssertEqual(AdvertisementSnapshot().ecoFlowHints(fallbackName: "EF-test").count, 1)
    }

    func testAdvertisementMergePreservesMissingFields() {
        var adv = AdvertisementSnapshot(localName: "Original", manufacturerData: Data([0xB5, 0xB5]), serviceUUIDs: ["180F"], serviceData: ["180F": Data([1])], isConnectable: true, transmitPower: -5)
        adv.merge(AdvertisementSnapshot(localName: "", serviceUUIDs: ["180F", "180A"], serviceData: ["180A": Data([2])]))
        XCTAssertEqual(adv.localName, "Original")
        XCTAssertEqual(adv.manufacturerID, 0xB5B5)
        XCTAssertEqual(adv.serviceUUIDs, ["180A", "180F"])
        XCTAssertEqual(adv.serviceData.count, 2)
        XCTAssertEqual(adv.isConnectable, true)
        XCTAssertEqual(adv.transmitPower, -5)
        adv.merge(AdvertisementSnapshot(localName: "Updated", serviceData: ["180F": Data([9])], isConnectable: false))
        XCTAssertEqual(adv.localName, "Updated")
        XCTAssertEqual(adv.serviceData["180F"], Data([9]))
        XCTAssertEqual(adv.isConnectable, false)
    }

    @MainActor
    func testMalformedCoreBluetoothAdvertisementDoesNotCrash() {
        let snapshot = BluetoothManager.advertisement(from: [CBAdvertisementDataManufacturerDataKey: "bad", CBAdvertisementDataServiceUUIDsKey: 42, CBAdvertisementDataIsConnectable: Data()])
        XCTAssertNil(snapshot.manufacturerID)
        XCTAssertTrue(snapshot.serviceUUIDs.isEmpty)
        XCTAssertNil(snapshot.isConnectable)
    }

    @MainActor
    func testCoreBluetoothAdvertisementMetadataIsCaptured() {
        let adv = BluetoothManager.advertisement(from: [
            CBAdvertisementDataLocalNameKey: "Private device name",
            CBAdvertisementDataManufacturerDataKey: Data([0xB5, 0xB5]),
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "180F")],
            CBAdvertisementDataOverflowServiceUUIDsKey: [CBUUID(string: "180A")],
            CBAdvertisementDataSolicitedServiceUUIDsKey: [CBUUID(string: "1810")],
            CBAdvertisementDataServiceDataKey: [CBUUID(string: "180F"): Data([4])],
            CBAdvertisementDataTxPowerLevelKey: NSNumber(value: -8),
            CBAdvertisementDataIsConnectable: NSNumber(value: false)
        ])
        XCTAssertEqual(adv.localName, "Private device name")
        XCTAssertEqual(adv.manufacturerID, 0xB5B5)
        XCTAssertEqual(adv.serviceUUIDs, ["180F"])
        XCTAssertEqual(adv.overflowServiceUUIDs, ["180A"])
        XCTAssertEqual(adv.solicitedServiceUUIDs, ["1810"])
        XCTAssertEqual(adv.serviceData["180F"], Data([4]))
        XCTAssertEqual(adv.transmitPower, -8)
        XCTAssertEqual(adv.isConnectable, false)
    }

    func testUnavailableRSSI() {
        XCTAssertNil(DiscoveredDevice.validRSSI(127))
        XCTAssertNil(DiscoveredDevice.validRSSI(-200))
        XCTAssertEqual(DiscoveredDevice.validRSSI(-64), -64)
        XCTAssertEqual(DiscoveredDevice.validRSSI(0), 0)
    }

    func testDuplicateUUIDsHaveIndependentIdentities() {
        let a = GATTCharacteristic(id: UUID(), uuid: "1234", properties: 2)
        let b = GATTCharacteristic(id: UUID(), uuid: "1234", properties: 16)
        let s1 = GATTService(id: UUID(), uuid: "180F", isPrimary: true, characteristics: [a, b])
        let s2 = GATTService(id: UUID(), uuid: "180F", isPrimary: true)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(s1.id, s2.id)
        XCTAssertEqual(s1.characteristics.count, 2)
    }

    func testPropertiesIncludeEncryptionUnknownBitsAndNoFalseSubscriptions() {
        XCTAssertEqual(GATTCharacteristic.labels(for: 0), ["none"])
        XCTAssertEqual(GATTCharacteristic.labels(for: 0x302), ["read", "notify requires encryption", "indicate requires encryption"])
        XCTAssertEqual(GATTCharacteristic.labels(for: 0x400), ["unknown 0x400"])
        XCTAssertFalse(GATTCharacteristic(id: UUID(), uuid: "1234", properties: 0x0E).supportsSubscription)
        XCTAssertTrue(GATTCharacteristic(id: UUID(), uuid: "1234", properties: 0x100).supportsSubscription)
    }

    func testNoDuplicateOrConcurrentConnectionAttempts() {
        var lifecycle = ConnectionLifecycle()
        let first = UUID(), other = UUID()
        XCTAssertTrue(lifecycle.begin(first))
        XCTAssertFalse(lifecycle.begin(first))
        XCTAssertFalse(lifecycle.begin(other))
        XCTAssertTrue(lifecycle.established(first))
        XCTAssertFalse(lifecycle.begin(first))
        XCTAssertEqual(lifecycle.state, .connected(first))
    }

    func testTimeoutCancellationRejectsLateConnectionAndWaitsForCompletion() {
        var lifecycle = ConnectionLifecycle()
        let id = UUID()
        XCTAssertTrue(lifecycle.begin(id))
        XCTAssertEqual(lifecycle.cancel(), id)
        XCTAssertEqual(lifecycle.state, .disconnecting(id))
        XCTAssertNil(lifecycle.cancel())
        XCTAssertFalse(lifecycle.established(id))
        XCTAssertFalse(lifecycle.begin(UUID()))
        XCTAssertTrue(lifecycle.finished(id))
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testStaleEventsCannotChangeCurrentConnection() {
        var lifecycle = ConnectionLifecycle()
        let old = UUID(), current = UUID()
        XCTAssertTrue(lifecycle.begin(old))
        lifecycle.reset()
        XCTAssertTrue(lifecycle.begin(current))
        XCTAssertFalse(lifecycle.established(old))
        XCTAssertFalse(lifecycle.finished(old))
        XCTAssertEqual(lifecycle.state, .connecting(current))
        lifecycle.reset()
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testLogCapacityAndClear() {
        var log = Diagnostics()
        for i in 0..<1_100 { log.record(.notification, fields: [.count(.bytes, i)]) }
        XCTAssertEqual(log.events.count, 1_000)
        XCTAssertEqual(log.events.first?.fields, [.count(.bytes, 100)])
        log.clear()
        XCTAssertTrue(log.events.isEmpty)
    }

    func testExportOmitsIdentityPayloadAndUntrustedErrorText() {
        let id = UUID()
        let privateName = "Owners private device"
        let packet = "DE AD BE EF"
        let char = GATTCharacteristic(id: UUID(), uuid: "2A19", properties: 16, payloadHex: packet, payloadByteCount: 4)
        let service = GATTService(id: UUID(), uuid: "180F", isPrimary: true, characteristics: [char])
        var log = Diagnostics()
        log.record(.discovered, peripheral: id, fields: [.manufacturer(0xB5B5)])
        log.record(.error, peripheral: id, fields: [.error(domain: privateName, code: 42), .uuid(privateName)])
        let export = log.export(appVersion: "0.1.0", systemVersion: "test", services: [service])
        XCTAssertFalse(export.contains(id.uuidString))
        XCTAssertFalse(export.contains(service.id.uuidString))
        XCTAssertFalse(export.contains(char.id.uuidString))
        XCTAssertFalse(export.contains(privateName))
        XCTAssertFalse(export.contains(packet))
        XCTAssertTrue(export.contains("Device 1"))
        XCTAssertTrue(export.contains("manufacturer=0xB5B5"))
        XCTAssertTrue(export.contains("error=Other/42"))
        XCTAssertTrue(export.contains("0000180F-0000-1000-8000-00805F9B34FB"))
    }

    func testRepeatedEventsRetainUniqueUIIdentities() {
        var log = Diagnostics()
        log.record(.scanStopped)
        log.record(.scanStopped)
        XCTAssertNotEqual(log.events[0].id, log.events[1].id)
    }

    func testPayloadPreviewCapsBytesAndMarksTruncation() {
        let preview = PayloadPreview(Data(repeating: 0xAB, count: 513))
        XCTAssertEqual(preview.byteCount, 513)
        XCTAssertTrue(preview.truncated)
        XCTAssertEqual(preview.hex.split(separator: " ").count, 512)
        XCTAssertFalse(PayloadPreview(Data(repeating: 0, count: 512)).truncated)
        XCTAssertEqual(PayloadPreview(Data()).hex, "")
    }

    @MainActor
    func testManagerStartsIdleWithoutBluetoothAndCannotConnectUnseenDevice() {
        let manager = BluetoothManager()
        XCTAssertEqual(manager.availability, .notStarted)
        XCTAssertTrue(manager.canScan)
        XCTAssertFalse(manager.isScanning)
        XCTAssertFalse(manager.scanRequested)
        manager.connect(to: UUID())
        XCTAssertEqual(manager.connection, .idle)
        XCTAssertTrue(manager.diagnostics.events.isEmpty)
        manager.shutdown()
    }

    func testHexEncoding() { XCTAssertEqual(Data([0, 1, 0xA8, 0xFF]).hex, "00 01 A8 FF") }
}

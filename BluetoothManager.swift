import AppKit
import Combine
import CoreBluetooth

/// Ordinary connections inspect GATT only. Explicit probes have a bounded write path.
@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var availability: BluetoothAvailability = .notStarted
    @Published private(set) var isScanning = false
    @Published private(set) var scanRequested = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var services: [GATTService] = []
    @Published private(set) var discovery: DiscoveryProgress = .notStarted
    @Published private(set) var diagnostics = Diagnostics()
    @Published private(set) var notice: String?
    @Published private(set) var probeStage: ProbeStage?
    @Published private(set) var probeResult: ProbeResult?
    @Published private(set) var probeElapsed: TimeInterval = 0
    @Published private(set) var gattIsStale = false
    @Published private(set) var monitoring = MonitoringPresentation()
    var isProbing: Bool { probeRequested || probe?.isActive == true }
    @Published private var lifecycle = ConnectionLifecycle()
    @Published var ecoFlowOnly = false

    var connection: ConnectionState { lifecycle.state }
    var visibleDevices: [DiscoveredDevice] { devices.filter { !ecoFlowOnly || !$0.hints.isEmpty } }
    var canScan: Bool {
        connection.isIdle && [.notStarted, .unknown, .ready].contains(availability)
    }
    var connectedName: String { devices.first { $0.id == connection.identifier }?.name ?? "Peripheral" }
    var monitoringEnabled: Bool { monitor.enabled }
    var selectedTargetID: UUID? { monitor.targetID }
    private enum ScanMode { case monitoring, diagnostics }
    private var scanMode: ScanMode?
    private var scanGeneration = 0
    private var monitor: MonitoringState
    private let preferences: UserDefaults
    private let now: () -> TimeInterval
    private var activated = false
    private var shuttingDown = false
    private var asleep = false
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceDeadline: TimeInterval?
    private var publicationTask: Task<Void, Never>?
    private var publicationGate = MonitoringPublicationGate()
    private var batteryOutcomes = BatteryOutcomeTracker()

    private var probeRequested = false
    private var requestedProbeKind: ProbeKind = .keyExchange
    private var connectionWasProbe = false
    private var probe: KeyExchangeProbe?
    private var probeTimer: Task<Void, Never>?
    private var probeWrite: CBCharacteristic?
    private var probeNotify: CBCharacteristic?
    private var pendingProbeWriteID: UUID?
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var current: CBPeripheral?
    private var serviceObjects: [UUID: CBService] = [:]
    private var characteristicObjects: [UUID: CBCharacteristic] = [:]
    private var pendingServices: Set<UUID> = []
    private var awaitingServices = false
    private var hadDiscoveryError = false
    private var scanTimer: Task<Void, Never>?
    private var connectionTimer: Task<Void, Never>?
    private var discoveryTimer: Task<Void, Never>?
    private var sleepObserver: AnyCancellable?
    private var wakeObserver: AnyCancellable?

    init(preferences: UserDefaults = .standard, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.preferences = preferences; self.now = now
        monitor = MonitoringState(enabled: preferences.bool(forKey: "monitoringEnabled"),
            targetID: preferences.string(forKey: "selectedPeripheral").flatMap(UUID.init(uuidString:)))
        super.init()
        // Construction is hardware-free. The system permission request is deferred to Scan.
        sleepObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemSleep()
                }
            }
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWake() }
            }
        publishMonitoring()
    }

    func resumeSavedMonitoring() { if monitor.enabled { startMonitoring() } }
    func startMonitoring() {
        guard !shuttingDown else { return }
        let wasActive = activated && monitor.enabled
        activated = true; monitor.setEnabled(true); preferences.set(true, forKey: "monitoringEnabled")
        if !wasActive { diagnostics.record(.monitoringStarted) }; reconcileScanning()
    }
    func pauseMonitoring() {
        guard monitor.enabled else { return }
        monitor.setEnabled(false); preferences.set(false, forKey: "monitoringEnabled")
        diagnostics.record(.monitoringPaused); reconcileScanning()
    }
    func choosePowerBank() {
        monitor.beginChoosing(); publishMonitoring()
        if monitor.enabled { reconcileScanning() } else { startScan() }
    }
    func selectPowerBank(_ id: UUID) {
        guard monitor.select(id, now: now()) else { notice = "Power bank is no longer nearby. Discover devices again."; return }
        preferences.set(id.uuidString, forKey: "selectedPeripheral")
        diagnostics.record(.targetSelected); publishMonitoring(); armMaintenance()
    }
    func forgetPowerBank() {
        monitor.forget(); preferences.removeObject(forKey: "selectedPeripheral")
        batteryOutcomes.clear(); publishMonitoring(); reconcileScanning()
    }
    func diagnosticsClosed() {
        monitor.endChoosing()
        scanRequested = false
        if !connection.isIdle { disconnect() } else { reconcileScanning() }
    }
    func systemSleep() {
        asleep = true; scanRequested = false; monitor.invalidateFreshness()
        diagnostics.record(.sleep)
        if !connection.isIdle { disconnect() }
        reconcileScanning()
    }
    func systemWake() { asleep = false; reconcileScanning() }

    private func publishMonitoring() {
        publicationTask?.cancel(); publicationTask = nil
        monitoring = monitor.presentation(now: now(), availability: availability, asleep: asleep,
            diagnosticBusy: scanRequested || !connection.isIdle)
        if scanMode == .monitoring { devices = monitoring.candidates }
        publicationGate.published(now: now())
    }
    private func queuePublication() {
        guard let deadline = publicationGate.request(now: now()) else { return }
        let delay = max(0, deadline - now())
        publicationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !self.shuttingDown else { return }
            self.publicationTask = nil; self.publishMonitoring()
        }
    }
    private func armMaintenance() {
        guard let deadline = monitor.nextDeadline(now: now()), activated, !shuttingDown else {
            maintenanceTask?.cancel(); maintenanceTask = nil; maintenanceDeadline = nil; return
        }
        // Keep an earlier wake-up rather than creating a timer for every packet.
        if let existing = maintenanceDeadline, existing <= deadline { return }
        maintenanceTask?.cancel(); maintenanceDeadline = deadline
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline - self.now()))) } catch { return }
            guard !self.shuttingDown, self.maintenanceDeadline == deadline else { return }
            self.maintenanceTask = nil; self.maintenanceDeadline = nil
            let previous = self.monitor.targetID
            self.monitor.settle(now: self.now())
            if let id = self.monitor.targetID, id != previous {
                self.preferences.set(id.uuidString, forKey: "selectedPeripheral")
                self.diagnostics.record(.targetSelected)
            }
            self.publishMonitoring(); self.armMaintenance()
        }
    }
    private func recordBatteryOutcome(_ outcome: AdvertisedBatteryOutcome?, id: UUID) {
        guard let outcome, batteryOutcomes.changed(outcome, id: id) else { return }
        diagnostics.record(.advertisedBattery, peripheral: id, fields: [.advertisedBattery(outcome)])
    }

    func startScan() {
        guard canScan, !scanRequested else { return }
        notice = nil
        activated = true; scanRequested = true; monitor.invalidateFreshness()
        reconcileScanning()
    }

    private func reconcileScanning() {
        if !monitor.enabled || asleep || shuttingDown {
            maintenanceTask?.cancel(); maintenanceTask = nil; maintenanceDeadline = nil
        }
        let wanted = activated && !shuttingDown && !asleep && connection.isIdle && (scanRequested || monitor.enabled)
        guard wanted else { stopPhysicalScan(); publishMonitoring(); return }
        if central == nil {
            availability = .unknown
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if central?.state == .poweredOn {
            beginScan()
        }
        publishMonitoring()
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn, connection.isIdle else { return }
        let mode: ScanMode = scanRequested ? .diagnostics : .monitoring
        guard !isScanning || scanMode != mode else { return }
        stopPhysicalScan(); scanMode = mode
        if mode == .diagnostics {
            devices = devices.filter { $0.id == monitor.targetID }
            peripherals = peripherals.filter { $0.key == monitor.targetID }
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: mode == .monitoring])
        isScanning = true
        diagnostics.record(.scanStarted)
        scanTimer?.cancel()
        guard mode == .diagnostics else { return }
        let generation = scanGeneration
        scanTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.scanMode == .diagnostics, self?.scanGeneration == generation else { return }; self?.stopScan()
        }
    }

    func stopScan() {
        scanRequested = false
        reconcileScanning()
    }
    private func stopPhysicalScan() {
        scanGeneration += 1
        scanTimer?.cancel()
        scanTimer = nil
        if isScanning {
            central?.stopScan()
            isScanning = false
            diagnostics.record(.scanStopped)
        }
        scanMode = nil
    }

    func canConnect(_ device: DiscoveredDevice) -> Bool {
        availability == .ready && connection.isIdle && device.advertisement.isConnectable != false
    }

    func connectAndProbe(to id: UUID, kind: ProbeKind = .keyExchange) {
        guard connection.isIdle else { return }
        requestedProbeKind = kind
        connect(to: id, probe: true)
    }

    func connect(to id: UUID, probe requested: Bool = false) {
        guard availability == .ready, let peripheral = peripherals[id],
              let device = devices.first(where: { $0.id == id }), canConnect(device),
              (!requested || device.advertisement.supportsKeyExchangeProbe),
              lifecycle.begin(id) else { return }
        stopScan()
        clearGATT()
        probeRequested = requested
        connectionWasProbe = requested
        probeStage = requested ? .discovering : nil
        if requested { probeResult = nil; probeElapsed = 0 }
        notice = nil
        current = peripheral
        peripheral.delegate = self
        diagnostics.record(.connecting, peripheral: id)
        central?.connect(peripheral, options: nil)
        connectionTimer?.cancel()
        connectionTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.connection == .connecting(id) else { return }
            self.diagnostics.record(.connectionTimeout, severity: .warning, peripheral: id)
            self.notice = "Connection timed out. Cancelling the Bluetooth connection."
            if self.probeRequested { self.failProbe(.stageTimeout) } else { self.disconnect() }
        }
    }

    func disconnect() {
        if let probe, probe.isActive { probe.cancel(); return }
        if probeRequested {
            completeProbe(ProbeResult(outcome: .cancelled, stage: .discovering, elapsed: 0, kind: requestedProbeKind))
            return
        }
        requestDisconnect()
    }

    private func requestDisconnect() {
        guard let peripheral = current, let id = lifecycle.cancel() else { return }
        connectionTimer?.cancel()
        connectionTimer = nil
        discoveryTimer?.cancel()
        discoveryTimer = nil
        invalidateLiveGATT()
        diagnostics.record(.disconnecting, peripheral: id)
        if central?.state == .poweredOn { central?.cancelPeripheralConnection(peripheral) }
    }

    func setSubscription(_ characteristicID: UUID) {
        guard !isProbing, !gattIsStale, connection.isConnected, let peripheral = current,
              let object = characteristicObjects[characteristicID],
              let (s, c) = characteristicIndex(characteristicID),
              services[s].characteristics[c].supportsSubscription,
              !services[s].characteristics[c].subscription.isPending else { return }
        let enable = !object.isNotifying
        services[s].characteristics[c].subscription = enable ? .enabling : .disabling
        if !enable {
            services[s].characteristics[c].payloadHex = nil
            services[s].characteristics[c].payloadByteCount = 0
        }
        // This standard GATT subscription may cause an OS pairing prompt. No
        // proprietary payload or explicit descriptor write is sent by Somnoire.
        peripheral.setNotifyValue(enable, for: object)
    }

    func clearDiagnostics() {
        diagnostics.clear()
        batteryOutcomes.clear()
        for s in services.indices {
            for c in services[s].characteristics.indices {
                services[s].characteristics[c].payloadHex = nil
                services[s].characteristics[c].payloadByteCount = 0
                services[s].characteristics[c].payloadTruncated = false
            }
        }
    }

    func copyDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let text = diagnosticReport(appVersion: version)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Copied diagnostics. Device identities and raw data excluded."
    }

    func diagnosticReport(appVersion: String = "development") -> String {
        diagnostics.export(appVersion: appVersion, systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            services: services, gattIsStale: gattIsStale) + "\n\nMonitoring metrics: accepted advertisements=\(monitor.receipts), coalesced updates=\(publicationGate.coalesced)"
    }

    func shutdown() {
        shuttingDown = true; activated = false; scanRequested = false; stopPhysicalScan()
        publicationTask?.cancel(); publicationTask = nil
        maintenanceTask?.cancel(); maintenanceTask = nil; maintenanceDeadline = nil
        if isProbing { disconnect() }
        probeTimer?.cancel()
        connectionTimer?.cancel()
        discoveryTimer?.cancel()
        if let current { central?.cancelPeripheralConnection(current) }
        resetConnection()
        central?.delegate = nil
        sleepObserver?.cancel()
        wakeObserver?.cancel()
    }

    private func invalidateLiveGATT() {
        discoveryTimer?.cancel()
        discoveryTimer = nil
        serviceObjects.removeAll()
        characteristicObjects.removeAll()
        pendingServices.removeAll()
        awaitingServices = false
        gattIsStale = !services.isEmpty
        for s in services.indices {
            for c in services[s].characteristics.indices {
                services[s].characteristics[c].subscription = .off
                services[s].characteristics[c].payloadHex = nil
                services[s].characteristics[c].payloadByteCount = 0
                services[s].characteristics[c].payloadTruncated = false
            }
        }
        if discovery == .discovering { discovery = .partial }
    }

    private func clearGATT() {
        gattIsStale = false
        discoveryTimer?.cancel()
        discoveryTimer = nil
        services.removeAll()
        serviceObjects.removeAll()
        characteristicObjects.removeAll()
        pendingServices.removeAll()
        awaitingServices = false
        hadDiscoveryError = false
        discovery = .notStarted
    }

    private func resetConnection() {
        connectionTimer?.cancel()
        connectionTimer = nil
        current?.delegate = nil
        current = nil
        lifecycle.reset()
        invalidateLiveGATT()
        reconcileScanning()
    }

    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        current === peripheral && connection.identifier == peripheral.identifier
    }

    private func inspectServices(_ peripheral: CBPeripheral) {
        clearGATT()
        discovery = .discovering
        awaitingServices = true
        peripheral.discoverServices(nil)
        discoveryTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.discovery == .discovering, self.isCurrent(peripheral) else { return }
            self.awaitingServices = false
            self.pendingServices.removeAll()
            self.discovery = self.services.isEmpty ? .failed : .partial
            self.diagnostics.record(.discoveryTimeout, severity: .warning, peripheral: peripheral.identifier)
        }
    }

    private func finishDiscoveryIfReady() {
        guard !awaitingServices, pendingServices.isEmpty else { return }
        discoveryTimer?.cancel()
        discoveryTimer = nil
        discovery = hadDiscoveryError ? .partial : .complete
        prepareProbeGATT()
    }

    private func startProbe() {
        let session = KeyExchangeProbe(kind: requestedProbeKind)
        probe = session
        session.onChange = { [weak self, weak session] in
            guard let self, let session, self.probe === session else { return }
            self.probeStage = session.stage
            self.probeElapsed = session.elapsed
            self.diagnostics.record(.probeStageChanged, peripheral: self.connection.identifier, fields: [.probeStage(session.stage)])
            self.armProbeDeadline(session)
        }
        session.onAction = { [weak self, weak session] action in
            guard let self, let session, self.probe === session else { return }
            self.handleProbe(action)
        }
        diagnostics.record(.probeStarted, peripheral: connection.identifier, fields: [.probeKind(requestedProbeKind)])
        session.start()
    }

    private func armProbeDeadline(_ session: KeyExchangeProbe) {
        probeTimer?.cancel()
        guard let deadline = session.deadline else { probeTimer = nil; return }
        probeTimer = Task { [weak self, weak session] in
            do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) } catch { return }
            guard let self, let session, self.probe === session else { return }
            session.expire()
        }
    }

    private func prepareProbeGATT() {
        guard probeRequested, let probe, probe.stage == .discovering else { return }
        let candidates = serviceObjects.values.filter { canonicalUUID($0.uuid.uuidString) == canonicalUUID("0001") }
        guard candidates.count == 1, let service = candidates.first else { probe.fail(.unsupportedGATT); return }
        let writes = (service.characteristics ?? []).filter { canonicalUUID($0.uuid.uuidString) == canonicalUUID("0002") }
        let notifications = (service.characteristics ?? []).filter { canonicalUUID($0.uuid.uuidString) == canonicalUUID("0003") }
        guard writes.count == 1, notifications.count == 1,
              let write = writes.first, write.properties.contains(.write),
              let notify = notifications.first, notify.properties.contains(.notify) else { probe.fail(.unsupportedGATT); return }
        probeWrite = write; probeNotify = notify
        probe.gattReady()
    }

    private func handleProbe(_ action: ProbeAction) {
        switch action {
        case .subscribe:
            guard connection.isConnected, let peripheral = current, let notify = probeNotify,
                  let id = characteristicObjects.first(where: { $0.value === notify })?.key,
                  let (s, c) = characteristicIndex(id) else { probe?.fail(.unsupportedGATT); return }
            services[s].characteristics[c].subscription = .enabling
            peripheral.setNotifyValue(true, for: notify)
        case .write(let id, let data):
            guard probe?.isActive == true, connection.isConnected, let peripheral = current,
                  let write = probeWrite, write.properties.contains(.write), pendingProbeWriteID == nil,
                  data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else { probe?.fail(.writeRejected); return }
            pendingProbeWriteID = id
            peripheral.writeValue(data, for: write, type: .withResponse)
        case .unrelatedStatus(let length):
            diagnostics.record(.unrelatedStatus, peripheral: connection.identifier, fields: [.count(.bytes, length)])
        case .finished(let result): completeProbe(result)
        }
    }

    private func completeProbe(_ result: ProbeResult) {
        probeResult = result
        probeElapsed = result.elapsed
        probeStage = nil
        notice = nil // The retained result has its own explicitly historical UI.
        diagnostics.record(.probeFinished, severity: {
            if case .failed = result.outcome { return .warning }; return .info
        }(), peripheral: connection.identifier, fields: [.probeStage(result.stage), .probeOutcome(result.outcome), .count(.milliseconds, Int(result.elapsed * 1000))])
        probeTimer?.cancel(); probeTimer = nil
        probe = nil; probeRequested = false
        probeWrite = nil; probeNotify = nil; pendingProbeWriteID = nil
        requestDisconnect()
    }

    private func failProbe(_ failure: ProbeFailure) {
        if let probe, probe.isActive { probe.fail(failure) }
        else if probeRequested { completeProbe(ProbeResult(outcome: .failed(failure), stage: .discovering, elapsed: 0, kind: requestedProbeKind)) }
    }

    private func characteristicIndex(_ id: UUID) -> (Int, Int)? {
        for s in services.indices {
            if let c = services[s].characteristics.firstIndex(where: { $0.id == id }) { return (s, c) }
        }
        return nil
    }

    private func recordError(_ error: Error, kind: DiagnosticKind = .error, peripheral: UUID? = nil) {
        let ns = error as NSError
        let field = DiagnosticField.error(domain: ns.domain, code: ns.code)
        diagnostics.record(kind, severity: .error, peripheral: peripheral, fields: [field])
        notice = "Bluetooth operation failed (\(field.text)). See diagnostics."
    }

    static func advertisement(from data: [String: Any]) -> AdvertisementSnapshot {
        func uuids(_ key: String) -> [String] { (data[key] as? [CBUUID] ?? []).map(\.uuidString).sorted() }
        let serviceData = data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        return AdvertisementSnapshot(
            localName: data[CBAdvertisementDataLocalNameKey] as? String,
            // Preserve the distinction between absent data and a malformed value.
            // Empty Data invalidates a prior battery sample without logging the input.
            manufacturerData: data[CBAdvertisementDataManufacturerDataKey].map { $0 as? Data ?? Data() },
            serviceUUIDs: uuids(CBAdvertisementDataServiceUUIDsKey),
            overflowServiceUUIDs: uuids(CBAdvertisementDataOverflowServiceUUIDsKey),
            solicitedServiceUUIDs: uuids(CBAdvertisementDataSolicitedServiceUUIDsKey),
            serviceData: Dictionary(uniqueKeysWithValues: serviceData.map { ($0.key.uuidString, $0.value) }),
            isConnectable: (data[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
            transmitPower: (data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        )
    }
}

// CoreBluetooth guarantees delegate delivery on the central's selected main queue.
// These conformances bridge its Objective-C, nonisolated delegate declarations;
// no CoreBluetooth reference crosses an actor or enters a detached task.
extension BluetoothManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        switch central.state {
        case .poweredOn: availability = .ready
        case .poweredOff: availability = .poweredOff
        case .resetting: availability = .resetting
        case .unsupported: availability = .unsupported
        case .unauthorized:
            availability = CBManager.authorization == .restricted ? .restricted : .denied
        case .unknown: availability = .unknown
        @unknown default: availability = .unknown
        }
        diagnostics.record(.bluetooth, fields: [.availability(availability)])
        if central.state == .poweredOn {
            reconcileScanning()
        } else if central.state != .unknown || connection.identifier != nil || isScanning {
            let oldID = connection.identifier
            scanRequested = false; stopPhysicalScan(); monitor.invalidateFreshness()
            if let oldID { diagnostics.record(.disconnected, severity: .warning, peripheral: oldID) }
            failProbe(.bluetoothUnavailable)
            resetConnection()
            peripherals.removeAll()
            devices.removeAll()
            publishMonitoring()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central, isScanning, connection.isIdle else { return }
        let id = peripheral.identifier
        if scanMode == .monitoring {
            if let target = monitor.targetID, !monitor.choosing, target != id { return }
            if monitor.candidates[id] == nil && monitor.targetID != id {
                let profile = AdvertisementSnapshot(manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
                guard profile.matchesObservedRapidProProfile else { return }
            }
        }
        let update = Self.advertisement(from: advertisementData)
        if scanMode == .monitoring {
            guard monitor.receive(id: id, advertisement: update, name: peripheral.name,
                rssi: DiscoveredDevice.validRSSI(RSSI.intValue), observedAt: Date(), now: now()) else { return }
            peripherals = peripherals.filter { monitor.candidates[$0.key] != nil }
            peripherals[id] = peripheral
            if update.manufacturerData != nil {
                let outcome: AdvertisedBatteryOutcome = !update.matchesObservedRapidProProfile ? .unsupportedProfile :
                    (AdvertisedBatteryReading.decode(update, observedAt: Date()) == nil ? .invalidValue : .decoded)
                recordBatteryOutcome(outcome, id: id)
            }
            queuePublication(); armMaintenance(); return
        }
        // Explicit diagnostic scans retain the original bounded discovery behavior.
        if monitor.receive(id: id, advertisement: update, name: peripheral.name,
            rssi: DiscoveredDevice.validRSSI(RSSI.intValue), observedAt: Date(), now: now()) {
            queuePublication(); armMaintenance()
        }
        let oldIndex = devices.firstIndex { $0.id == id }
        // A scan is bounded in duration and retained peripheral count.
        guard oldIndex != nil || devices.count < 500 else { return }
        peripherals[id] = peripheral
        var changed = true
        var batteryOutcome: AdvertisedBatteryOutcome?
        if let i = oldIndex {
            let before = devices[i].advertisement
            batteryOutcome = devices[i].updateAdvertisement(update, observedAt: Date())
            devices[i].peripheralName = peripheral.name ?? devices[i].peripheralName
            devices[i].rssi = DiscoveredDevice.validRSSI(RSSI.intValue)
            changed = before != devices[i].advertisement
        } else {
            var device = DiscoveredDevice(id: id, peripheralName: peripheral.name, rssi: DiscoveredDevice.validRSSI(RSSI.intValue), advertisement: AdvertisementSnapshot())
            batteryOutcome = device.updateAdvertisement(update, observedAt: Date())
            devices.append(device)
        }
        if let batteryOutcome, update.manufacturerID == 0xB5B5 || oldIndex.map({ !devices[$0].hints.isEmpty }) == true {
            recordBatteryOutcome(batteryOutcome, id: id)
        }
        devices.sort {
            if $0.rssi == $1.rssi { return $0.id.uuidString < $1.id.uuidString }
            return ($0.rssi ?? Int.min) > ($1.rssi ?? Int.min)
        }
        guard changed else { return }
        var fields: [DiagnosticField] = [.count(.advertisedServices, update.serviceUUIDs.count + update.overflowServiceUUIDs.count), .count(.serviceDataEntries, update.serviceData.count)]
        if let mfr = update.manufacturerID { fields.append(.manufacturer(mfr)) }
        if let rssi = DiscoveredDevice.validRSSI(RSSI.intValue) { fields.append(.rssi(rssi)) }
        if let connectable = update.isConnectable { fields.append(.connectable(connectable)) }
        if let tx = update.transmitPower { fields.append(.transmitPower(tx)) }
        fields += (update.serviceUUIDs + update.overflowServiceUUIDs + update.solicitedServiceUUIDs).map { .uuid($0) }
        diagnostics.record(oldIndex == nil ? .discovered : .advertisement, peripheral: id, fields: fields)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central else { return }
        guard isCurrent(peripheral), lifecycle.established(peripheral.identifier) else {
            // Cancellation can race with a successful link establishment.
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectionTimer?.cancel()
        connectionTimer = nil
        diagnostics.record(.connected, peripheral: peripheral.identifier)
        if probeRequested { startProbe() }
        inspectServices(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, isCurrent(peripheral), lifecycle.finished(peripheral.identifier) else { return }
        failProbe(.disconnected)
        diagnostics.record(.connectionFailed, severity: error == nil ? .info : .error, peripheral: peripheral.identifier)
        if let error { recordError(error, peripheral: peripheral.identifier) }
        resetConnection()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, isCurrent(peripheral), lifecycle.finished(peripheral.identifier) else { return }
        failProbe(.disconnected)
        diagnostics.record(.disconnected, peripheral: peripheral.identifier)
        if let error {
            recordError(error, peripheral: peripheral.identifier)
            if !connectionWasProbe && (error as NSError).domain == CBErrorDomain && (error as NSError).code == CBError.peripheralDisconnected.rawValue {
                notice = "Peripheral disconnected. Ordinary Connect inspects GATT only; the device may require a session before keeping the link open."
            }
        }
        resetConnection()
    }
}

extension BluetoothManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(peripheral), connection.isConnected, awaitingServices else { return }
        awaitingServices = false
        if let error {
            recordError(error, kind: .discoveryFailed, peripheral: peripheral.identifier)
            discovery = .failed
            failProbe(.unsupportedGATT)
            discoveryTimer?.cancel()
            discoveryTimer = nil
            return
        }
        let found = peripheral.services ?? []
        diagnostics.record(.services, peripheral: peripheral.identifier, fields: [.count(.services, found.count)])
        for object in found {
            let id = UUID()
            services.append(GATTService(id: id, uuid: object.uuid.uuidString, isPrimary: object.isPrimary))
            serviceObjects[id] = object
            pendingServices.insert(id)
            diagnostics.record(.service, peripheral: peripheral.identifier, fields: [.uuid(object.uuid.uuidString)])
        }
        // Populate all pending IDs before requesting callbacks.
        for object in found { peripheral.discoverCharacteristics(nil, for: object) }
        finishDiscoveryIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(peripheral), connection.isConnected,
              let id = serviceObjects.first(where: { $0.value === service })?.key,
              pendingServices.remove(id) != nil,
              let index = services.firstIndex(where: { $0.id == id }) else { return }
        if let error {
            hadDiscoveryError = true
            services[index].discoveryFailed = true
            recordError(error, kind: .discoveryFailed, peripheral: peripheral.identifier)
        } else {
            for object in service.characteristics ?? [] {
                let characteristic = GATTCharacteristic(id: UUID(), uuid: object.uuid.uuidString, properties: object.properties.rawValue)
                services[index].characteristics.append(characteristic)
                characteristicObjects[characteristic.id] = object
                diagnostics.record(.characteristic, peripheral: peripheral.identifier, fields: [.uuid(object.uuid.uuidString), .properties(object.properties.rawValue)])
            }
        }
        finishDiscoveryIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard isCurrent(peripheral), connection.isConnected else { return }
        if isProbing { failProbe(.servicesChanged); return }
        diagnostics.record(.invalidated, peripheral: peripheral.identifier, fields: [.count(.services, invalidatedServices.count)])
        // Unsubscribe surviving characteristics before discarding their references.
        for characteristic in characteristicObjects.values where characteristic.isNotifying {
            if !invalidatedServices.contains(where: { $0 === characteristic.service }) {
                peripheral.setNotifyValue(false, for: characteristic)
            }
        }
        inspectServices(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), connection.isConnected,
              let id = characteristicObjects.first(where: { $0.value === characteristic })?.key,
              let (s, c) = characteristicIndex(id) else { return }
        if let error {
            services[s].characteristics[c].subscription = characteristic.isNotifying ? .on : .failed
            recordError(error, peripheral: peripheral.identifier)
        } else {
            services[s].characteristics[c].subscription = characteristic.isNotifying ? .on : .off
        }
        diagnostics.record(.subscription, peripheral: peripheral.identifier, fields: [.uuid(characteristic.uuid.uuidString), .subscribed(characteristic.isNotifying)])
        if !characteristic.isNotifying { services[s].characteristics[c].payloadHex = nil }
        if characteristic === probeNotify { probe?.subscribed(success: error == nil && characteristic.isNotifying) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), connection.isConnected, characteristic === probeWrite,
              let id = pendingProbeWriteID else { return }
        pendingProbeWriteID = nil
        if let error { recordError(error, peripheral: peripheral.identifier) }
        probe?.writeCompleted(id, success: error == nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), connection.isConnected,
              let id = characteristicObjects.first(where: { $0.value === characteristic })?.key,
              let (s, c) = characteristicIndex(id),
              services[s].characteristics[c].subscription == .on else { return }
        if probeRequested {
            if characteristic === probeNotify {
                if error != nil { failProbe(.disconnected) }
                else if let value = characteristic.value {
                    diagnostics.record(.notification, peripheral: peripheral.identifier, fields: [.count(.bytes, value.count)])
                    probe?.receive(value)
                }
            }
            return
        }
        if let error { recordError(error, peripheral: peripheral.identifier); return }
        guard let value = characteristic.value else { return }
        diagnostics.record(.notification, peripheral: peripheral.identifier, fields: [.uuid(characteristic.uuid.uuidString), .count(.bytes, value.count)])
        // Opaque, volatile inspection only. Never forwarded into the event log,
        // persisted, decoded, or included in Copy Diagnostics.
        let preview = PayloadPreview(value)
        services[s].characteristics[c].payloadHex = preview.hex
        services[s].characteristics[c].payloadByteCount = preview.byteCount
        services[s].characteristics[c].payloadTruncated = preview.truncated
    }
}

import Foundation

/// Hardware-free monitoring policy. Times here are monotonic; Date is display-only.
struct MonitoringState {
    private(set) var enabled: Bool
    private(set) var targetID: UUID?
    private(set) var candidates: [UUID: DiscoveredDevice] = [:]
    private(set) var choosing = false
    private(set) var associationDeadline: TimeInterval?
    private(set) var lastBatteryAt: TimeInterval?
    private(set) var receipts: Int = 0
    private var lastSeen: [UUID: TimeInterval] = [:]
    private var batteryTimes: [UUID: TimeInterval] = [:]

    init(enabled: Bool = false, targetID: UUID? = nil) {
        self.enabled = enabled; self.targetID = targetID
    }
    mutating func setEnabled(_ value: Bool) { enabled = value; if !value { invalidateFreshness() } }
    mutating func invalidateFreshness() { lastBatteryAt = nil; associationDeadline = nil }
    mutating func beginChoosing() { choosing = true; associationDeadline = nil }
    mutating func select(_ id: UUID, now: TimeInterval) -> Bool {
        guard candidates[id]?.advertisement.matchesObservedRapidProProfile == true,
              let seen = lastSeen[id], now - seen < 30 else { return false }
        targetID = id; choosing = false; associationDeadline = nil
        candidates = candidates.filter { $0.key == id }
        lastSeen = lastSeen.filter { $0.key == id }; batteryTimes = batteryTimes.filter { $0.key == id }
        lastBatteryAt = batteryTimes[id]
        return true
    }
    mutating func endChoosing() {
        guard let id = targetID else { return }
        choosing = false; candidates = candidates.filter { $0.key == id }
        lastSeen = lastSeen.filter { $0.key == id }; batteryTimes = batteryTimes.filter { $0.key == id }
    }
    mutating func forget() {
        targetID = nil; candidates.removeAll(); lastSeen.removeAll(); batteryTimes.removeAll()
        associationDeadline = nil; lastBatteryAt = nil; choosing = false
    }
    mutating func receive(id: UUID, advertisement: AdvertisementSnapshot, name: String?, rssi: Int?, observedAt: Date, now: TimeInterval) -> Bool {
        for old in candidates.keys.filter({ $0 != targetID && now - (lastSeen[$0] ?? -.infinity) >= 30 }) {
            candidates[old] = nil; lastSeen[old] = nil; batteryTimes[old] = nil
        }
        guard targetID == nil || targetID == id || choosing else { return false }
        guard advertisement.matchesObservedRapidProProfile || candidates[id] != nil || targetID == id else { return false }
        guard candidates[id] != nil || candidates.count < 8 else { return false }
        var device = candidates[id] ?? DiscoveredDevice(id: id, advertisement: AdvertisementSnapshot())
        device.updateAdvertisement(advertisement, observedAt: observedAt)
        device.peripheralName = name ?? device.peripheralName; device.rssi = rssi
        candidates[id] = device; lastSeen[id] = now; receipts += 1
        if advertisement.manufacturerData != nil {
            batteryTimes[id] = device.advertisedBattery == nil ? nil : now
            if targetID == id { lastBatteryAt = batteryTimes[id] }
        }
        if enabled && targetID == nil && !choosing && associationDeadline == nil { associationDeadline = now + 3 }
        return true
    }
    mutating func settle(now: TimeInterval) {
        guard let deadline = associationDeadline, now >= deadline else { return }
        associationDeadline = nil
        let eligible = candidates.values.filter { $0.advertisement.matchesObservedRapidProProfile && now - (lastSeen[$0.id] ?? -.infinity) < 30 }
        if eligible.count == 1 { _ = select(eligible[0].id, now: now) }
        else if eligible.count > 1 { choosing = true }
    }
    func nextDeadline(now: TimeInterval) -> TimeInterval? {
        [associationDeadline, lastBatteryAt.map { $0 + 30 }].compactMap { $0 }.filter { $0 > now }.min()
    }
    func presentation(now: TimeInterval, availability: BluetoothAvailability, asleep: Bool, diagnosticBusy: Bool) -> MonitoringPresentation {
        let device = targetID.flatMap { candidates[$0] }
        let reading = device?.visibleBatteryReading()
        let active = enabled && !asleep && !diagnosticBusy && availability == .ready
        let fresh = active && lastBatteryAt.map { now - $0 < 30 } == true && reading != nil
        let status: String
        if !enabled { status = "Paused" }
        else if asleep { status = "Paused during sleep" }
        else if availability != .ready { status = availability.rawValue }
        else if diagnosticBusy { status = "Monitoring paused for diagnostics" }
        else if choosing { status = "Choose a power bank" }
        else { status = fresh ? "Nearby · Monitoring" : "Searching for power bank…" }
        return MonitoringPresentation(name: device?.name ?? "EcoFlow RAPID Pro", percentage: fresh ? reading?.percentage : nil,
            lastReading: reading, status: status, candidates: candidates.values.sorted { $0.id.uuidString < $1.id.uuidString }, receipts: receipts)
    }
}

struct MonitoringPresentation {
    var name = "EcoFlow RAPID Pro"
    var percentage: Int?
    var lastReading: AdvertisedBatteryReading?
    var status = "Paused"
    var candidates: [DiscoveredDevice] = []
    var receipts = 0
    var menuBarText: String { percentage.map { "\($0)%" } ?? "—" }
    var batteryText: String {
        if let percentage { return "Battery \(percentage)%" }
        if let lastReading { return "Last reported \(lastReading.percentage)% · stale" }
        return "Battery unavailable"
    }
    var accessibilityLabel: String { "Somnoire, power bank, \(batteryText), \(status)" }
}

struct MonitoringPublicationGate {
    private(set) var lastPublished: TimeInterval = -.infinity
    private(set) var deadline: TimeInterval?
    private(set) var coalesced = 0
    mutating func request(now: TimeInterval) -> TimeInterval? {
        guard deadline == nil else { coalesced += 1; return nil }
        let next = max(now, lastPublished + 1); deadline = next; return next
    }
    mutating func published(now: TimeInterval) { lastPublished = now; deadline = nil }
}

struct BatteryOutcomeTracker {
    private var outcomes: [UUID: AdvertisedBatteryOutcome] = [:]
    mutating func changed(_ outcome: AdvertisedBatteryOutcome, id: UUID) -> Bool {
        guard outcomes[id] != outcome else { return false }
        if outcomes.count >= 500 { outcomes.removeAll() }
        outcomes[id] = outcome; return true
    }
    mutating func clear() { outcomes.removeAll() }
}

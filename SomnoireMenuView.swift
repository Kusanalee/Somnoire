import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import ServiceManagement

struct SomnoireStatusLabel: View {
    @ObservedObject var bluetooth: BluetoothManager
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.stars")
            Text(bluetooth.monitoring.menuBarText).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bluetooth.monitoring.accessibilityLabel)
    }
}

struct SomnoireMenuView: View {
    @ObservedObject var bluetooth: BluetoothManager
    var openDiagnostics: () -> Void = {}
    var openSettings: () -> Void = {}
    @State private var accountID = ""
    private let ports: [(String, P512ProtocolPort)] = [("C1", .usbC1), ("C2", .usbC2), ("C3", .usbC3), ("C4", .usbC4)]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                card("BATTERY", icon: "battery.100") {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(bluetooth.monitoring.lastReading.map { "\($0.percentage)%" } ?? "—")
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                            if bluetooth.monitoring.percentage == nil, let reading = bluetooth.monitoring.lastReading {
                                Text("Last updated \(Int(max(0, context.date.timeIntervalSince(reading.observedAt))))s ago").font(.caption).foregroundStyle(.secondary)
                            }

                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 10) {
                            ForEach([BatteryInformation.Metric.input, .output], id: \.self) { metric in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(metric.label).font(.caption).foregroundStyle(.secondary)
                                    Text(bluetooth.batteryInformation.power(metric, at: context.date).map { String(format: "%.1f W", $0) } ?? "— W")
                                        .font(.headline).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(ports, id: \.0) { name, port in
                        let watts = fresh(port, "W", at: context.date)
                        card(name, icon: "cable.connector") {
                            Text(watts.map { String(format: "%.1fW", abs($0)) } ?? "— W")
                                .font(.system(size: 28, weight: .bold, design: .rounded)).minimumScaleFactor(0.7)
                            Text("\(format(fresh(port, "V", at: context.date), "V")) / \(format(fresh(port, "A", at: context.date), "A"))")
                                .font(.caption).monospacedDigit()
                            Text(watts.map { $0 > 0 ? "Input" : $0 < 0 ? "Output" : "Idle" } ?? "No recent data")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }.help("Direction follows the app convention. Output mapping verified; input comparison pending.")
                    }
                }
                BatteryInformationSection(information: bluetooth.batteryInformation, date: context.date, active: bluetooth.liveStatus == .live)
                Button("Settings…", action: openSettings)
                Text(bluetooth.liveStatus.label).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !bluetooth.hasLiveCredential {
                    Button("Set Up Power Bank…", action: openSettings)
                } else if bluetooth.liveStatus != .live && !bluetooth.isProbing {
                    Button("Retry") { bluetooth.startLive() }
                }
                Divider()
                HStack {
                    Button("Quit") { bluetooth.shutdown(); NSApplication.shared.terminate(nil) }
                    Spacer()
                    Menu {
                        Button("Settings…", action: openSettings)
                        Toggle("Monitor Battery", isOn: Binding(get: { bluetooth.monitoringEnabled }, set: {
                            if $0 { bluetooth.startMonitoring() } else { bluetooth.pauseMonitoring() }
                        }))
                        Button("Choose Power Bank…") { bluetooth.panelVisibility(false); bluetooth.choosePowerBank(); openSettings() }
                        Button("Forget Power Bank") { bluetooth.forgetPowerBank() }
                        Button("Diagnostics…") { bluetooth.panelVisibility(false); openDiagnostics() }
                    } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).frame(width: 28)
                        .accessibilityLabel("Settings")
                }
            }
            .padding(12).frame(width: 328).background(.ultraThinMaterial)
        }
        .background(PanelVisibilityObserver { visible in
            if !visible { accountID = "" }
            bluetooth.panelVisibility(visible)
        }.frame(width: 0, height: 0))
    }
    private func fresh(_ port: P512ProtocolPort, _ key: String, at date: Date) -> Float? {
        return bluetooth.liveReadings[port]?[key]?.fresh(at: date)
    }
    private func format(_ value: Float?, _ unit: String) -> String {
        value.map { String(format: "%.1f %@", $0, unit) } ?? "— \(unit)"
    }
    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, minHeight: 94, alignment: .leading).modifier(DashboardCardStyle())
    }
}

struct BatteryInformationSection: View {
    let information: BatteryInformation
    let date: Date
    var active = false
    @State var expanded = false
    @AppStorage("energyDisplayUnit") private var energyUnit = "Auto"
    @AppStorage("temperatureDisplayUnit") private var temperatureUnit = "°C"
    var body: some View {
        DisclosureGroup("Battery Information", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !active, let latest = information.samples.values.map(\.reportedAt).max() {
                    Text("Last updated \(Int(max(0, date.timeIntervalSince(latest))))s ago").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach([BatteryInformation.Metric.health, .cycles, .temperature, .energyIn, .energyOut], id: \.self) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(metric.label)
                            Spacer()
                            Text(formatted(metric)).monospacedDigit()
                        }.font(.caption)

                    }
                }
                Menu {
                    ForEach(["Auto", "Wh", "kWh"], id: \.self) { unit in
                        Button(unit) { energyUnit = unit }
                    }
                } label: { Text("Energy: \(energyUnit)") }
                    .menuStyle(.borderlessButton).fixedSize()
                Menu {
                    ForEach(["°C", "°F"], id: \.self) { unit in
                        Button(unit) { temperatureUnit = unit }
                    }
                } label: { Text("Temperature: \(temperatureUnit)") }
                    .menuStyle(.borderlessButton).fixedSize()
            }.padding(.top, 6)
        }.font(.caption).modifier(DashboardCardStyle())
    }
    private func formatted(_ metric: BatteryInformation.Metric) -> String {
        guard let value = information.samples[metric]?.value else { return "Unavailable" }
        switch metric {
        case .health: return String(format: "%.1f%%", value)
        case .cycles: return String(format: "%.0f", value)
        case .temperature: return BatteryInformation.temperature(value, unit: temperatureUnit)
        case .energyIn, .energyOut: return BatteryInformation.energy(value, unit: energyUnit)
        default: return "Unavailable"
        }
    }
}

struct DashboardCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}
struct HealthyChargingSection: View {
    @ObservedObject var bluetooth: BluetoothManager
    var editing = false
    var baseline = HealthySettings()
    var draft = HealthySettings()
    var expanded = false
    var body: some View { ChargingPane(bluetooth: bluetooth) }
}
struct ChargingPane: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var draft = SettingsDraft<HealthySettings>()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Healthy Charging") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Healthy Charging", isOn: Binding(get: { draft.value?.mode == 1 }, set: { enabled in
                        var value = draft.value ?? bluetooth.healthySettings; value.mode = enabled ? 1 : 2
                        if !enabled { value.ceiling = draft.baseline?.ceiling; value.floor = draft.baseline?.floor }
                        draft.edit(value)
                    })).toggleStyle(.switch)
                    chargingSlider("Charge Limit", floor: false, range: 80...100)
                    chargingSlider("Discharge Reserve", floor: true, range: 0...20)
                    Text("Stops discharging at the reserve level.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(!bluetooth.healthySettings.valid || bluetooth.settingsBusy)
            if !bluetooth.healthySettings.valid { Text("Connect to read recognized charging settings.").foregroundStyle(.secondary) }
            paneActions(phase: bluetooth.panePhases[.charging] ?? draft.phase)
        }
        .onAppear { draft.sync(bluetooth.healthySettings) }
        .onChange(of: bluetooth.healthySettings) { value in if !bluetooth.settingsBusy { draft.sync(value) } }
        .onChange(of: bluetooth.panePhases[.charging]) { value in if value == .applied { draft.revert(bluetooth.healthySettings); draft.phase = .applied } }
    }
    private func chargingSlider(_ title: String, floor: Bool, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let value = floor ? draft.value?.floor : draft.value?.ceiling
            HStack { Text(title); Spacer(); Text(value.map { "\($0)%" } ?? "Unavailable").monospacedDigit() }
            Slider(value: Binding(get: { Double(value ?? UInt32(range.lowerBound)) }, set: { new in
                var next = draft.value ?? bluetooth.healthySettings
                if floor { next.floor = UInt32(new) } else { next.ceiling = UInt32(new) }
                draft.edit(next)
            }), in: range, step: 5).disabled(draft.value?.mode != 1).accessibilityLabel(title)
            HStack { ForEach(stride(from: Int(range.lowerBound), through: Int(range.upperBound), by: 5).map { $0 }, id: \.self) { tick in
                Text("\(tick)%").font(.caption2); if tick != Int(range.upperBound) { Spacer() }
            } }
        }
    }
    private func paneActions(phase: PanePhase) -> some View {
        HStack {
            Text(paneFeedback(local: draft.phase, dirty: draft.dirty, transaction: phase).message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Revert") { draft.revert(bluetooth.healthySettings) }.disabled(!draft.dirty || bluetooth.settingsBusy)
            Button("Apply") { if let value = draft.value, let baseline = draft.baseline { bluetooth.applyChargingPane(value, baseline: baseline) } }
                .disabled(!draft.dirty || draft.phase == .conflict || !bluetooth.canEditHealthy || bluetooth.settingsBusy)
        }
    }
}
struct ScreenPane: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var draft = SettingsDraft<[ScreenField: UInt32]>()
    @State private var artwork = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsGroup("Display", [.duration, .brightness])
            settingsGroup("Clock", [.clockEnabled, .clockFormat, .clockDuration, .chargingClockDuration])
            settingsGroup("Screen Art", [.artEnabled, .artDuration])
            Button("Customize artwork…") { artwork = true }
                .sheet(isPresented: $artwork) {
                    VStack { ArtworkEditor(); HStack { Spacer(); Button("Done") { artwork = false } } }.padding().frame(width: 580)
                }
            HStack {
                Text(paneFeedback(local: draft.phase, dirty: draft.dirty, transaction: bluetooth.panePhases[.screen]).message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { draft.revert(bluetooth.screenSettings) }.disabled(!draft.dirty || bluetooth.settingsBusy)
                Button("Apply") { if let value = draft.value, let baseline = draft.baseline { bluetooth.applyScreenPane(value, baseline: baseline) } }
                    .disabled(!draft.dirty || draft.phase == .conflict || !bluetooth.canEditScreen || bluetooth.settingsBusy)
            }
        }
        .onAppear { draft.sync(bluetooth.screenSettings) }
        .onChange(of: bluetooth.screenSettings) { value in if !bluetooth.settingsBusy { draft.sync(value) } }
        .onChange(of: bluetooth.panePhases[.screen]) { value in if value == .applied { draft.revert(bluetooth.screenSettings); draft.phase = .applied } }
    }
    private func settingsGroup(_ title: String, _ fields: [ScreenField]) -> some View {
        GroupBox(title) {
            VStack(spacing: 10) { ForEach(fields, id: \.self) { field in
                HStack {
                    Text(field.label).frame(width: 205, alignment: .leading)
                    Spacer(minLength: 8)
                    if let value = draft.value?[field], field.accepts(value) {
                        if field == .brightness {
                            Image(systemName: "sun.min")
                            Slider(value: Binding(get: { Double(value) }, set: { update(field, UInt32($0)) }), in: 0...100, step: 1).accessibilityLabel("Brightness")
                            Image(systemName: "sun.max")
                            Text("\(value)%").monospacedDigit().frame(width: 38)
                        } else if field == .artEnabled || field == .clockEnabled {
                            Toggle(field.label, isOn: Binding(get: { value == 1 }, set: { update(field, $0 ? 1 : 2) })).labelsHidden().toggleStyle(.switch)
                        } else {
                            Picker(field.label, selection: Binding(get: { value }, set: { update(field, $0) })) {
                                ForEach(field == .clockFormat ? [UInt32(1),2] : ScreenField.durations + (field == .chargingClockDuration ? [UInt32.max] : []), id: \.self) { Text(field.text($0)).tag($0) }
                            }.labelsHidden().frame(maxWidth: 190)
                        }
                    } else { Text("Unavailable").foregroundStyle(.secondary) }
                }
            } }.padding(8).disabled(!bluetooth.canEditScreen || bluetooth.settingsBusy)
        }
    }
    private func update(_ field: ScreenField, _ value: UInt32) { var next = draft.value ?? [:]; next[field] = value; draft.edit(next) }
}

private struct PanelVisibilityObserver: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(changed: changed) }
    func updateNSView(_ view: ObserverView, context: Context) { view.changed = changed }
    final class ObserverView: NSView {
        var changed: (Bool) -> Void
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { changed(false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
            }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window else { return }; self?.changed(window.isVisible && window.isKeyWindow)
            }
        }
        @objc private func visibilityChanged(_ note: Notification) {
            guard let window else { changed(false); return }
            changed(note.name != NSWindow.willCloseNotification && window.isVisible && window.occlusionState.contains(.visible))
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct SomnoireDiagnosticsView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var accountID = ""
    private var validAccountID: Bool {
        !accountID.isEmpty && accountID.utf8.count <= 32 && accountID.utf8.allSatisfy { (48...57).contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Somnoire", systemImage: "moon.stars").font(.headline)
                Spacer()
                Text("Diagnostics").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(bluetooth.availability.rawValue).font(.callout)
                    if let notice = bluetooth.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(bluetooth.scanRequested ? "Stop Discovery" : "Discover Devices") {
                            if bluetooth.scanRequested { bluetooth.stopScan() } else { bluetooth.startScan() }
                        }
                        .disabled(!bluetooth.scanRequested && !bluetooth.canScan)
                        if bluetooth.scanRequested { Text("Diagnostic discovery · up to 30 seconds").font(.caption).foregroundStyle(.secondary) }
                    }
                    Toggle("Only possible EcoFlow devices", isOn: $bluetooth.ecoFlowOnly)
                        .font(.caption)
                    Divider()
                    if !bluetooth.monitoring.candidates.isEmpty {
                        Text("Power Bank Selection").font(.subheadline.weight(.semibold))
                        ForEach(bluetooth.monitoring.candidates) { device in
                            HStack {
                                Text(device.name)
                                Spacer()
                                Button(device.id == bluetooth.selectedTargetID ? "Selected" : "Use This Power Bank") {
                                    bluetooth.selectPowerBank(device.id)
                                }.disabled(device.id == bluetooth.selectedTargetID)
                            }
                        }
                    }
                    Text("Accepted monitoring advertisements: \(bluetooth.monitoring.receipts)")
                        .font(.caption).foregroundStyle(.secondary)
                    connectionSection
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Authenticated telemetry experiment").font(.caption.weight(.semibold))
                        SecureField("Numeric EcoFlow authorizing account ID", text: $accountID)
                            .textFieldStyle(.roundedBorder)
                            .disabled(bluetooth.isProbing)
                            .accessibilityIdentifier("experimentalAccountID")
                        Text(validAccountID ? "ID ready for a local credential check." :
                            accountID.isEmpty ? "Paste the numeric account ID above." : "ID not ready: use 1–32 digits, with no spaces or other text.")
                            .font(.caption2)
                            .foregroundStyle(validAccountID ? Color.primary : Color.secondary)
                        Text("Used once for a local credential check. Cleared when a probe starts or this window closes. Enter the account ID, never your password.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Link("Account ID setup guide", destination: URL(string: "https://github.com/rabits/ha-ef-ble/wiki#finding-user-id-manually")!)
                            .font(.caption2)
                    }
                    if let stage = bluetooth.probeStage {
                        Text("Experimental probe · \(stage.rawValue)").font(.caption)
                        Button("Cancel Probe") { bluetooth.disconnect() }
                    }
                    if let result = bluetooth.probeResult {
                        Text("Previous probe · \(result.kind.rawValue)").font(.caption.weight(.semibold))
                        Text(result.outcome.label).font(.caption)
                        Text(String(format: "Last probe: %.2f seconds", result.elapsed)).font(.caption2).foregroundStyle(.secondary)
                        if result.kind == .telemetryAccess {
                            Text("Other validated packets observed: \(result.observedPacketCount). Packet headers alone do not verify port power.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let access = result.access {
                            Text(access.authentication.label).font(.caption2).foregroundStyle(.secondary)
                            Text("One-shot report requested: \(access.reportRequestIssued ? "yes" : "no") · reply received: \(access.reportReplyReceived ? "yes" : "no")")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("Decoded packets: \(access.decodedPackets) · candidate port-power updates: \(access.portPowerUpdates)")
                                .font(.caption2).foregroundStyle(.secondary)
                            if result.kind == .authenticatedAccess {
                                Text("Credential check: \(access.credentialCheckIssued ? (access.credentialAccepted.map { $0 ? "accepted" : "rejected" } ?? "no validated result") : "not sent")")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let delta = access.latestDelta {
                                    experimentalMeasurements(delta)
                                }
                            }
                        }
                    }
                    Divider()
                    Text("Nearby devices (\(bluetooth.visibleDevices.count))").font(.subheadline.weight(.semibold))
                    if bluetooth.visibleDevices.isEmpty {
                        Text(bluetooth.ecoFlowOnly ? "No matching devices. Turn off the filter to inspect all peripherals." : "Click Scan with your power bank awake and nearby.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(bluetooth.visibleDevices) { device in deviceRow(device) }
                    Divider()
                    Text("GATT inspection").font(.subheadline.weight(.semibold))
                    if bluetooth.gattIsStale { Text("Last GATT snapshot · disconnected / stale").font(.caption).foregroundStyle(.secondary) }
                    Text(bluetooth.discovery.label).font(.caption).foregroundStyle(.secondary)
                    if bluetooth.discovery == .complete && bluetooth.services.isEmpty {
                        Text("The peripheral exposed no services.").font(.caption)
                    }
                    ForEach(bluetooth.services) { service in serviceRow(service) }
                    Divider()
                    diagnosticsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            // Keep a usable ideal height while allowing the utility window to resize.
            .frame(minHeight: 360, idealHeight: 480, maxHeight: .infinity)
            Divider()
            HStack(alignment: .center) {
                Text("Read-only inspection · Session probes are explicit")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { NSApplication.shared.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: .infinity, minHeight: 440, idealHeight: 600, maxHeight: .infinity)
        .onDisappear { accountID = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in accountID = "" }
    }

    private func experimentalMeasurements(_ delta: P512TelemetryDelta) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last reported experimental values · not live").font(.caption.weight(.semibold))
            Text("Protocol fields; physical labels unverified. Values can come from different packets in this experiment.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach([BatteryInformation.Metric.health, .cycles, .temperature, .energyIn, .energyOut], id: \.self) { metric in
                let info: BatteryInformation = { var info = BatteryInformation(); info.receive(delta, at: Date()); return info }()
                Text("\(metric.label): \(info.samples[metric]?.value.map { String($0) } ?? "Unavailable") \(metric == .temperature ? "°C" : metric == .health ? "%" : metric == .cycles ? "count" : "Wh")")
                    .font(.caption.monospacedDigit())
            }
            Text("Aggregate In: \(experimentalValue(delta.inputWatts, unit: "W")) · Out: \(experimentalValue(delta.outputWatts, unit: "W"))")
                .font(.caption)
            ForEach(P512ProtocolPort.allCases, id: \.self) { port in
                if let reading = delta.ports[port] {
                    Text("Field \(port.rawValue): \(experimentalValue(reading.watts, unit: "W")) · \(experimentalValue(reading.volts, unit: "V")) · \(experimentalValue(reading.amps, unit: "A"))")
                        .font(.caption.monospacedDigit())
                }
            }
            Text("App-derived convention: +W input, −W output; physical verification required.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func experimentalValue(_ value: Float?, unit: String) -> String {
        value.map { String(format: "%.1f %@", $0, unit) } ?? "— \(unit)"
    }

    private var connectionSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(bluetooth.connection.label).font(.subheadline.weight(.semibold))
                if !bluetooth.connection.isIdle {
                    Text(bluetooth.connectedName).font(.caption).textSelection(.enabled)
                }
            }
            Spacer()
            switch bluetooth.connection {
            case .connecting:
                Button("Cancel") { bluetooth.disconnect() }
            case .connected:
                Button("Disconnect") { bluetooth.disconnect() }
            case .disconnecting:
                Text("Waiting for Bluetooth…").font(.caption).foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        }
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.callout.weight(.medium)).textSelection(.enabled)
                    Text(device.rssi.map { "RSSI \($0) dBm" } ?? "RSSI unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Connect") { bluetooth.connect(to: device.id) }
                        .disabled(!bluetooth.canConnect(device))
                    if device.advertisement.supportsKeyExchangeProbe {
                        Menu("Connect & Probe") {
                            ForEach(ProbeKind.allCases.filter { $0 != .authenticatedAccess }, id: \.self) { kind in
                                Button(kind.rawValue) {
                                    if bluetooth.connectAndProbe(to: device.id, kind: kind) {
                                        accountID = ""
                                    }
                                }
                            }
                        }
                            .disabled(!bluetooth.canConnect(device))
                            .help("Bounded session and telemetry experiments. The authenticated check uses the entered ID locally. Each probe disconnects; credentials and settings are never changed.")
                        Button("Authenticated telemetry check") {
                            if bluetooth.connectAndProbe(to: device.id, kind: .authenticatedAccess, userID: accountID) {
                                accountID = ""
                            }
                        }
                        .disabled(!bluetooth.canConnect(device))
                        .help("Use the ID field above to check the existing credential and request one display report.")
                    }
                }
            }
            if device.advertisement.supportsKeyExchangeProbe {
                Text("Connect inspects GATT only. Authenticated telemetry check runs the credential experiment and disconnects.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !device.hints.isEmpty {
                if let reading = device.visibleBatteryReading() {
                    Label(reading.label, systemImage: reading.symbolName).font(.callout)
                    HStack(spacing: 3) {
                        Text("Scan snapshot · observed")
                        Text(reading.observedAt, style: .relative)
                        Text("ago")
                    }.font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Battery unavailable").font(.callout)
                    if !AdvertisedBatteryReading.hardwareValidated && device.advertisement.matchesObservedRapidProProfile {
                        Text("Advertised battery support awaiting hardware validation.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("Scan to refresh").font(.caption2).foregroundStyle(.secondary)
                Label("Possible EcoFlow · model unverified", systemImage: "questionmark.circle")
                    .font(.caption)
                ForEach(device.hints, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            DisclosureGroup("Advertisement details") {
                VStack(alignment: .leading, spacing: 4) {
                    detail("Identifier", device.id.uuidString)
                    detail("Connectable", device.advertisement.isConnectable.map { $0 ? "Yes" : "No" } ?? "Unknown")
                    if let tx = device.advertisement.transmitPower { detail("Transmit power", "\(tx) dBm") }
                    if let data = device.advertisement.manufacturerData { detail("Manufacturer data (local only)", data.hex) }
                    if !device.advertisement.serviceUUIDs.isEmpty { detail("Advertised services", device.advertisement.serviceUUIDs.joined(separator: ", ")) }
                    if !device.advertisement.overflowServiceUUIDs.isEmpty { detail("Overflow services", device.advertisement.overflowServiceUUIDs.joined(separator: ", ")) }
                    if !device.advertisement.solicitedServiceUUIDs.isEmpty { detail("Solicited services", device.advertisement.solicitedServiceUUIDs.joined(separator: ", ")) }
                    ForEach(device.advertisement.serviceData.keys.sorted(), id: \.self) { uuid in
                        detail("Service data \(uuid) (local only)", device.advertisement.serviceData[uuid]?.hex ?? "")
                    }
                }
            }
            .font(.caption)
            Divider()
        }
    }

    private func serviceRow(_ service: GATTService) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(service.isPrimary ? "Primary service" : "Secondary service").font(.caption).foregroundStyle(.secondary)
                if service.discoveryFailed { Text("Characteristic discovery failed.").font(.caption).foregroundStyle(.secondary) }
                if service.characteristics.isEmpty && bluetooth.discovery == .complete { Text("No characteristics exposed.").font(.caption) }
                ForEach(service.characteristics) { characteristic in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(characteristic.uuid).font(.caption.monospaced()).textSelection(.enabled)
                        Text(characteristic.propertyLabels.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                        if characteristic.supportsSubscription {
                            HStack {
                                Button(characteristic.subscription == .on ? "Unsubscribe" : "Subscribe") {
                                    bluetooth.setSubscription(characteristic.id)
                                }
                                .disabled(!bluetooth.connection.isConnected || bluetooth.isProbing || bluetooth.gattIsStale || characteristic.subscription.isPending)
                                Text(characteristic.subscription.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }
                            if characteristic.needsEncryption {
                                Text("Subscription requires encryption; macOS may request pairing.").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let hex = characteristic.payloadHex {
                            DisclosureGroup("Last notification · \(characteristic.payloadByteCount) bytes · local only") {
                                Text(hex.isEmpty ? "Empty payload" : hex).font(.caption2.monospaced()).textSelection(.enabled)
                                if characteristic.payloadTruncated {
                                    Text("Preview truncated to \(Diagnostics.payloadLimit) bytes.").font(.caption2)
                                }
                            }
                            .font(.caption)
                        }
                        Divider()
                    }
                }
            }
        } label: {
            Text(service.uuid).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Diagnostics (\(bluetooth.diagnostics.events.count))").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Copy Diagnostics") { bluetooth.copyDiagnostics() }
                Button("Clear") { accountID = ""; bluetooth.clearDiagnostics() }
            }
            Text("Copied diagnostics exclude device identities and raw data.").font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup("Event log") {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if bluetooth.diagnostics.events.isEmpty { Text("No events yet.").font(.caption) }
                        ForEach(bluetooth.diagnostics.events) { event in
                            Text(event.line).font(.caption2.monospaced()).textSelection(.enabled)
                                .foregroundStyle(event.severity == .error ? Color.red : Color.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
            .font(.caption)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(.secondary)
            Text(value.isEmpty ? "Empty" : value).font(.caption2.monospaced()).textSelection(.enabled)
        }
    }
}

struct SomnoireSettingsView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var identity = ""
    @State var pane = 2
    var resize: (Int) -> Void = { _ in }
    var body: some View {
        VStack {
            Picker("Settings pane", selection: $pane) { Text("General").tag(2); Text("Charging").tag(0); Text("Screen").tag(1) }
                .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top])
            ZStack {
                ScrollView { GeneralPane(bluetooth: bluetooth).padding(16) }
                    .opacity(pane == 2 ? 1 : 0).disabled(pane != 2).accessibilityHidden(pane != 2)
                ScrollView { ChargingPane(bluetooth: bluetooth).padding(16) }
                    .opacity(pane == 0 ? 1 : 0).disabled(pane != 0).accessibilityHidden(pane != 0)
                ScrollView { ScreenPane(bluetooth: bluetooth).padding(16) }
                    .opacity(pane == 1 ? 1 : 0).disabled(pane != 1).accessibilityHidden(pane != 1)
            }
            HStack {
                Text(bluetooth.liveStatus.label).font(.caption).foregroundStyle(.secondary)
                if bluetooth.hasLiveCredential && bluetooth.liveStatus != .live && !bluetooth.isProbing {
                    Button("Retry") { bluetooth.startLive() }
                }
                if bluetooth.settingsStatus == .notConfirmed || bluetooth.settingsStatus == .partial { Button("Refresh") { bluetooth.disconnect() } }
                Spacer()
                Button("Done") { NSApplication.shared.keyWindow?.performClose(nil) }.keyboardShortcut(.defaultAction)
            }.padding()
        }.frame(minWidth: 520, minHeight: 340)
        .onChange(of: pane) { resize($0) }
    }
}
struct ArtworkEditor: View {
    @State private var source: CGImage?
    @State private var zoom = 1.0
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom screen art").font(.headline)
            Button("Choose PNG or JPEG…", action: choose)
            if let source, let preview = ArtworkCodec.crop(source, zoom: zoom, x: x, y: y) {
                HStack(alignment: .top, spacing: 20) {
                Image(nsImage: NSImage(cgImage: preview, size: NSSize(width: 240, height: 240)))
                    .resizable().interpolation(.high).frame(width: 240, height: 240).accessibilityLabel("240 by 240 artwork preview")
                VStack(alignment: .leading, spacing: 12) {
                Slider(value: $zoom, in: 1...4) { Text("Zoom") }
                Slider(value: $x, in: -1...1) { Text("Horizontal crop") }
                Slider(value: $y, in: -1...1) { Text("Vertical crop") }
                Text("240 × 240 pixels · local preview").font(.caption)
                Button("Upload") {}.disabled(true)
                Button("Clear") { self.source = nil; message = nil }
                }
                }
            }
            Text(message ?? "Preview is available. Artwork upload is not available in this build.")
                .font(.caption).foregroundStyle(.secondary)
        }.modifier(DashboardCardStyle())
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = false
        guard let window = NSApplication.shared.keyWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = ArtworkCodec.normalized(imageSource) else {
                message = "This image could not be decoded."; return
            }
            source = image; zoom = 1; x = 0; y = 0; message = nil
        }
    }
}
enum ArtworkCodec {
    static func normalized(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary)
    }
    static func crop(_ source: CGImage, zoom: Double, x: Double, y: Double) -> CGImage? {
        guard let context = CGContext(data: nil, width: 240, height: 240, bitsPerComponent: 8, bytesPerRow: 960,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        let scale = max(240 / Double(source.width), 240 / Double(source.height)) * min(4, max(1, zoom))
        let w = Double(source.width) * scale, h = Double(source.height) * scale
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: (240-w)/2 + x*(w-240)/2, y: (240-h)/2 + y*(h-240)/2, width: w, height: h))
        return context.makeImage()
    }
    static func package(rgba: [UInt8], id: String) -> Data? {
        guard rgba.count == 240*240*4, id.utf8.count <= 32, id.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        var result = Data()
        func big(_ value: UInt32) { result.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16)&255), UInt8((value >> 8)&255), UInt8(value&255)]) }
        big(2); big(4); big(4)
        result.append(contentsOf: Array(repeating: 0, count: 32-id.utf8.count)); result.append(contentsOf: id.utf8)
        big(0); big(1); big(3); big(1); big(72); big(115204); big(1442735868)
        let header: UInt32 = 4 | (240 << 10) | (240 << 21)
        for i in 0..<4 { result.append(UInt8((header >> (i*8))&255)) }
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let r = min(248, Int((Double(rgba[i])/8).rounded())*8)
            let g = min(252, Int((Double(rgba[i+1])/4).rounded())*4)
            let b = min(248, Int((Double(rgba[i+2])/8).rounded())*8)
            let pixel = UInt16((r << 8) | (g << 3) | (b >> 3))
            result.append(UInt8(pixel&255)); result.append(UInt8(pixel>>8))
        }
        return result
    }
}

@MainActor
struct GeneralPane: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var identity = ""
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Power Bank") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(bluetooth.selectedTargetID == nil ? "Choose your nearby power bank to get started." : "Your selected power bank is remembered on this Mac.")
                    ForEach(bluetooth.devices) { device in
                        HStack {
                            Text(device.name); Spacer()
                            Button(device.id == bluetooth.selectedTargetID ? "Selected" : "Pair") { bluetooth.selectPowerBank(device.id); bluetooth.startLive() }
                                .disabled(device.id == bluetooth.selectedTargetID)
                        }
                    }
                    HStack {
                        Button("Find Power Banks") { bluetooth.choosePowerBank() }
                        Button("Forget Bank") { bluetooth.forgetPowerBank() }.disabled(bluetooth.selectedTargetID == nil)
                    }
                    if bluetooth.selectedTargetID != nil && !bluetooth.hasLiveCredential {
                        Text("Account-free access is not established for this bank. Use your numeric EcoFlow account ID once to connect locally. Your password is never needed.").font(.caption).foregroundStyle(.secondary)
                        SecureField("Numeric EcoFlow account ID", text: $identity).textFieldStyle(.roundedBorder)
                        Button("Connect") { bluetooth.startLive(userID: identity); identity = "" }
                            .disabled(identity.isEmpty || bluetooth.isProbing)
                    }
                    if let notice = bluetooth.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Launch at Login", isOn: Binding(get: { loginStatus == .enabled }, set: { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch { loginError = "Could not update Launch at Login. Check System Settings." }
                        loginStatus = SMAppService.mainApp.status
                    }))
                    if loginStatus == .requiresApproval {
                        Button("Allow in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            DisclosureGroup("Advanced") {
                Button("Diagnostics…") { (NSApplication.shared.delegate as? SomnoireAppDelegate)?.openDiagnostics() }
            }
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onDisappear { identity = "" }
    }
}

import AppKit
import SwiftUI
import ServiceManagement

struct SomnoireStatusLabel: View {
    @ObservedObject var bluetooth: BluetoothManager
    @AppStorage("percentagePrecision") private var decimalPlaces = 0
    @AppStorage("menuBarStyle") private var iconStyle = MenuBarStyle.default.rawValue
    var body: some View {
        HStack(spacing: 4) {
            Group {
                if iconStyle == MenuBarStyle.nouNou.rawValue { Image(nsImage: MenuBarArtwork.nouNou(awake: bluetooth.batteryIsFresh)).renderingMode(.original).resizable().frame(width: 20, height: 20) }
                else { Image(systemName: bluetooth.batteryIsFresh ? "moon.stars.fill" : "moon.stars") }
            }
            Text(bluetooth.battery.formatted(precision: .saved(decimalPlaces))).monospacedDigit().opacity(bluetooth.batteryIsFresh ? 1 : 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Somnoire, \(bluetooth.battery.formatted(precision: .saved(decimalPlaces)))" + (bluetooth.batteryIsFresh ? "" : ", stale, last seen " + (bluetooth.battery.observedAt.map { RelativeAge.text(since: $0, at: Date()) } ?? "unavailable")))
    }
}

struct SomnoireMenuView: View {
    @ObservedObject var bluetooth: BluetoothManager
    var openSettings: () -> Void = {}
    @AppStorage("percentagePrecision") private var decimalPlaces = 0
    @State private var accountID = ""
    private let ports: [(String, P512ProtocolPort)] = [("C1", .usbC1), ("C2", .usbC2), ("C3", .usbC3), ("C4", .usbC4)]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                card("BATTERY", icon: "battery.100") {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(bluetooth.battery.formatted(precision: .saved(decimalPlaces))).opacity(bluetooth.batteryIsFresh ? 1 : 0.5)
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                            if !bluetooth.batteryIsFresh, let observedAt = bluetooth.battery.observedAt {
                                Text("Last seen \(RelativeAge.text(since: observedAt, at: context.date))").font(.caption).foregroundStyle(.secondary)
                            }

                        }
                        Spacer(minLength: 8)
                        if bluetooth.appMode == .fullReadings && bluetooth.hasLiveCredential {
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
                }
                if bluetooth.appMode == .fullReadings && bluetooth.hasLiveCredential {
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
                }
                if bluetooth.appMode == .fullReadings && !bluetooth.hasLiveCredential {
                    Text("Set up full readings in Settings.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Button("Quit") { bluetooth.shutdown(); NSApplication.shared.terminate(nil) }
                    Spacer()
                    Button(action: openSettings) { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).frame(width: 28).accessibilityLabel("Settings")
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
                    Text("Previously reported · \(RelativeAge.text(since: latest, at: date))").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach([BatteryInformation.Metric.health, .cycles, .temperature, .energyIn, .energyOut], id: \.self) { metric in
                    if metric == .energyIn { Divider().padding(.vertical, 3) }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(metric.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(formatted(metric)).monospacedDigit()
                        }.font(.callout)
                        if !active, let sample = information.samples[metric] {
                            Text(RelativeAge.text(since: sample.reportedAt, at: date)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(.top, 6)
        }.font(.callout.weight(.medium)).modifier(DashboardCardStyle())
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
                    Text("Stops discharging at the reserve level.").font(.caption).foregroundStyle(.secondary).opacity(draft.value?.mode == 1 ? 1 : 0.45)
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
        }.disabled(draft.value?.mode != 1).opacity(draft.value?.mode == 1 ? 1 : 0.45)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsGroup("Display", [.duration, .brightness])
            settingsGroup("Clock", [.clockEnabled, .clockFormat, .clockDuration, .chargingClockDuration])
            Text("Somnoire uses the clock artwork already on your power bank. Change it in the official EcoFlow app.").font(.caption).foregroundStyle(.secondary)
            Text("Set your power bank’s time in the official EcoFlow app.").font(.caption).foregroundStyle(.secondary)
            Link("Official EcoFlow app: time, artwork, sharing and firmware", destination: URL(string: "https://www.ecoflow.com/us/app-download")!)
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
                        } else if field == .clockEnabled {
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
    @State var pane = 2
    var resize: (Int) -> Void = { _ in }
    var body: some View {
        HSplitView {
            List {
                sidebarItem("General", icon: "gearshape", id: 2)
                sidebarItem("Alerts", icon: "bell", id: 3)
                if bluetooth.appMode == .fullReadings {
                    sidebarItem("Charging", icon: "battery.100.bolt", id: 0)
                    sidebarItem("Screen", icon: "display", id: 1)
                }
                sidebarItem("About", icon: "info.circle", id: 4)
            }.listStyle(.sidebar).frame(minWidth: 170, idealWidth: 190, maxWidth: 220)
            VStack(alignment: .leading, spacing: 0) {
                Text(pane == 0 ? "Charging" : pane == 1 ? "Screen" : pane == 3 ? "Alerts" : pane == 4 ? "About" : "General").font(.title2.bold()).padding(20)
                ZStack(alignment: .topLeading) {
                    ScrollView { AboutPane().padding(20) }.opacity(pane == 4 ? 1 : 0).disabled(pane != 4).accessibilityHidden(pane != 4)
                    ScrollView { AlertsPane(alerts: bluetooth.alerts).padding(20) }.opacity(pane == 3 ? 1 : 0).disabled(pane != 3).accessibilityHidden(pane != 3)
                    ScrollView { GeneralPane(bluetooth: bluetooth).padding(20) }.opacity(pane == 2 ? 1 : 0).disabled(pane != 2).accessibilityHidden(pane != 2)
                    if bluetooth.appMode == .fullReadings {
                        ScrollView { ChargingPane(bluetooth: bluetooth).padding(20) }.opacity(pane == 0 ? 1 : 0).disabled(pane != 0).accessibilityHidden(pane != 0)
                        ScrollView { ScreenPane(bluetooth: bluetooth).padding(20) }.opacity(pane == 1 ? 1 : 0).disabled(pane != 1).accessibilityHidden(pane != 1)
                    }
                }
                Divider()
                HStack {
                    if pane == 2 {
                        Text(bluetooth.appMode == .percentageOnly ? bluetooth.monitoring.status : bluetooth.liveStatus == .live ? "Connected to your EcoFlow." : bluetooth.liveStatus.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { NSApplication.shared.keyWindow?.performClose(nil) }.keyboardShortcut(.defaultAction)
                }.padding(16)
            }.frame(minWidth: 460).background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 680, minHeight: 500)
        .onChange(of: bluetooth.appMode) { _ in pane = 2 }
    }
    private func sidebarItem(_ title: String, icon: String, id: Int) -> some View {
        Button { pane = id } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .foregroundStyle(pane == id ? Color.white : Color.primary)
                .background(pane == id ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
}
@MainActor
struct GeneralPane: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var identity = ""
    @State private var setupHelp = false
    @AppStorage("percentagePrecision") private var decimalPlaces = 0
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("menuBarStyle") private var iconStyle = MenuBarStyle.default.rawValue
    @AppStorage("energyDisplayUnit") private var energyUnit = "Auto"
    @AppStorage("temperatureDisplayUnit") private var temperatureUnit = "°C"
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Appearance") {
                VStack(spacing: 12) {
                    Picker("Appearance", selection: $appearance) { ForEach(AppAppearance.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                    Divider()
                    Picker("Menu bar icon", selection: $iconStyle) { ForEach(MenuBarStyle.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                }.padding(8)
            }
            GroupBox("Battery Monitoring") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Monitor Battery", isOn: Binding(get: { bluetooth.monitoringEnabled }, set: { if $0 { bluetooth.startMonitoring() } else { bluetooth.pauseMonitoring() } }))
                    Divider()
                    Picker("Percentage decimal places", selection: $decimalPlaces) { ForEach(PercentagePrecision.allCases, id: \.rawValue) { Text(String($0.rawValue)).tag($0.rawValue) } }
                    Text("Shows up to the chosen decimal places when the bank reports fractions. Advertisements report whole percentages. More digits do not guarantee greater measurement accuracy.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            Button("Open setup guide") { (NSApplication.shared.delegate as? SomnoireAppDelegate)?.openOnboarding() }
            GroupBox("Experience") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Show", selection: Binding(get: { bluetooth.appMode }, set: { bluetooth.setAppMode($0) })) {
                        Text("Battery percentage only").tag(AppMode.percentageOnly)
                        Text("Full readings").tag(AppMode.fullReadings)
                    }
                    Text("Percentage monitoring needs no account. Full readings and device settings require a one-time EcoFlow account ID.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            if bluetooth.appMode == .fullReadings {
                GroupBox("Units") {
                    VStack(spacing: 12) {
                        Picker("Energy", selection: $energyUnit) { ForEach(["Auto", "Wh", "kWh"], id: \.self) { Text($0) } }
                        Divider()
                        Picker("Temperature", selection: $temperatureUnit) { ForEach(["°C", "°F"], id: \.self) { Text($0) } }
                    }.padding(8)
                }
            }
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
                    if bluetooth.appMode == .fullReadings && bluetooth.selectedTargetID != nil && !bluetooth.hasLiveCredential {
                        Text("Full readings require one-time EcoFlow account setup; everyday operation remains local.").font(.caption).foregroundStyle(.secondary)
                        Button("First-time setup") { setupHelp = true }
                            .sheet(isPresented: $setupHelp) { FirstTimeSetupSheet() }
                        SecureField("Numeric EcoFlow account ID", text: $identity).textFieldStyle(.roundedBorder)
                        Button("Connect") { bluetooth.startLive(userID: identity); identity = "" }
                            .disabled(!validEcoFlowID(identity) || bluetooth.isProbing)
                    }
                    if bluetooth.appMode == .fullReadings && bluetooth.hasLiveCredential && bluetooth.liveStatus != .live && !bluetooth.isProbing {
                        Button("Retry") { bluetooth.startLive() }
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
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onDisappear { identity = "" }
    }
}

func validEcoFlowID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy { (48...57).contains($0) }
}
struct FirstTimeSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    static let steps = [
        "1. Install the official EcoFlow phone app. Sign in or create an account using the correct country/region.",
        "2. If your bank is already linked, use its existing authorizing account. Otherwise complete first-time setup in the official app.",
        "3. On your Mac, open your regional EcoFlow website. Open the browser’s Developer Tools → Network before signing in with that same account. Filter for pages/web/create and inspect its request payload for user_id. US/Canada reports use shopify-na; European reports use shopify-eu. Copy only the numeric ID. Regional behavior varies: if absent, consult the retrieval guide below. A website ID is a candidate until your bank accepts it.",
        "4. Close the official app’s Bluetooth connection. In Somnoire, find and select your bank, paste only the numeric ID, and click Connect. Never paste your password, a login token, or the whole response.",
        "5. After connection succeeds, quit and reopen Somnoire to check remembered access. Only the derived bank credential is stored in this Mac’s Keychain; the ID is cleared after use."
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("First-time setup").font(.title2)
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.steps, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                Link("Install the official EcoFlow app", destination: URL(string: "https://www.ecoflow.com/us/app-download")!)
                Text("Browser retrieval is community-documented and varies by region.").font(.caption).foregroundStyle(.secondary)
                Link("Account-ID retrieval guide and regional updates", destination: URL(string: "https://github.com/rabits/ha-ef-ble/issues/130")!)
            } }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 560, height: 530)
    }
}

struct AlertsPane: View {
    @ObservedObject var alerts: LowBatteryAlerts
    var body: some View {
        GroupBox("Low battery") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Low battery alerts", isOn: Binding(get: { alerts.enabled }, set: { alerts.setEnabled($0) })).toggleStyle(.switch)
                Divider()
                Picker("Notify at", selection: $alerts.threshold) { ForEach(LowBatteryPolicy.thresholds, id: \.self) { Text("\($0)%").tag($0) } }.disabled(!alerts.enabled)
                Text(alerts.status).font(.caption).foregroundStyle(.secondary)
                Text("One notification per low-battery event. This requires Somnoire running, battery monitoring enabled, and the bank nearby. Monitoring pauses during sleep.").font(.caption).foregroundStyle(.secondary)
                Button("Send test notification") { alerts.test() }.disabled(!alerts.enabled)
            }.padding(8)
        }.onAppear { alerts.refresh() }
    }
}

struct AppAppearanceStyle: ViewModifier {
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance == "Light" ? .light : appearance == "Dark" ? .dark : nil)
    }
}
struct AppIdentityIcon: View {
    var size: CGFloat = 96
    var body: some View { Image(nsImage: NSImage(named: "AppIcon") ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 128, height: 128))).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size) }
}
@MainActor
final class AboutSession: ObservableObject {
    static let shared = AboutSession()
    @Published var unlock = DiagnosticsUnlock()
}
struct AboutPane: View {
    @ObservedObject private var session = AboutSession.shared
    @State private var activated = false
    var body: some View {
        VStack(spacing: 16) {
            Button { if session.unlock.activate() { activated = true } } label: { AppIdentityIcon(size: 120) }.buttonStyle(.plain).accessibilityLabel("Somnoire app icon")
            Text("Somnoire").font(.largeTitle.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))").foregroundStyle(.secondary)
            Text("Your power bank, quietly nearby.").font(.title3)
            Text("Battery monitoring and optional full readings over Bluetooth. Everyday operation stays local on your Mac.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Link("Somnoire on GitHub", destination: URL(string: "https://github.com/Kusanalee/Somnoire")!)
            Button("Check for Updates") { NSWorkspace.shared.open(URL(string: "https://github.com/Kusanalee/Somnoire/releases")!) }
            if session.unlock.unlocked { Button("Open Diagnostics…") { (NSApplication.shared.delegate as? SomnoireAppDelegate)?.openDiagnostics() } }
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
        .alert("Diagnostics activated.", isPresented: $activated) { Button("OK", role: .cancel) {} }
    }
}

enum MenuBarArtwork {
    static func nouNou(awake: Bool) -> NSImage {
        let stem = awake ? "NouNouAwake" : "NouNouSleepy"
        // Xcode combines the standard/Retina PNG pair into a multi-representation TIFF.
        guard let url = Bundle.main.url(forResource: stem, withExtension: "tiff"), let image = NSImage(contentsOf: url) else { return NSImage(size: NSSize(width: 20, height: 20)) }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = false; return image
    }
}

struct OnboardingView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @AppStorage("onboardingStep") private var savedStep = OnboardingStep.welcome.rawValue
    @State private var identity = ""
    @State private var help = false
    var close: () -> Void = {}
    private var step: OnboardingStep { OnboardingStep(rawValue: savedStep) ?? .welcome }
    var body: some View {
        VStack(spacing: 20) {
            AppIdentityIcon(size: step == .welcome ? 110 : 64)
            Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .welcome:
                        Text("Keep an eye on your power bank from your Mac’s menu bar. Somnoire works locally over Bluetooth.")
                        Text("Let’s get you set up.").foregroundStyle(.secondary)
                    case .experience:
                        Picker("Your experience", selection: Binding(get: { bluetooth.appMode }, set: { bluetooth.setAppMode($0) })) {
                            Text("Battery percentage only").tag(AppMode.percentageOnly)
                            Text("Full readings").tag(AppMode.fullReadings)
                        }
                        Text("Percentage monitoring needs no account. Full readings adds wattage and device settings using a one-time numeric EcoFlow account ID.").foregroundStyle(.secondary)
                    case .bank:
                        Text("Keep your power bank awake and nearby. Allow Bluetooth access when macOS asks.")
                        Text(bluetooth.availability == .ready ? bluetooth.monitoring.status : bluetooth.availability.rawValue).foregroundStyle(.secondary)
                        ForEach(bluetooth.devices.filter { $0.advertisement.matchesObservedRapidProProfile }) { device in
                            HStack { Text(device.name); Spacer(); Button(device.id == bluetooth.selectedTargetID ? "Selected" : "Select") { bluetooth.selectPowerBank(device.id) }.disabled(device.id == bluetooth.selectedTargetID) }
                        }
                        if bluetooth.devices.isEmpty { Text("No power banks found yet. Turn on Bluetooth and wake your bank, then try again.").font(.callout).foregroundStyle(.secondary) }
                        Button("Find Power Banks") { bluetooth.startMonitoring(); bluetooth.choosePowerBank() }
                    case .access:
                        Text("Close the official app’s Bluetooth connection, then enter the numeric ID from your bank’s authorizing account. Your password and login tokens stay outside Somnoire.")
                        Button("How to find your account ID") { help = true }
                        SecureField("Numeric EcoFlow account ID", text: $identity).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Connect") { bluetooth.startLive(userID: identity); identity = "" }.disabled(!validEcoFlowID(identity) || bluetooth.isProbing)
                            if bluetooth.hasLiveCredential { Button("Use saved access") { bluetooth.startLive() }.disabled(bluetooth.isProbing) }
                        }
                        Text(bluetooth.liveStatus.label).foregroundStyle(.secondary)
                        if let notice = bluetooth.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                        Button("Use percentage only") { bluetooth.setAppMode(.percentageOnly); savedStep = OnboardingStep.ready.rawValue }
                    case .ready:
                        Text(bluetooth.appMode == .percentageOnly ? "Your percentage will appear in the menu bar when the bank broadcasts nearby." : "Full readings are ready. Somnoire remembers access in this Mac’s Keychain.")
                        Text("Open Settings from the dashboard’s gear menu anytime. Monitoring runs while Somnoire is open and your Mac is awake.").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if step != .welcome { Button("Back") { identity = ""; savedStep = step.previous(mode: bluetooth.appMode).rawValue } }
                Button("Set Up Later") { identity = ""; close() }
                Spacer()
                Button(step == .ready ? "Get Started" : "Continue") { advance() }.keyboardShortcut(.defaultAction)
                    .disabled(!step.canAdvance(hasBank: bluetooth.selectedTargetID != nil, live: bluetooth.liveStatus == .live))
            }
        }.padding(32).frame(minWidth: 520, minHeight: 540).background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $help) { FirstTimeSetupSheet().modifier(AppAppearanceStyle()) }
        .onChange(of: bluetooth.liveStatus) { status in if step == .access && status == .live { savedStep = OnboardingStep.ready.rawValue } }
        .onDisappear { identity = "" }
    }
    private var title: String {
        switch step { case .welcome: return "Welcome to Somnoire"; case .experience: return "Make it yours"; case .bank: return "Find your power bank"; case .access: return "Connect for full readings"; case .ready: return "You’re ready" }
    }
    private func advance() {
        identity = ""
        if step == .ready { UserDefaults.standard.set(true, forKey: "onboardingComplete"); close(); return }
        let previous = step
        savedStep = step.next(mode: bluetooth.appMode).rawValue
        if previous == .experience { bluetooth.startMonitoring(); bluetooth.choosePowerBank() }
        if previous == .bank && bluetooth.appMode == .fullReadings { bluetooth.startLive() }
    }
}

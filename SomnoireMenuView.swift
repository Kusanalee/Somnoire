import AppKit
import SwiftUI

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
    var body: some View {
        Text("Somnoire")
        Text(bluetooth.monitoring.name)
        Text(bluetooth.monitoring.batteryText)
        Text(bluetooth.monitoring.status)
        if let reading = bluetooth.monitoring.lastReading {
            Text("Last received \(reading.observedAt.formatted(date: .omitted, time: .standard))")
        }
        Divider()
        Toggle("Monitor Battery", isOn: Binding(get: { bluetooth.monitoringEnabled }, set: {
            if $0 { bluetooth.startMonitoring() } else { bluetooth.pauseMonitoring() }
        }))
        Button("Choose Power Bank…") {
            bluetooth.choosePowerBank(); showDiagnostics()
        }
        Button("Forget Power Bank") { bluetooth.forgetPowerBank() }
            .disabled(bluetooth.selectedTargetID == nil)
        Divider()
        Button("Diagnostics…") { showDiagnostics() }.keyboardShortcut("d")
        Button("Quit Somnoire") {
            bluetooth.shutdown(); NSApplication.shared.terminate(nil)
        }.keyboardShortcut("q")
    }
    private func showDiagnostics() {
        openDiagnostics()
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

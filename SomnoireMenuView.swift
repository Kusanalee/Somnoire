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
                    if let stage = bluetooth.probeStage {
                        Text("Experimental probe · \(stage.rawValue)").font(.caption)
                        Button("Cancel Probe") { bluetooth.disconnect() }
                    }
                    if let result = bluetooth.probeResult {
                        Text("Previous probe · \(result.kind.rawValue)").font(.caption.weight(.semibold))
                        Text(result.outcome.label).font(.caption)
                        Text(String(format: "Last probe: %.2f seconds", result.elapsed)).font(.caption2).foregroundStyle(.secondary)
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
                            ForEach(ProbeKind.allCases, id: \.self) { kind in
                                Button(kind.rawValue) { bluetooth.connectAndProbe(to: device.id, kind: kind) }
                            }
                        }
                            .disabled(!bluetooth.canConnect(device))
                            .help("Choose key exchange only or experimental encrypted session/status. Both intentionally disconnect. No login or device controls.")
                    }
                }
            }
            if device.advertisement.supportsKeyExchangeProbe {
                Text("Probe: experimental session exchange, then disconnect. No device controls.").font(.caption2).foregroundStyle(.secondary)
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
                Button("Clear") { bluetooth.clearDiagnostics() }
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

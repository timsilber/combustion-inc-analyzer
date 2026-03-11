//
//  LiveView.swift
//  CombustionIncAnalyser
//
//  Created by Michael Schinis on 20/02/2024.
//

import Combine
import CombustionBLE
import SwiftUI

class LiveViewModel: ObservableObject {
    @Published var deviceManager = DeviceManager.shared
    
    @Published var probes: [Probe] = []
    @Published var gauges: [CombustionBLE.Gauge] = []
    @Published var nodes: [MeatNetNode] = []
    @Published var otherDevices: [Device] = []

    private var subscribers: Set<AnyCancellable> = []
    
    func start() {
        deviceManager.enableMeatNet()
        deviceManager.initBluetooth()

        deviceManager
            .$devices
            .receive(on: DispatchQueue.main)
            .sink { devices in
                self.probes = devices.values.compactMap { $0 as? Probe }
                self.gauges = devices.values.compactMap { $0 as? CombustionBLE.Gauge }
                self.nodes = devices.values.compactMap { $0 as? MeatNetNode }
                self.otherDevices = devices.values.filter { !($0 is Probe) && !($0 is MeatNetNode) && !($0 is CombustionBLE.Gauge) }
            }
            .store(in: &subscribers)
    }

    var firstGauge: CombustionBLE.Gauge? {
        gauges.first
    }
}

struct LiveView: View {
    @StateObject private var viewModel: LiveViewModel

    init() {
        self._viewModel = StateObject(wrappedValue: LiveViewModel())
    }

    init(viewModel: LiveViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    private var hasAnyDevices: Bool {
        !viewModel.probes.isEmpty || !viewModel.gauges.isEmpty || !viewModel.nodes.isEmpty || !viewModel.otherDevices.isEmpty
    }

    var body: some View {
        NavigationView {
            List {
                if !hasAnyDevices {
                    Section {
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning for devices…")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }

                if !viewModel.probes.isEmpty {
                    Section("Probes") {
                        ForEach(viewModel.probes, id: \.self) { probe in
                            NavigationLink(destination: LiveProbeView(probe: probe, gauge: viewModel.firstGauge)) {
                                ProbeRow(probe: probe)
                            }
                        }
                    }
                }

                if !viewModel.gauges.isEmpty {
                    Section("Gauges") {
                        ForEach(viewModel.gauges, id: \.self) { gauge in
                            GaugeRow(gauge: gauge)
                        }
                    }
                }

                if !viewModel.nodes.isEmpty {
                    Section("MeatNet Nodes") {
                        ForEach(viewModel.nodes, id: \.self) { node in
                            NodeRow(node: node)
                        }
                    }
                }

                if !viewModel.otherDevices.isEmpty {
                    Section("Other Devices") {
                        ForEach(viewModel.otherDevices, id: \.self) { device in
                            Text(device.uniqueIdentifier)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 260)
            .navigationTitle("Devices")
        }
        .onAppear(perform: {
            viewModel.start()
        })
    }
}

struct ProbeRow: View {
    @ObservedObject var probe: Probe
    @AppStorage(AppSettingsKeys.temperatureUnit.rawValue) private var temperatureUnit: TemperatureUnit = .celsius

    private var isFahrenheit: Bool { temperatureUnit == .fahrenheit }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(probe.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                ConnectionBadge(
                    state: probe.connectionState,
                    isMeatNetRelay: probe.connectionState == .disconnected && probe.lastNormalModeHopCount != nil
                )
            }
            if let temps = probe.virtualTemperatures {
                HStack(spacing: 10) {
                    TempLabel(label: "C", celsius: temps.coreTemperature, isFahrenheit: isFahrenheit)
                    TempLabel(label: "S", celsius: temps.surfaceTemperature, isFahrenheit: isFahrenheit)
                    TempLabel(label: "A", celsius: temps.ambientTemperature, isFahrenheit: isFahrenheit)
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1)
            } else if let raw = probe.currentTemperatures {
                let temp = isFahrenheit ? raw.values[0] * 9.0 / 5.0 + 32.0 : raw.values[0]
                let unit = isFahrenheit ? "°F" : "°C"
                Text("T1: \(temp, specifier: "%.1f")\(unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct NodeRow: View {
    @ObservedObject var node: MeatNetNode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(nodeDisplayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ConnectionBadge(state: node.connectionState)
            }
            HStack(spacing: 8) {
                Text("\(node.rssi) dBm")
                if !node.probes.isEmpty {
                    Text("· \(node.probes.count) probe(s)")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var nodeDisplayName: String {
        if let sku = node.sku {
            return sku
        }
        if let serial = node.serialNumberString {
            return serial
        }
        return String(node.uniqueIdentifier.prefix(12))
    }
}

struct ConnectionBadge: View {
    let state: Device.ConnectionState
    var isMeatNetRelay: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
                .shadow(color: badgeColor.opacity(0.5), radius: 3)
            Text(badgeLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.1))
        .clipShape(Capsule())
    }

    private var badgeColor: Color {
        if isMeatNetRelay { return .cyan }
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var badgeLabel: String {
        if isMeatNetRelay { return "Via MeatNet" }
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .failed: return "Failed"
        }
    }
}

struct GaugeRow: View {
    @ObservedObject var gauge: CombustionBLE.Gauge
    @AppStorage(AppSettingsKeys.temperatureUnit.rawValue) private var temperatureUnit: TemperatureUnit = .celsius

    private var isFahrenheit: Bool { temperatureUnit == .fahrenheit }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(gauge.serialNumberString)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if gauge.sensorPresent {
                    let temp = isFahrenheit ? gauge.temperatureFahrenheit : gauge.temperatureCelsius
                    let unit = isFahrenheit ? "°F" : "°C"
                    Text("\(temp, specifier: "%.1f")\(unit)")
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(.orange)
                } else {
                    Text("No sensor")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                Text("\(gauge.rssi) dBm")
                if gauge.lowBattery {
                    Label("Low Battery", systemImage: "battery.25")
                        .foregroundStyle(.red)
                }
                if gauge.sensorOverheating {
                    Label("Overheating", systemImage: "thermometer.sun.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

struct TempLabel: View {
    let label: String
    let celsius: Double
    var isFahrenheit: Bool = false

    var body: some View {
        let temp = isFahrenheit ? celsius * 9.0 / 5.0 + 32.0 : celsius
        let unit = isFahrenheit ? "°F" : "°C"
        HStack(spacing: 2) {
            Text("\(label):")
                .foregroundStyle(.tertiary)
            Text("\(temp, specifier: "%.1f")\(unit)")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    LiveView()
}

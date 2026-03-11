//
//  LiveProbeView.swift
//  CombustionIncAnalyser
//
//  Created by Michael Schinis on 20/02/2024.
//

import Charts
import Combine
import CombustionBLE
import SwiftUI
import UserNotifications

// MARK: - Data Model

struct LiveChartDataPoint: Identifiable {
    let id: UInt32
    let timeSeconds: Double
    let timestamp: Date
    let core: Double
    let surface: Double
    let ambient: Double
    let gauge: Double?
}

struct LiveChartHoverInfo {
    let position: Float
    let point: LiveChartDataPoint
}

// MARK: - LTTB Downsampling (Largest-Triangle-Three-Buckets)
// Non-trivial algorithm: selects representative points by maximizing triangle area
// between previous selected point, candidate, and next-bucket average.
// Reference: Sveinn Steinarsson, 2013 — "Downsampling Time Series for Visual Representation"

func lttbDownsample(_ data: [LiveChartDataPoint], to threshold: Int) -> [LiveChartDataPoint] {
    guard data.count > threshold, threshold >= 3 else { return data }

    var result: [LiveChartDataPoint] = []
    result.reserveCapacity(threshold)
    result.append(data[0])

    let bucketSize = Double(data.count - 2) / Double(threshold - 2)
    var prevIndex = 0

    for i in 0..<(threshold - 2) {
        let bucketStart = Int(Double(i + 1) * bucketSize) + 1
        let bucketEnd = min(Int(Double(i + 2) * bucketSize) + 1, data.count - 1)

        let nextBucketStart = min(bucketEnd, data.count - 1)
        let nextBucketEnd = min(Int(Double(i + 3) * bucketSize) + 1, data.count)
        var avgTimestamp: Double = 0
        var avgValue: Double = 0
        let nextCount = max(nextBucketEnd - nextBucketStart, 1)
        for j in nextBucketStart..<min(nextBucketEnd, data.count) {
            avgTimestamp += data[j].timestamp.timeIntervalSince1970
            avgValue += data[j].core
        }
        avgTimestamp /= Double(nextCount)
        avgValue /= Double(nextCount)

        var maxArea: Double = -1
        var bestIndex = bucketStart
        let prevTimestamp = data[prevIndex].timestamp.timeIntervalSince1970
        let prevValue = data[prevIndex].core

        // Triangle area = |½ × cross product of vectors from prev→candidate and prev→avgNext|
        for j in bucketStart..<bucketEnd {
            let area = abs(
                (data[j].timestamp.timeIntervalSince1970 - prevTimestamp) * (avgValue - prevValue) -
                (avgTimestamp - prevTimestamp) * (data[j].core - prevValue)
            )
            if area > maxArea {
                maxArea = area
                bestIndex = j
            }
        }

        result.append(data[bestIndex])
        prevIndex = bestIndex
    }

    result.append(data[data.count - 1])
    return result
}

func lttbDownsamplePersisted(_ data: [PersistedTemperaturePoint], to threshold: Int) -> [PersistedTemperaturePoint] {
    guard data.count > threshold, threshold >= 3 else { return data }

    var result: [PersistedTemperaturePoint] = []
    result.reserveCapacity(threshold)
    result.append(data[0])

    let bucketSize = Double(data.count - 2) / Double(threshold - 2)
    var prevIndex = 0

    for i in 0..<(threshold - 2) {
        let bucketStart = Int(Double(i + 1) * bucketSize) + 1
        let bucketEnd = min(Int(Double(i + 2) * bucketSize) + 1, data.count - 1)

        let nextBucketStart = min(bucketEnd, data.count - 1)
        let nextBucketEnd = min(Int(Double(i + 3) * bucketSize) + 1, data.count)
        var avgTimestamp: Double = 0
        var avgValue: Double = 0
        let nextCount = max(nextBucketEnd - nextBucketStart, 1)
        for j in nextBucketStart..<min(nextBucketEnd, data.count) {
            avgTimestamp += data[j].timestamp.timeIntervalSince1970
            avgValue += data[j].core
        }
        avgTimestamp /= Double(nextCount)
        avgValue /= Double(nextCount)

        var maxArea: Double = -1
        var bestIndex = bucketStart
        let prevTimestamp = data[prevIndex].timestamp.timeIntervalSince1970
        let prevValue = data[prevIndex].core

        for j in bucketStart..<bucketEnd {
            let area = abs(
                (data[j].timestamp.timeIntervalSince1970 - prevTimestamp) * (avgValue - prevValue) -
                (avgTimestamp - prevTimestamp) * (data[j].core - prevValue)
            )
            if area > maxArea {
                maxArea = area
                bestIndex = j
            }
        }

        result.append(data[bestIndex])
        prevIndex = bestIndex
    }

    result.append(data[data.count - 1])
    return result
}

// MARK: - ViewModel

class LiveProbeViewModel: ObservableObject {
    @Published var probe: Probe
    @Published var chartData: [LiveChartDataPoint] = []
    @Published var displayData: [LiveChartDataPoint] = []

    @Published var gaugeHistory: [(date: Date, celsius: Double)] = []
    weak var gauge: CombustionBLE.Gauge?

    @Published var targetTemperatureCelsius: Double? = nil
    @Published var targetReached = false
    private var targetNotificationSent = false

    private var subscribers: Set<AnyCancellable> = []
    private var saveCounter = 0
    private var sessionID: UUID?
    private var lastRebuiltCount = 0

    private static let maxDisplayPoints = 600

    init(probe: Probe) {
        self.probe = probe
        restoreSession()
    }

    func monitor() {
        probe
            .$currentTemperatures
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &subscribers)

        probe
            .$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &subscribers)

        probe
            .$predictionInfo
            .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &subscribers)

        Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.validateSessionIfNeeded()
                self?.sampleGaugeTemperature()
                self?.rebuildChartData()
                self?.checkTargetTemperature()
                self?.autoSave()
            }
            .store(in: &subscribers)
    }

    func connect() {
        probe.connect()
    }

    func disconnect() {
        probe.disconnect()
    }

    func setTargetTemperature(celsius: Double?) {
        targetTemperatureCelsius = celsius
        targetReached = false
        targetNotificationSent = false

        if let temp = celsius {
            DeviceManager.shared.setRemovalPrediction(probe, removalTemperatureC: temp) { _ in }
        } else {
            DeviceManager.shared.cancelPrediction(probe) { _ in }
        }
    }

    func closestPoint(to date: Date) -> LiveChartDataPoint? {
        guard !displayData.isEmpty else { return nil }
        let target = date.timeIntervalSince1970
        var lo = 0, hi = displayData.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if displayData[mid].timestamp.timeIntervalSince1970 < target { lo = mid + 1 } else { hi = mid }
        }
        var best = lo
        if lo > 0 {
            let dLo = abs(displayData[lo].timestamp.timeIntervalSince1970 - target)
            let dPrev = abs(displayData[lo - 1].timestamp.timeIntervalSince1970 - target)
            if dPrev < dLo { best = lo - 1 }
        }
        return displayData[best]
    }

    private func sampleGaugeTemperature() {
        guard let gauge = gauge, gauge.sensorPresent else { return }
        gaugeHistory.append((date: Date(), celsius: gauge.temperatureCelsius))
        if gaugeHistory.count > 21600 {
            gaugeHistory.removeFirst(gaugeHistory.count - 21600)
        }
    }

    private func rebuildChartData() {
        guard let log = probe.temperatureLogs.last else {
            if !chartData.isEmpty {
                chartData = []
                displayData = []
            }
            return
        }

        let currentCount = log.dataPoints.count
        guard currentCount != lastRebuiltCount else { return }
        lastRebuiltCount = currentCount

        let samplePeriodSeconds = Double(log.sessionInformation.samplePeriod) / 1000.0
        let sessionStart = log.startTime ?? Date()

        chartData = log.dataPoints.map { dp in
            let timeSeconds = Double(dp.sequenceNum) * samplePeriodSeconds
            let timestamp = sessionStart.addingTimeInterval(timeSeconds)

            let gaugeTemp = closestGaugeReading(to: timestamp)

            return LiveChartDataPoint(
                id: dp.sequenceNum,
                timeSeconds: timeSeconds,
                timestamp: timestamp,
                core: dp.virtualCore.temperatureFrom(dp.temperatures),
                surface: dp.virtualSurface.temperatureFrom(dp.temperatures),
                ambient: dp.virtualAmbient.temperatureFrom(dp.temperatures),
                gauge: gaugeTemp
            )
        }

        displayData = lttbDownsample(chartData, to: Self.maxDisplayPoints)
    }

    private func closestGaugeReading(to date: Date) -> Double? {
        guard !gaugeHistory.isEmpty else { return nil }
        let target = date.timeIntervalSince1970
        var lo = 0, hi = gaugeHistory.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if gaugeHistory[mid].date.timeIntervalSince1970 < target { lo = mid + 1 } else { hi = mid }
        }
        var best = lo
        if lo > 0 {
            let dLo = abs(gaugeHistory[lo].date.timeIntervalSince1970 - target)
            let dPrev = abs(gaugeHistory[lo - 1].date.timeIntervalSince1970 - target)
            if dPrev < dLo { best = lo - 1 }
        }
        if abs(gaugeHistory[best].date.timeIntervalSince1970 - target) <= 10.0 {
            return gaugeHistory[best].celsius
        }
        return nil
    }

    private func checkTargetTemperature() {
        guard let target = targetTemperatureCelsius,
              let temps = probe.virtualTemperatures else { return }

        if temps.coreTemperature >= target && !targetReached {
            targetReached = true
            if !targetNotificationSent {
                targetNotificationSent = true
                sendTargetReachedNotification(coreCelsius: temps.coreTemperature, targetCelsius: target)
            }
        }
    }

    private func sendTargetReachedNotification(coreCelsius: Double, targetCelsius: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Target Temperature Reached"
        content.body = String(format: "Probe %@ core is %.1f°C (target: %.1f°C)",
                              probe.serialNumberString, coreCelsius, targetCelsius)
        content.sound = .default

        let request = UNNotificationRequest(identifier: "target-\(probe.serialNumberString)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private var restoredSdkSessionID: UInt32?
    private var sessionValidated = false

    private func restoreSession() {
        let sdkID = probe.sessionInformation?.sessionID

        if let sdkID = sdkID,
           let exact = CookSessionStore.shared.session(forProbeSerial: probe.serialNumberString, sdkSessionID: sdkID) {
            sessionID = exact.id
            restoredSdkSessionID = sdkID
            sessionValidated = true
            targetTemperatureCelsius = exact.targetTemperatureCelsius
            gaugeHistory = exact.gaugeOnlyPoints.map { (date: $0.timestamp, celsius: $0.celsius) }
            return
        }

        if let recent = CookSessionStore.shared.mostRecentSession(forProbeSerial: probe.serialNumberString) {
            sessionID = recent.id
            restoredSdkSessionID = recent.sdkSessionID
            targetTemperatureCelsius = recent.targetTemperatureCelsius
            gaugeHistory = recent.gaugeOnlyPoints.map { (date: $0.timestamp, celsius: $0.celsius) }
        }
    }

    private func validateSessionIfNeeded() {
        guard !sessionValidated, let sdkID = probe.sessionInformation?.sessionID else { return }
        sessionValidated = true

        if let restoredID = restoredSdkSessionID, restoredID == sdkID {
            return
        }

        if let exact = CookSessionStore.shared.session(forProbeSerial: probe.serialNumberString, sdkSessionID: sdkID) {
            sessionID = exact.id
            restoredSdkSessionID = sdkID
            targetTemperatureCelsius = exact.targetTemperatureCelsius
            gaugeHistory = exact.gaugeOnlyPoints.map { (date: $0.timestamp, celsius: $0.celsius) }
        } else {
            sessionID = nil
            restoredSdkSessionID = sdkID
            gaugeHistory = []
        }
    }

    private func autoSave() {
        saveCounter += 1
        guard saveCounter % 15 == 0 else { return }

        let id = sessionID ?? UUID()
        sessionID = id

        let dataPoints = chartData.map { dp in
            PersistedTemperaturePoint(
                timestamp: dp.timestamp,
                core: dp.core,
                surface: dp.surface,
                ambient: dp.ambient,
                gauge: dp.gauge
            )
        }

        let gaugePoints = gaugeHistory.map {
            PersistedGaugePoint(timestamp: $0.date, celsius: $0.celsius)
        }

        let session = PersistedCookSession(
            id: id,
            probeSerial: probe.serialNumberString,
            sdkSessionID: probe.sessionInformation?.sessionID,
            startDate: chartData.first?.timestamp ?? Date(),
            endDate: chartData.last?.timestamp,
            dataPoints: dataPoints,
            gaugeSerial: gauge?.serialNumberString,
            gaugeOnlyPoints: gaugePoints,
            targetTemperatureCelsius: targetTemperatureCelsius,
            notes: nil
        )

        CookSessionStore.shared.save(session)
    }
}

// MARK: - View

struct LiveProbeView: View {
    @StateObject private var viewModel: LiveProbeViewModel
    @State private var hoverInfo: LiveChartHoverInfo?

    @AppStorage(AppSettingsKeys.temperatureUnit.rawValue) private var temperatureUnit: TemperatureUnit = .celsius

    @State private var showCore = true
    @State private var showSurface = true
    @State private var showAmbient = true
    @State private var showGauge = true

    @State private var targetInputText = ""
    @State private var isEditingTarget = false

    private var isFahrenheit: Bool { temperatureUnit == .fahrenheit }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let hoverTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    init(probe: Probe, gauge: CombustionBLE.Gauge? = nil) {
        let vm = LiveProbeViewModel(probe: probe)
        vm.gauge = gauge
        self._viewModel = StateObject(wrappedValue: vm)
    }

    init(viewModel: LiveProbeViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    private var isConnected: Bool {
        viewModel.probe.connectionState == .connected
    }

    private func displayTemp(_ celsius: Double) -> Double {
        isFahrenheit ? celsius * 9.0 / 5.0 + 32.0 : celsius
    }

    private func celsiusFromDisplay(_ display: Double) -> Double {
        isFahrenheit ? (display - 32.0) * 5.0 / 9.0 : display
    }

    private var unitSymbol: String {
        isFahrenheit ? "°F" : "°C"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection

                sectionSeparator

                if let virtualSensors = viewModel.probe.virtualSensors,
                   let currentTemperatures = viewModel.probe.currentTemperatures {
                    currentTemperaturesSection(
                        virtualSensors: virtualSensors,
                        temperatures: currentTemperatures
                    )

                    sectionSeparator
                }

                targetAndPredictionSection

                sectionSeparator

                chartSection

                sectionSeparator

                infoSection

                Spacer(minLength: 20)
            }
        }
        .navigationTitle("Probe \(viewModel.probe.name)")
        .onAppear {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            viewModel.monitor()
            if let target = viewModel.targetTemperatureCelsius {
                targetInputText = String(format: "%.0f", displayTemp(target))
            }
        }
    }

    private var sectionSeparator: some View {
        Rectangle()
            .fill(Color(.separatorColor))
            .frame(height: 1)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.probe.name)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                ConnectionBadge(
                    state: viewModel.probe.connectionState,
                    isMeatNetRelay: viewModel.probe.connectionState == .disconnected && viewModel.probe.lastNormalModeHopCount != nil
                )
            }

            Spacer()

            Button(action: {
                if isConnected {
                    viewModel.disconnect()
                } else {
                    viewModel.connect()
                }
            }) {
                Label(
                    isConnected ? "Disconnect" : "Connect",
                    systemImage: isConnected ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"
                )
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(isConnected ? Color.secondary : .blue)
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Current Temperatures (clickable cards)

    private func currentTemperaturesSection(
        virtualSensors: VirtualSensors,
        temperatures: ProbeTemperatures
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LIVE READINGS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)

            HStack(spacing: 10) {
                temperatureCard(
                    label: "Core",
                    celsius: virtualSensors.virtualCore.temperatureFrom(temperatures),
                    color: TemperatureChartPlottable.core.color,
                    isEnabled: $showCore
                )
                temperatureCard(
                    label: "Surface",
                    celsius: virtualSensors.virtualSurface.temperatureFrom(temperatures),
                    color: TemperatureChartPlottable.surface.color,
                    isEnabled: $showSurface
                )
                temperatureCard(
                    label: "Ambient",
                    celsius: virtualSensors.virtualAmbient.temperatureFrom(temperatures),
                    color: TemperatureChartPlottable.ambient.color,
                    isEnabled: $showAmbient
                )

               
                if let gauge = viewModel.gauge, gauge.sensorPresent {
                    temperatureCard(
                        label: "Gauge",
                        celsius: gauge.temperatureCelsius,
                        color: TemperatureChartPlottable.gauge.color,
                        isEnabled: $showGauge
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func temperatureCard(label: String, celsius: Double, color: Color, isEnabled: Binding<Bool>) -> some View {
        let displayed = displayTemp(celsius)
        let active = isEnabled.wrappedValue
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(active ? color : color.opacity(0.25))
                    .frame(width: 10, height: 10)
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(active ? .secondary : .tertiary)
                    .tracking(0.5)
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(displayed, specifier: "%.1f")")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(active ? .primary : .tertiary)
                Text(unitSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? .secondary : .tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? color.opacity(0.08) : Color(.controlBackgroundColor))
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [active ? color.opacity(0.12) : .clear, .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(active ? color.opacity(0.3) : Color(.separatorColor), lineWidth: 1)
        )
        .shadow(color: active ? color.opacity(0.2) : .clear, radius: 8, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isEnabled.wrappedValue.toggle()
            }
        }
    }

    // MARK: - Target & Prediction

    private var targetAndPredictionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text("TARGET")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)

                HStack(spacing: 6) {
                    TextField("e.g. \(isFahrenheit ? "203" : "95")", text: $targetInputText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .monospacedDigit()
                        .onSubmit { commitTarget() }

                    Text(unitSymbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(viewModel.targetTemperatureCelsius != nil ? "Update" : "Set") {
                    commitTarget()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.2, green: 0.7, blue: 0.3))
                .controlSize(.small)
                .disabled(targetInputText.isEmpty)

                if viewModel.targetTemperatureCelsius != nil {
                    Button("Clear") {
                        viewModel.setTargetTemperature(celsius: nil)
                        targetInputText = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                if viewModel.targetReached {
                    Label("Target Reached!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.bold())
                }
            }

            if let info = viewModel.probe.predictionInfo, info.predictionMode != .none {
                predictionCard(info: info)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func commitTarget() {
        guard let displayValue = Double(targetInputText) else { return }
        let celsius = celsiusFromDisplay(displayValue)
        let clamped = min(max(celsius, 0.1), 99.9)
        viewModel.setTargetTemperature(celsius: clamped)
        targetInputText = String(format: "%.0f", displayTemp(clamped))
    }

    private func predictionCard(info: PredictionInfo) -> some View {
        let isReady = info.predictionState == .removalPredictionDone
        let isNotInserted = info.predictionState == .probeNotInserted
        let stateColor = predictionStateColor(info.predictionState)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(predictionStateLabel(info.predictionState), systemImage: predictionStateIcon(info.predictionState))
                    .font(isReady ? .headline.bold() : .subheadline.bold())
                    .foregroundStyle(stateColor)

                Spacer()

                if let seconds = info.secondsRemaining {
                    Text(formatCountdown(seconds))
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }

            if info.predictionSetPointTemperature > 0 {
                HStack(spacing: 20) {
                    HStack(spacing: 4) {
                        Text("Target")
                            .foregroundStyle(.tertiary)
                        Text("\(displayTemp(info.predictionSetPointTemperature), specifier: "%.1f")\(unitSymbol)")
                            .monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        Text("Est. Core")
                            .foregroundStyle(.tertiary)
                        Text("\(displayTemp(info.estimatedCoreTemperature), specifier: "%.1f")\(unitSymbol)")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
            }

            if info.percentThroughCook > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: isReady ? [.green, .green.opacity(0.7)] : [stateColor.opacity(0.6), stateColor],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * min(CGFloat(info.percentThroughCook) / 100.0, 1.0), height: 6)
                        }
                    }
                    .frame(height: 6)
                    Text("\(info.percentThroughCook)% complete")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .opacity(isNotInserted ? 0.35 : 1.0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isReady ? Color.green.opacity(0.08) : Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isReady ? Color.green.opacity(0.25) : Color(.separatorColor), lineWidth: 1)
        )
        .shadow(color: isReady ? .green.opacity(0.15) : .clear, radius: 12, y: 2)
    }

    private func predictionStateLabel(_ state: PredictionState) -> String {
        switch state {
        case .probeNotInserted: return "Probe Not Inserted"
        case .probeInserted: return "Probe Inserted"
        case .cooking: return "Heating..."
        case .predicting: return "Predicting"
        case .removalPredictionDone: return "Ready to Remove"
        default: return "Unknown"
        }
    }

    private func predictionStateIcon(_ state: PredictionState) -> String {
        switch state {
        case .probeNotInserted: return "arrow.down.to.line"
        case .probeInserted: return "thermometer.medium"
        case .cooking: return "flame"
        case .predicting: return "clock"
        case .removalPredictionDone: return "checkmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private func predictionStateColor(_ state: PredictionState) -> Color {
        switch state {
        case .cooking: return .orange
        case .predicting: return .blue
        case .removalPredictionDone: return .green
        default: return .secondary
        }
    }

    private func formatCountdown(_ seconds: UInt) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HISTORY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)

            if viewModel.chartData.isEmpty {
                emptyChartPlaceholder
            } else {
                temperatureChart
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(.separatorColor), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyChartPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No Data Yet")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Connect to probe to sync temperature history")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separatorColor), lineWidth: 1)
        )
    }

    private var chartYDomain: ClosedRange<Double> {
        var allValues: [Double] = []
        for point in viewModel.displayData {
            if showCore { allValues.append(displayTemp(point.core)) }
            if showSurface { allValues.append(displayTemp(point.surface)) }
            if showAmbient { allValues.append(displayTemp(point.ambient)) }
            if showGauge, let g = point.gauge { allValues.append(displayTemp(g)) }
        }
        if let targetC = viewModel.targetTemperatureCelsius {
            allValues.append(displayTemp(targetC))
        }
        let minVal = allValues.min() ?? 0
        let maxVal = allValues.max() ?? 100
        let range = max(maxVal - minVal, 10)
        let padding = range * 0.08
        return (minVal - padding) ... (maxVal + padding)
    }

    private var temperatureChart: some View {
        Chart {
            ForEach(viewModel.displayData) { point in
                if showCore {
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Core", displayTemp(point.core)),
                        series: .value("Series", TemperatureChartPlottable.core.rawValue)
                    )
                    .foregroundStyle(by: .value("Series", TemperatureChartPlottable.core))
                }

                if showSurface {
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Surface", displayTemp(point.surface)),
                        series: .value("Series", TemperatureChartPlottable.surface.rawValue)
                    )
                    .foregroundStyle(by: .value("Series", TemperatureChartPlottable.surface))
                }

                if showAmbient {
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Ambient", displayTemp(point.ambient)),
                        series: .value("Series", TemperatureChartPlottable.ambient.rawValue)
                    )
                    .foregroundStyle(by: .value("Series", TemperatureChartPlottable.ambient))
                }

                if showGauge, let gaugeTemp = point.gauge {
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Gauge", displayTemp(gaugeTemp)),
                        series: .value("Series", TemperatureChartPlottable.gauge.rawValue)
                    )
                    .foregroundStyle(by: .value("Series", TemperatureChartPlottable.gauge))
                }
            }

            if let targetC = viewModel.targetTemperatureCelsius {
                RuleMark(y: .value("Target", displayTemp(targetC)))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(.green.opacity(0.7))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Target \(displayTemp(targetC), specifier: "%.0f")\(unitSymbol)")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
            }

            if let hover = hoverInfo {
                RuleMark(x: .value("Hover", hover.point.timestamp))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.primary.opacity(0.6))
                    .annotation(
                        position: annotationPosition(for: hover.point),
                        alignment: .center,
                        spacing: 8
                    ) {
                        chartTooltip(for: hover.point)
                    }
            }
        }
        .chartForegroundStyleScale(mapping: { (plottable: TemperatureChartPlottable) -> Color in
            plottable.color
        })
        .chartYScale(domain: chartYDomain)
        .chartYAxis {
            AxisMarks { value in
                if let temp = value.as(Int.self) {
                    AxisGridLine()
                    AxisValueLabel {
                        Text("\(temp)°")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { value in
                if let date = value.as(Date.self) {
                    AxisGridLine()
                    AxisValueLabel {
                        Text(Self.timestampFormatter.string(from: date))
                    }
                }
            }
        }
        .chartYAxisLabel("Temperature (\(unitSymbol))")
        .chartOverlay { proxy in
            Color.clear
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if let dateValue: Date = proxy.value(atX: location.x) {
                            if let closest = viewModel.closestPoint(to: dateValue) {
                                hoverInfo = LiveChartHoverInfo(position: 0, point: closest)
                            }
                        }
                    case .ended:
                        hoverInfo = nil
                    }
                }
        }
        .frame(height: 320)
        .drawingGroup()
    }

    private func annotationPosition(for point: LiveChartDataPoint) -> AnnotationPosition {
        guard let first = viewModel.displayData.first, let last = viewModel.displayData.last else { return .trailing }
        let totalRange = last.timeSeconds - first.timeSeconds
        guard totalRange > 0 else { return .trailing }
        let relativePosition = (point.timeSeconds - first.timeSeconds) / totalRange
        return relativePosition > 0.75 ? .leading : .trailing
    }

    private func chartTooltip(for point: LiveChartDataPoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Self.hoverTimestampFormatter.string(from: point.timestamp))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)

            if showCore {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(TemperatureChartPlottable.core.color).frame(width: 8, height: 8)
                    Text("Core: \(displayTemp(point.core), specifier: "%.1f")\(unitSymbol)")
                }
            }
            if showSurface {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(TemperatureChartPlottable.surface.color).frame(width: 8, height: 8)
                    Text("Surface: \(displayTemp(point.surface), specifier: "%.1f")\(unitSymbol)")
                }
            }
            if showAmbient {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(TemperatureChartPlottable.ambient.color).frame(width: 8, height: 8)
                    Text("Ambient: \(displayTemp(point.ambient), specifier: "%.1f")\(unitSymbol)")
                }
            }
            if showGauge, let gaugeTemp = point.gauge {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(TemperatureChartPlottable.gauge.color).frame(width: 8, height: 8)
                    Text("Gauge: \(displayTemp(gaugeTemp), specifier: "%.1f")\(unitSymbol)")
                }
            }

            Text(TimeInterval(point.timeSeconds).hourMinuteFormat() + " elapsed")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEVICE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)

            HStack(spacing: 16) {
                infoItem(label: "Serial", value: viewModel.probe.serialNumberString)
                infoItem(label: "Connection", value: isConnected ? "Direct" : (viewModel.probe.lastNormalModeHopCount != nil ? "Via MeatNet" : "Disconnected"))
                if let fw = viewModel.probe.firmareVersion {
                    infoItem(label: "Firmware", value: fw)
                }
                if let percent = viewModel.probe.percentOfLogsSynced {
                    infoItem(label: "Logs Synced", value: "\(percent)%")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func infoItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .tracking(0.3)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - TemperatureRow (preserved)

struct TemperatureRow: View {
    let label: String
    let celsius: Double

    private var fahrenheit: Double { celsius * 9.0 / 5.0 + 32.0 }

    var body: some View {
        LabeledContent(label) {
            Text("\(celsius, specifier: "%.1f")°C / \(fahrenheit, specifier: "%.1f")°F")
                .monospacedDigit()
        }
    }
}

// MARK: - Preview

#Preview {
    LiveProbeView(
        viewModel: LiveProbeViewModel(probe: SimulatedProbe())
    )
}

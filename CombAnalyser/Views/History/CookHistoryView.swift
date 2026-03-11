//
//  CookHistoryView.swift
//  CombAnalyser
//

import Charts
import SwiftUI

struct CookHistoryView: View {
    @ObservedObject private var store = CookSessionStore.shared
    @AppStorage(AppSettingsKeys.temperatureUnit.rawValue) private var temperatureUnit: TemperatureUnit = .celsius

    private var isFahrenheit: Bool { temperatureUnit == .fahrenheit }

    var body: some View {
        NavigationView {
            List {
                if store.sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("No cook history yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Sessions are saved automatically while monitoring probes.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(store.sessions) { session in
                        NavigationLink(destination: CookHistoryDetailView(session: session)) {
                            CookHistoryRow(session: session, isFahrenheit: isFahrenheit)
                        }
                    }
                    .onDelete { indices in
                        for index in indices {
                            store.delete(store.sessions[index])
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 260)
            .navigationTitle("Cook History")
        }
    }
}

struct CookHistoryRow: View {
    let session: PersistedCookSession
    let isFahrenheit: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Probe \(session.probeSerial)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(Self.dateFormatter.string(from: session.startDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if let peak = session.peakCoreCelsius {
                    let displayed = isFahrenheit ? peak * 9.0 / 5.0 + 32.0 : peak
                    let unit = isFahrenheit ? "°F" : "°C"
                    Text(String(format: "Peak: %.0f%@", displayed, unit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(TimeInterval(session.duration).hourMinuteFormat())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if session.gaugeSerial != nil {
                    Label("Gauge", systemImage: "thermometer.sun")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct CookHistoryDetailView: View {
    let session: PersistedCookSession
    @AppStorage(AppSettingsKeys.temperatureUnit.rawValue) private var temperatureUnit: TemperatureUnit = .celsius

    @State private var showCore = true
    @State private var showSurface = true
    @State private var showAmbient = true
    @State private var showGauge = true
    @State private var hoverPoint: PersistedTemperaturePoint?

    private var isFahrenheit: Bool { temperatureUnit == .fahrenheit }
    private var unitSymbol: String { isFahrenheit ? "°F" : "°C" }

    private var downsampledPoints: [PersistedTemperaturePoint] {
        lttbDownsamplePersisted(session.dataPoints, to: 600)
    }

    private func displayTemp(_ celsius: Double) -> Double {
        isFahrenheit ? celsius * 9.0 / 5.0 + 32.0 : celsius
    }

    private func closestPoint(to date: Date, in points: [PersistedTemperaturePoint]) -> PersistedTemperaturePoint? {
        guard !points.isEmpty else { return nil }
        let target = date.timeIntervalSince1970
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].timestamp.timeIntervalSince1970 < target { lo = mid + 1 } else { hi = mid }
        }
        var best = lo
        if lo > 0 {
            let dLo = abs(points[lo].timestamp.timeIntervalSince1970 - target)
            let dPrev = abs(points[lo - 1].timestamp.timeIntervalSince1970 - target)
            if dPrev < dLo { best = lo - 1 }
        }
        return points[best]
    }

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

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sessionHeader
                Divider().padding(.horizontal)
                temperatureCards
                Divider().padding(.horizontal)
                chartSection
            }
        }
        .navigationTitle("Probe \(session.probeSerial)")
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Probe \(session.probeSerial)")
                .font(.title2.bold())
            HStack(spacing: 16) {
                Label(Self.headerDateFormatter.string(from: session.startDate), systemImage: "calendar")
                Label(TimeInterval(session.duration).hourMinuteFormat(), systemImage: "clock")
                if let gauge = session.gaugeSerial {
                    Label(gauge, systemImage: "thermometer.sun")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let target = session.targetTemperatureCelsius {
                Label(String(format: "Target: %.0f%@", displayTemp(target), unitSymbol), systemImage: "target")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding()
    }

    private var temperatureCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Peak Temperatures")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                peakCard(label: "Core", celsius: session.dataPoints.max(by: { $0.core < $1.core })?.core,
                         color: TemperatureChartPlottable.core.color, isEnabled: $showCore)
                peakCard(label: "Surface", celsius: session.dataPoints.max(by: { $0.surface < $1.surface })?.surface,
                         color: TemperatureChartPlottable.surface.color, isEnabled: $showSurface)
                peakCard(label: "Ambient", celsius: session.dataPoints.max(by: { $0.ambient < $1.ambient })?.ambient,
                         color: TemperatureChartPlottable.ambient.color, isEnabled: $showAmbient)

                if session.dataPoints.contains(where: { $0.gauge != nil }) {
                    let peakGauge = session.dataPoints.compactMap({ $0.gauge }).max()
                    peakCard(label: "Gauge", celsius: peakGauge,
                             color: TemperatureChartPlottable.gauge.color, isEnabled: $showGauge)
                }
            }
        }
        .padding()
    }

    private func peakCard(label: String, celsius: Double?, color: Color, isEnabled: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isEnabled.wrappedValue ? color : color.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(isEnabled.wrappedValue ? .secondary : .tertiary)
            }
            if let c = celsius {
                Text("\(displayTemp(c), specifier: "%.1f")\(unitSymbol)")
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(isEnabled.wrappedValue ? .primary : .tertiary)
            } else {
                Text("--")
                    .font(.title3.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(isEnabled.wrappedValue ? 0.15 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isEnabled.wrappedValue ? color.opacity(0.4) : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isEnabled.wrappedValue.toggle()
            }
        }
    }

    private func historyChartYDomain(points: [PersistedTemperaturePoint]) -> ClosedRange<Double> {
        var allValues: [Double] = []
        for point in points {
            if showCore { allValues.append(displayTemp(point.core)) }
            if showSurface { allValues.append(displayTemp(point.surface)) }
            if showAmbient { allValues.append(displayTemp(point.ambient)) }
            if showGauge, let g = point.gauge { allValues.append(displayTemp(g)) }
        }
        if let targetC = session.targetTemperatureCelsius {
            allValues.append(displayTemp(targetC))
        }
        let minVal = allValues.min() ?? 0
        let maxVal = allValues.max() ?? 100
        let range = max(maxVal - minVal, 10)
        let padding = range * 0.08
        return (minVal - padding) ... (maxVal + padding)
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Temperature History")
                .font(.headline)
                .foregroundStyle(.secondary)

            if session.dataPoints.isEmpty {
                Text("No temperature data recorded")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            } else {
                let points = downsampledPoints
                Chart {
                    ForEach(points) { point in
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

                    if let target = session.targetTemperatureCelsius {
                        RuleMark(y: .value("Target", displayTemp(target)))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .foregroundStyle(.green.opacity(0.7))
                    }

                    if let hover = hoverPoint {
                        RuleMark(x: .value("Hover", hover.timestamp))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.primary.opacity(0.6))
                            .annotation(
                                position: hoverAnnotationPosition(for: hover),
                                alignment: .center,
                                spacing: 8
                            ) {
                                historyTooltip(for: hover)
                            }
                    }
                }
                .chartForegroundStyleScale(mapping: { (plottable: TemperatureChartPlottable) -> Color in
                    plottable.color
                })
                .chartYScale(domain: historyChartYDomain(points: points))
                .chartYAxis {
                    AxisMarks { value in
                        if let temp = value.as(Int.self) {
                            AxisGridLine()
                            AxisValueLabel { Text("\(temp)°") }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour)) { value in
                        if let date = value.as(Date.self) {
                            AxisGridLine()
                            AxisValueLabel { Text(Self.timestampFormatter.string(from: date)) }
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
                                    hoverPoint = closestPoint(to: dateValue, in: points)
                                }
                            case .ended:
                                hoverPoint = nil
                            }
                        }
                }
                .frame(height: 320)
                .drawingGroup()
            }
        }
        .padding()
    }

    private func hoverAnnotationPosition(for point: PersistedTemperaturePoint) -> AnnotationPosition {
        guard let first = session.dataPoints.first, let last = session.dataPoints.last else { return .trailing }
        let totalRange = last.timestamp.timeIntervalSince(first.timestamp)
        guard totalRange > 0 else { return .trailing }
        let relativePosition = point.timestamp.timeIntervalSince(first.timestamp) / totalRange
        return relativePosition > 0.75 ? .leading : .trailing
    }

    private func historyTooltip(for point: PersistedTemperaturePoint) -> some View {
        let elapsed = point.timestamp.timeIntervalSince(session.startDate)
        return VStack(alignment: .leading, spacing: 5) {
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

            Text(elapsed.hourMinuteFormat() + " elapsed")
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
}

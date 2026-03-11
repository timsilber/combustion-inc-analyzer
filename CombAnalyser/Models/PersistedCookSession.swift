//
//  PersistedCookSession.swift
//  CombAnalyser
//

import Foundation

struct PersistedTemperaturePoint: Codable, Identifiable {
    var id: Date { timestamp }

    let timestamp: Date
    /// All temperatures in Celsius — converted to F only at display time.
    let core: Double
    let surface: Double
    let ambient: Double
    let gauge: Double?
}

struct PersistedCookSession: Codable, Identifiable {
    let id: UUID
    let probeSerial: String
    /// SDK SessionInformation.sessionID — nil if not yet received from probe.
    let sdkSessionID: UInt32?
    let startDate: Date
    var endDate: Date?
    var dataPoints: [PersistedTemperaturePoint]

    var gaugeSerial: String?
    var gaugeOnlyPoints: [PersistedGaugePoint]

    var targetTemperatureCelsius: Double?
    var notes: String?

    var duration: TimeInterval {
        let end = endDate ?? (dataPoints.last?.timestamp ?? startDate)
        return end.timeIntervalSince(startDate)
    }

    var peakCoreCelsius: Double? {
        dataPoints.max(by: { $0.core < $1.core })?.core
    }
}

struct PersistedGaugePoint: Codable {
    let timestamp: Date
    let celsius: Double
}

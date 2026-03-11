//  GaugeAdvertisingData.swift
//  Parses Gauge-specific BLE advertisements (product type 0x03)
//
//  Based on gauge_ble_specification.rst from combustion-inc/combustion-documentation

import Foundation

/// Gauge status flags packed in 1 byte
public struct GaugeStatusFlags {
    public let sensorPresent: Bool
    public let sensorOverheating: Bool
    public let lowBattery: Bool
}

/// Individual alarm status (16 bits)
public struct GaugeAlarmStatus {
    public let isSet: Bool
    public let isTripped: Bool
    public let isAlarming: Bool
    /// Alarm temperature in Celsius
    public let temperatureCelsius: Double
}

/// High-Low alarm status (32 bits)
public struct GaugeHighLowAlarmStatus {
    public let high: GaugeAlarmStatus
    public let low: GaugeAlarmStatus
}

/// Gauge preferences (1 byte)
public struct GaugePreferences {
    public let highRadioPower: Bool
}

/// Parsed advertising data specific to the Giant Grill Gauge.
///
/// Manufacturer Specific Data layout (24 bytes):
///   Vendor ID:              2 bytes  (0x09C7)
///   Product Type:           1 byte   (0x03 = Gauge)
///   Serial Number:         10 bytes  (alphanumeric)
///   Raw Temperature Data:   2 bytes  (13-bit, 0.1°C, offset -20)
///   Gauge Status Flags:     1 byte
///   Reserved:               1 byte
///   High-Low Alarm Status:  4 bytes
///   Gauge Preferences:      1 byte
///   Reserved:               3 bytes  (total = 25 with vendor ID at front? spec says 24)
public struct GaugeAdvertisingData {
    /// Gauge serial number (alphanumeric string, up to 10 chars)
    public let serialNumber: String
    /// Current temperature in Celsius from the Gauge's thermistor
    public let temperatureCelsius: Double
    /// Status flags
    public let statusFlags: GaugeStatusFlags
    /// High/Low alarm configuration and status
    public let alarmStatus: GaugeHighLowAlarmStatus?
    /// Gauge preferences
    public let preferences: GaugePreferences?
}

extension GaugeAdvertisingData {
    private enum Constants {
        static let VENDOR_ID_RANGE = 0..<2
        static let PRODUCT_TYPE_INDEX = 2
        static let SERIAL_RANGE = 3..<13       // 10 bytes alphanumeric
        static let RAW_TEMP_RANGE = 13..<15     // 2 bytes
        static let STATUS_FLAGS_INDEX = 15
        static let RESERVED1_INDEX = 16
        static let ALARM_STATUS_RANGE = 17..<21 // 4 bytes
        static let PREFERENCES_INDEX = 21

        static let COMBUSTION_VENDOR_ID: UInt16 = 0x09C7
    }

    /// Attempt to parse Gauge advertising data from raw manufacturer data.
    /// Returns nil if data is too short or vendor ID doesn't match.
    init?(fromData data: Data?) {
        guard let data = data, data.count >= 16 else { return nil }

        // Verify vendor ID
        let vendorID = data.subdata(in: Constants.VENDOR_ID_RANGE).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard vendorID == Constants.COMBUSTION_VENDOR_ID else { return nil }

        // Verify product type
        guard data[Constants.PRODUCT_TYPE_INDEX] == CombustionProductType.gauge.rawValue else { return nil }

        // Serial number: 10 bytes, ASCII alphanumeric, trim null bytes
        let serialData = data.subdata(in: Constants.SERIAL_RANGE)
        serialNumber = String(bytes: serialData, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""

        // Raw temperature: 13-bit packed unsigned integer, 0.1°C resolution, offset -20°C
        // Bits 1-13 = thermistor reading, bits 14-16 = reserved
        let rawTempBytes = data.subdata(in: Constants.RAW_TEMP_RANGE)
        let rawValue = UInt16(rawTempBytes[0]) | (UInt16(rawTempBytes[1]) << 8)
        let thermistorRaw = rawValue & 0x1FFF  // 13 bits
        temperatureCelsius = (Double(thermistorRaw) * 0.1) - 20.0

        // Gauge status flags
        let flagsByte = data[Constants.STATUS_FLAGS_INDEX]
        statusFlags = GaugeStatusFlags(
            sensorPresent: (flagsByte & 0x01) != 0,
            sensorOverheating: (flagsByte & 0x02) != 0,
            lowBattery: (flagsByte & 0x04) != 0
        )

        // High-Low alarm status (if data is long enough)
        if data.count >= 21 {
            let alarmData = data.subdata(in: Constants.ALARM_STATUS_RANGE)
            let highAlarmRaw = UInt16(alarmData[0]) | (UInt16(alarmData[1]) << 8)
            let lowAlarmRaw = UInt16(alarmData[2]) | (UInt16(alarmData[3]) << 8)
            alarmStatus = GaugeHighLowAlarmStatus(
                high: Self.parseAlarmStatus(rawValue: highAlarmRaw),
                low: Self.parseAlarmStatus(rawValue: lowAlarmRaw)
            )
        } else {
            alarmStatus = nil
        }

        // Preferences
        if data.count >= 22 {
            let prefByte = data[Constants.PREFERENCES_INDEX]
            preferences = GaugePreferences(highRadioPower: (prefByte & 0x01) != 0)
        } else {
            preferences = nil
        }
    }

    /// Parse a 16-bit alarm status field
    private static func parseAlarmStatus(rawValue: UInt16) -> GaugeAlarmStatus {
        let isSet = (rawValue & 0x0001) != 0
        let isTripped = (rawValue & 0x0002) != 0
        let isAlarming = (rawValue & 0x0004) != 0
        let tempRaw = (rawValue >> 3) & 0x1FFF
        let tempCelsius = (Double(tempRaw) * 0.1) - 20.0
        return GaugeAlarmStatus(
            isSet: isSet,
            isTripped: isTripped,
            isAlarming: isAlarming,
            temperatureCelsius: tempCelsius
        )
    }
}

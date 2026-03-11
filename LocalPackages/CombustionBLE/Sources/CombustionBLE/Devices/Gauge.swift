import Foundation

public class Gauge: Device {

    @Published public private(set) var serialNumberString: String
    @Published public private(set) var temperatureCelsius: Double
    @Published public private(set) var temperatureFahrenheit: Double
    @Published public private(set) var sensorPresent: Bool
    @Published public private(set) var sensorOverheating: Bool
    @Published public private(set) var lowBattery: Bool
    @Published public private(set) var alarmStatus: GaugeHighLowAlarmStatus?
    @Published public private(set) var highRadioPower: Bool

    init(_ gaugeAd: GaugeAdvertisingData, isConnectable: Bool, RSSI: NSNumber, identifier: UUID) {
        serialNumberString = gaugeAd.serialNumber
        temperatureCelsius = gaugeAd.temperatureCelsius
        temperatureFahrenheit = gaugeAd.temperatureCelsius * 9.0 / 5.0 + 32.0
        sensorPresent = gaugeAd.statusFlags.sensorPresent
        sensorOverheating = gaugeAd.statusFlags.sensorOverheating
        lowBattery = gaugeAd.statusFlags.lowBattery
        alarmStatus = gaugeAd.alarmStatus
        highRadioPower = gaugeAd.preferences?.highRadioPower ?? false

        super.init(uniqueIdentifier: "gauge-\(gaugeAd.serialNumber)", bleIdentifier: identifier, RSSI: RSSI)
        self.isConnectable = isConnectable
    }

    func updateWithGaugeAdvertising(_ gaugeAd: GaugeAdvertisingData, isConnectable: Bool, RSSI: NSNumber) {
        self.rssi = RSSI.intValue
        self.isConnectable = isConnectable

        if gaugeAd.statusFlags.sensorPresent {
            temperatureCelsius = gaugeAd.temperatureCelsius
            temperatureFahrenheit = gaugeAd.temperatureCelsius * 9.0 / 5.0 + 32.0
        }

        sensorPresent = gaugeAd.statusFlags.sensorPresent
        sensorOverheating = gaugeAd.statusFlags.sensorOverheating
        lowBattery = gaugeAd.statusFlags.lowBattery
        alarmStatus = gaugeAd.alarmStatus
        highRadioPower = gaugeAd.preferences?.highRadioPower ?? false

        lastUpdateTime = Date()
    }
}

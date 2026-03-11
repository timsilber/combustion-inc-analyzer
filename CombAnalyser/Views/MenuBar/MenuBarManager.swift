//
//  MenuBarManager.swift
//  CombAnalyser
//

import AppKit
import Combine
import CombustionBLE
import SwiftUI

class MenuBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var subscribers: Set<AnyCancellable> = []
    private weak var liveViewModel: LiveViewModel?
    private var updateTimer: AnyCancellable?

    func start(liveViewModel: LiveViewModel) {
        self.liveViewModel = liveViewModel

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "CombAnalyser")
        statusItem?.button?.imagePosition = .imageLeading

        liveViewModel.$probes
            .combineLatest(liveViewModel.$gauges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.rebuildMenu()
            }
            .store(in: &subscribers)

        updateTimer = Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateButtonTitle()
                self?.rebuildMenu()
            }

        rebuildMenu()
    }

    private func updateButtonTitle() {
        guard let liveViewModel = liveViewModel else { return }
        let isFahrenheit = UserDefaults.standard.string(forKey: AppSettingsKeys.temperatureUnit.rawValue) == "fahrenheit"

        if let probe = liveViewModel.probes.first,
           let temps = probe.virtualTemperatures {
            let core = isFahrenheit ? temps.coreTemperature * 9.0 / 5.0 + 32.0 : temps.coreTemperature
            let unit = isFahrenheit ? "F" : "C"
            statusItem?.button?.title = String(format: " %.0f°%@", core, unit)
        } else if let gauge = liveViewModel.gauges.first, gauge.sensorPresent {
            let temp = isFahrenheit ? gauge.temperatureFahrenheit : gauge.temperatureCelsius
            let unit = isFahrenheit ? "F" : "C"
            statusItem?.button?.title = String(format: " %.0f°%@", temp, unit)
        } else {
            statusItem?.button?.title = ""
        }
    }

    private func rebuildMenu() {
        guard let liveViewModel = liveViewModel else { return }
        let isFahrenheit = UserDefaults.standard.string(forKey: AppSettingsKeys.temperatureUnit.rawValue) == "fahrenheit"
        let unit = isFahrenheit ? "°F" : "°C"

        let menu = NSMenu()

        if liveViewModel.probes.isEmpty && liveViewModel.gauges.isEmpty {
            menu.addItem(NSMenuItem(title: "No devices connected", action: nil, keyEquivalent: ""))
        }

        for probe in liveViewModel.probes {
            let header = NSMenuItem(title: "Probe \(probe.serialNumberString)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            if let temps = probe.virtualTemperatures {
                let core = isFahrenheit ? temps.coreTemperature * 9.0 / 5.0 + 32.0 : temps.coreTemperature
                let surface = isFahrenheit ? temps.surfaceTemperature * 9.0 / 5.0 + 32.0 : temps.surfaceTemperature
                let ambient = isFahrenheit ? temps.ambientTemperature * 9.0 / 5.0 + 32.0 : temps.ambientTemperature
                menu.addItem(NSMenuItem(title: String(format: "  Core: %.1f%@", core, unit), action: nil, keyEquivalent: ""))
                menu.addItem(NSMenuItem(title: String(format: "  Surface: %.1f%@", surface, unit), action: nil, keyEquivalent: ""))
                menu.addItem(NSMenuItem(title: String(format: "  Ambient: %.1f%@", ambient, unit), action: nil, keyEquivalent: ""))
            } else {
                menu.addItem(NSMenuItem(title: "  Waiting for data...", action: nil, keyEquivalent: ""))
            }

            if let info = probe.predictionInfo, let seconds = info.secondsRemaining {
                let m = (seconds % 3600) / 60
                let s = seconds % 60
                let timeStr = seconds >= 3600
                    ? String(format: "%d:%02d:%02d", seconds / 3600, m, s)
                    : String(format: "%d:%02d", m, s)
                menu.addItem(NSMenuItem(title: "  ETA: \(timeStr)", action: nil, keyEquivalent: ""))
            }

            menu.addItem(NSMenuItem.separator())
        }

        for gauge in liveViewModel.gauges {
            let header = NSMenuItem(title: "Gauge \(gauge.serialNumberString)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            if gauge.sensorPresent {
                let temp = isFahrenheit ? gauge.temperatureFahrenheit : gauge.temperatureCelsius
                menu.addItem(NSMenuItem(title: String(format: "  Temp: %.1f%@", temp, unit), action: nil, keyEquivalent: ""))
            } else {
                menu.addItem(NSMenuItem(title: "  No sensor", action: nil, keyEquivalent: ""))
            }

            menu.addItem(NSMenuItem.separator())
        }

        let openItem = NSMenuItem(title: "Open CombAnalyser", action: #selector(Self.activateApp), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        statusItem?.menu = menu
    }

    @objc private func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

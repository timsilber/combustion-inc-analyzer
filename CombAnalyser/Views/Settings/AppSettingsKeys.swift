//
//  AppSettingsKeys.swift
//  CombustionIncAnalyser
//
//  Created by Michael Schinis on 15/11/2023.
//

import SwiftUI

enum AppSettingsKeys: String {
    case temperatureUnit = "temperatureUnit"
    case appearanceMode = "appearanceMode"
}

enum AppearanceMode: String, Codable, Identifiable, CaseIterable {
    var id: String { rawValue }

    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

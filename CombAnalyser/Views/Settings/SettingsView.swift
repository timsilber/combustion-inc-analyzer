//
//  SettingsView.swift
//  CombustionIncAnalyser
//
//  Created by Michael Schinis on 14/11/2023.
//

import Factory
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettingsKeys.temperatureUnit.rawValue) private var temperatureUnit: TemperatureUnit = .celsius
    @AppStorage(AppSettingsKeys.appearanceMode.rawValue) private var appearanceMode: AppearanceMode = .system

    @State private var isDeleteAccountDialogVisible = false

    @Environment(\.dismiss) private var dismiss
    @InjectedObject(\.authService) private var authService: AuthService

    func logout() {
        Task {
            do {
                try authService.logout()
            } catch {
                print("Auth:: Failed logging out")
            }
        }
    }

    func didConfirmDeleteAccount() {
        authService.reauthenticateAndDeleteAccount()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $temperatureUnit) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            Text(unit.rawValue.capitalized).tag(unit)
                        }
                    } label: {
                        Text("Temperature Unit")
                    }

                    Picker(selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    } label: {
                        Text("Appearance")
                    }
                } header: {
                    Text("Display")
                        .bold()
                }

                if authService.user != nil {
                    Button(role: .destructive) {
                        isDeleteAccountDialogVisible.toggle()
                    } label: {
                        Text("Delete account")
                    }
                    .macPadding(.top, 16)
                }
            }
            .macPadding()
            .macWrappedScrollview()
            .navigationTitle("Settings")
            .macPadding(8)
        }
        .confirmationDialog("Delete account?", isPresented: $isDeleteAccountDialogVisible) {
            Button("Delete", role: .destructive, action: didConfirmDeleteAccount)
        } message: {
            Text("You'll lose all your stored cooks. We can't recover them once you delete.\n\nYou will first be prompted to login, to authenticate you.")
        }
    }
}

#Preview {
    SettingsView()
}

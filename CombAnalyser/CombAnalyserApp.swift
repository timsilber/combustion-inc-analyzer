//
//  CombAnalyserApp.swift
//  CombustionIncAnalyser
//
//  Created by Michael Schinis on 11/11/2023.
//

import Factory
import PopupView
import SwiftUI
import SwiftData
import FirebaseCore

@main
struct CombAnalyserApp: App {
    @State private var crossCompatibleSheet: CrossCompatibleWindow?

    @StateObject private var liveViewModel = LiveViewModel()
    @StateObject private var menuBarManager = MenuBarManager()

    @AppStorage(AppSettingsKeys.appearanceMode.rawValue) private var appearanceMode: AppearanceMode = .system

    @State private var popupMessage: PopupMessage?

    @Environment(\.openWindow) private var openWindow

    func openCrossCompatibleWindow(_ window: CrossCompatibleWindow) {
        #if os(macOS)
        openWindow(id: window.rawValue)
        #else
        self.crossCompatibleSheet = window
        #endif
    }

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            AppView(liveViewModel: liveViewModel)
                .preferredColorScheme(appearanceMode.colorScheme)
                .environment(\.openCrossCompatibleWindow, openCrossCompatibleWindow(_:))
                .environment(\.popupMessage, $popupMessage)
                .onAppear { menuBarManager.start(liveViewModel: liveViewModel) }
                .popup(item: $popupMessage) { item in
                    PopupMessageView(
                        message: item
                    )
                    .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 0)
                    .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 0)
                } customize: {
                    $0
                        .type(.floater())
                        .autohideIn(2)
                        .position(.top)
                }
                .sheet(item: $crossCompatibleSheet, content: { type in
                    switch type {
                    case .settings:
                        SettingsView()
                    }
                })
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Settings...") {
                    openCrossCompatibleWindow(.settings)
                }
                .keyboardShortcut(",")

                Button("Sign Out") {
                    let authService = Container.shared.authService()
                    try? authService.logout()
                }
            }
        }

        WindowGroup("Settings", id: CrossCompatibleWindow.settings.rawValue) {
            SettingsView()
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }
}

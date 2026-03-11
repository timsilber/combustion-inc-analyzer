//
//  AppView.swift
//  CombustionIncAnalyser
//
//  Created by Michael Schinis on 14/03/2024.
//

import SwiftUI

struct AppView: View {
    enum Tab {
        case live
        case history
        case settings
    }

    @State private var currentTab: Tab = .live
    @ObservedObject var liveViewModel: LiveViewModel

    var body: some View {
        TabView(selection: $currentTab) {
            LiveView(viewModel: liveViewModel)
                .tag(Tab.live)
                .tabItem {
                    Label(
                        title: { Text("Live") },
                        icon: { Image(systemName: "flame") }
                    )
                }

            CookHistoryView()
                .tag(Tab.history)
                .tabItem {
                    Label(
                        title: { Text("History") },
                        icon: { Image(systemName: "clock.arrow.circlepath") }
                    )
                }

            SettingsView()
                .tag(Tab.settings)
                .tabItem {
                    Label(
                        title: { Text("Settings") },
                        icon: { Image(systemName: "gear") }
                    )
                }
        }
    }
}

#Preview {
    AppView(liveViewModel: LiveViewModel())
}

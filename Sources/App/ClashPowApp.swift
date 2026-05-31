// ClashPowApp — macOS mihomo GUI client.
import SwiftUI

@main
struct ClashPowApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(model.dark ? .dark : .light)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.titleBar)

        MenuBarExtra {
            MenuBarPanel().environmentObject(model)
        } label: {
            Image(systemName: model.reachable ? "bolt.fill" : "bolt.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

// ClashPowApp.swift — macOS mihomo GUI client
import SwiftUI

@main
struct ClashPowApp: App {
    @StateObject private var S = AppState()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(S)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { S.traffic.start(); S.connectToEngine() }
        }
        .windowStyle(.automatic).defaultSize(width: 1200, height: 800)
        .commands { SidebarCommands() }

        MenuBarExtra {
            MenuBarPanel().environmentObject(S)
        } label: {
            HStack(spacing: 3) {
                Circle().fill(S.running ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(menuBarText).font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }

    var menuBarText: String {
        let dl = S.traffic.down.last ?? 0
        if dl >= 1_000_000 { return String(format: "%.1fM", dl / 1_000_000) }
        if dl >= 1_000 { return String(format: "%.0fK", dl / 1_000) }
        return "0K"
    }
}

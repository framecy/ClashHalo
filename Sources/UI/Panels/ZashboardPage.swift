import SwiftUI
import AppKit

struct ZashboardPage: View {
    @EnvironmentObject var M: AppModel
    
    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "Zashboard", desc: "轻量级 Mihomo/Clash 可视化面板") {
                Button(action: { M.zashboardURL = "https://board.zash.run.place/" }) {
                    Label("重置 URL", systemImage: "arrow.counterclockwise")
                }.buttonStyle(.bordered)
                
                if let url = externalURL {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Label("浏览器打开", systemImage: "safari")
                    }
                }
            }
            
            if let url = configuredURL {
                WebView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    .padding([.horizontal, .bottom], DS.Spacing.l)
                    .id(url.absoluteString) // Re-load if URL parameters change
            } else {
                ContentUnavailable("无法构造面板 URL，请检查配置", "exclamationmark.triangle")
            }
        }
    }
    
    private var externalURL: URL? {
        let host = M.api.host
        let port = String(M.api.port)
        let secret = M.api.secret
        let isDark = NSApp.effectiveAppearance.name == .darkAqua || NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        
        var baseString = M.zashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseString.hasSuffix("/") && !baseString.hasSuffix("index.html") { baseString += "/" }
        
        var urlString = baseString + "#/?"
        urlString += "hostname=\(host)"
        urlString += "&port=\(port)"
        urlString += "&secret=\(secret)"
        urlString += "&https=false"
        urlString += "&theme=\(isDark ? "dark" : "light")"
        
        return URL(string: urlString)
    }

    private var configuredURL: URL? {
        let host = M.api.host
        let port = String(M.api.port)
        let secret = M.api.secret
        let isDark = NSApp.effectiveAppearance.name == .darkAqua || NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        
        var baseString = M.zashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Plan B: Use local bundle if available
        if let localPath = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: "zashboard/dist") {
            baseString = "file://" + localPath
        }
        
        if !baseString.hasSuffix("/") && !baseString.hasSuffix("index.html") { baseString += "/" }
        
        // Zashboard uses Hash routing. Parameters MUST be after the #/ to be picked up correctly.
        var urlString = baseString + "#/?"
        urlString += "hostname=\(host)"
        urlString += "&port=\(port)"
        urlString += "&secret=\(secret)"
        urlString += "&https=false"
        urlString += "&theme=\(isDark ? "dark" : "light")"
        
        return URL(string: urlString)
    }
}

import SwiftUI
import WebKit

struct SubStorePage: View {
    @StateObject private var engine = SubStoreEngine.shared
    
    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "Sub-Store", desc: "本地高级订阅管理器") {
                Button {
                    if let url = URL(string: "http://127.0.0.1:\(engine.port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("在浏览器中打开", systemImage: "safari")
                }
            }
            
            if engine.isRunning {
                SubStoreWebView(url: URL(string: "http://127.0.0.1:\(engine.port)")!)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在启动 Sub-Store 引擎...").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            engine.start()
        }
    }
}

struct SubStoreWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        let script = WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        
        let webView = WKWebView(frame: .zero, configuration: config)
        // Set a transparent background
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

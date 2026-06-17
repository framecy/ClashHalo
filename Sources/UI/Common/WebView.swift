import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let url: URL
    var injectionJS: String? = nil
    var onCommit: ((WKWebView) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Allow cross-origin requests for local files
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        
        // Ensure JavaScript can run and access local storage
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        
        // Inject custom JS if provided
        if let js = injectionJS {
            let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(script)
        }
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground") // Make it transparent if content is
        
        // Disable scroll bouncing on macOS (optional, depends on look & feel)
        if let scrollView = webView.enclosingScrollView {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
        }
        
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            if url.isFileURL {
                // For local files, we need to allow read access to the directory
                let directory = url.deletingLastPathComponent()
                nsView.loadFileURL(url, allowingReadAccessTo: directory)
            } else {
                let request = URLRequest(url: url)
                nsView.load(request)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView

        init(_ parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.onCommit?(webView)
        }
    }
}

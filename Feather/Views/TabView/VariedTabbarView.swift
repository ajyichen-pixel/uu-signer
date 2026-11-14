import SwiftUI
import WebKit

struct VariedTabbarView: View {
    @StateObject private var installer = UUInstallCoordinator.shared
    var body: some View {
        if Bundle.main.object(forInfoDictionaryKey: "UUCloudDelivery") as? Bool == true {
            NavigationStack {
                UUCloudStore().navigationTitle("UU 商店").navigationBarTitleDisplayMode(.inline)
            }
        } else {
            localStore
        }
    }
    private var localStore: some View {
        VStack(spacing: 0) {
            if installer.busy {
                VStack {
                    HStack {
                        ProgressView()
                        Text(installer.status).font(.footnote)
                        if installer.downloading { Button("取消") { installer.cancelDownload() } }
                    }
                    if let progress = installer.downloadProgress { ProgressView(value: progress) }
                }.padding(10)
            }
            TabbarView().tint(Color(red: 0.66, green: 0.33, blue: 0.97))
        }
        .task { await installer.prepare() }
        .sheet(item: $installer.installApp) { app in
            InstallPreviewView(app: app.base)
        }
        .alert("UU 安裝", isPresented: Binding(get: { installer.error != nil }, set: { if !$0 { installer.error = nil } })) {
            if installer.canRetry { Button("重試") { installer.retry() } }
            Button("知道了") { installer.error = nil }
        } message: { Text(installer.error ?? "") }
    }
}

// The developer signing key stays on the private backend. Customers receive
// already-signed packages through their existing, authenticated store account.
private struct UUCloudStore: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "UUSigner"
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "https://uuxp.click/#install")!))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "https", url.host == "uuxp.click", !url.path.hasPrefix("/device-enrollment/") {
                decisionHandler(.allow); return
            }
            decisionHandler(.cancel)
            if url.scheme == "itms-services",
               let manifest = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
               let target = URL(string: manifest), target.scheme == "https", target.host == "uuxp.click", target.path.hasPrefix("/install/") {
                UIApplication.shared.open(url)
            } else if url.scheme == "https", navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            webView.loadHTMLString("<meta name='viewport' content='width=device-width'><body style='background:#130b22;color:white;font:20px sans-serif;padding:24px'><h2>無法連線 UU 商店</h2><p>請檢查網路後重新嘗試。</p><a style='color:#ca9cff' href='https://uuxp.click/#install'>重新載入商店</a></body>", baseURL: URL(string: "https://uuxp.click"))
        }
    }
}

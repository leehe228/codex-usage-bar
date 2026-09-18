import AppKit
import WebKit
import CodexUsageCore

/// Owns an isolated, memory-only console login. Credentials leave WebKit only for
/// the OpenModel client; they are never placed in the account JSON or logs.
@MainActor final class OpenModelLogin: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private let status = NSTextField(labelWithString: "OpenModel에 로그인하세요. Google 로그인이 열리지 않으면 이메일 인증 코드를 이용하세요.")
    private var poll: Task<Void, Never>?
    private var checking = false
    private var lastToken: String?
    private var finished = false
    private let expected: AccountIdentity?
    private let completion: (AccountIdentity, OpenModelSnapshot, OpenModelCredential) -> Void
    private let cancelled: () -> Void
    init(expected: AccountIdentity?, completion: @escaping (AccountIdentity, OpenModelSnapshot, OpenModelCredential) -> Void, cancelled: @escaping () -> Void) {
        self.expected = expected; self.completion = completion; self.cancelled = cancelled
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "OpenModel 계정 연결"; window.isReleasedWhenClosed = false; window.delegate = self
        webView.navigationDelegate = self; webView.uiDelegate = self
        status.font = .systemFont(ofSize: 12); status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 3
        let retry = NSButton(title: "로그인 완료 확인", target: self, action: #selector(recheck))
        let header = NSStackView(views: [status, retry]); header.orientation = .horizontal; header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let content = NSView(); window.contentView = content
        for view in [header, webView] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor), header.leadingAnchor.constraint(equalTo: content.leadingAnchor), header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor), webView.leadingAnchor.constraint(equalTo: content.leadingAnchor), webView.trailingAnchor.constraint(equalTo: content.trailingAnchor), webView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.center()
    }
    func show() {
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: URL(string: "https://console.openmodel.ai/auth")!))
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !self.finished else { return }
                await self.check()
            }
        }
    }
    @objc private func recheck() { lastToken = nil; Task { await check() } }
    private func check() async {
        guard !checking, !finished, webView.url?.scheme == "https", webView.url?.host == "console.openmodel.ai" else { return }
        checking = true; defer { checking = false }
        do {
            let value = try await webView.evaluateJavaScript("JSON.parse(localStorage.getItem('auth') || '{}').state?.accessToken || ''")
            guard let token = value as? String, !token.isEmpty, token != lastToken else { return }
            lastToken = token
            status.stringValue = "잔액과 사용량을 확인하고 있습니다…"
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let client = OpenModelClient(credential: OpenModelCredential(accessToken: token, cookies: cookies.map(OpenModelCookie.init)))
            // Verify refresh-cookie authentication before installing the account.
            try await client.refreshAuthentication()
            let (identity, snapshot) = try await client.fetch(expected: expected)
            let credential = await client.currentCredential()
            guard !finished else { return }
            finished = true; poll?.cancel(); window.orderOut(nil)
            completion(identity, snapshot, credential)
        } catch {
            if !finished { status.stringValue = (error as? OpenModelError)?.localizedDescription ?? "연결을 확인하지 못했습니다. 로그인을 마친 뒤 ‘로그인 완료 확인’을 누르세요." }
        }
    }
    func cancel() { finished = true; poll?.cancel(); webView.stopLoading(); window.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { guard !finished else { return }; cancel(); cancelled() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.scheme == "https" else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.request.url?.scheme == "https" { webView.load(action.request) }
        return nil
    }
}

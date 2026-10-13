import AppKit
@preconcurrency import WebKit

struct HistoryResult: Decodable {
    var entries: [RemoteEntry]
    var canWrite: Bool
}

@MainActor
final class RefoldAdapter: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private var loginWindow: NSWindow?
    private var popupWindows: [ObjectIdentifier: NSWindow] = [:]
    var onNavigation: (() -> Void)?

    init(loadResources: Void = ()) throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let bridgeURL: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            // SPM's generated Bundle.module lookup is not relocatable inside a macOS app.
            guard let resources = Bundle.main.resourceURL else {
                throw NSError(domain: "RefoldTracker.Resources", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "App resources are missing. Reinstall Refold Tracker."])
            }
            bridgeURL = resources.appendingPathComponent("RefoldTracker_RefoldTracker.bundle/Bridge.js")
        } else {
            guard let resource = Bundle.module.url(forResource: "Bridge", withExtension: "js") else {
                throw NSError(domain: "RefoldTracker.Resources", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Bridge.js is missing. Rebuild Refold Tracker."])
            }
            bridgeURL = resource
        }
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)
        configuration.userContentController.addUserScript(WKUserScript(source: bridge,
                                                                       injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: URL(string: "https://prod.refold.la/dashboard")!))
    }

    func showLogin() {
        if loginWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Refold — sign in"
            window.contentView = webView
            window.isReleasedWhenClosed = false
            window.center()
            loginWindow = window
        }
        loginWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { onNavigation?() }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url,
              url.scheme == "https" || url.scheme == "about" else { return nil }

        // Use the exact configuration supplied by WebKit. Reusing the main view or creating
        // a fresh configuration breaks window.opener / Firebase's popup response channel.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let width = min(1200, max(500, windowFeatures.width?.doubleValue ?? 600))
        let height = min(1000, max(500, windowFeatures.height?.doubleValue ?? 750))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Refold — sign in"
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.delegate = self
        popupWindows[ObjectIdentifier(popup)] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // WebKit loads navigationAction itself after this delegate returns the new view.
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupWindows[ObjectIdentifier(webView)]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let popup = window.contentView as? WKWebView,
              popupWindows.removeValue(forKey: ObjectIdentifier(popup)) != nil else { return }
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        onNavigation?()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Refold"
        alert.informativeText = message
        if let window = webView.window {
            alert.beginSheetModal(for: window) { _ in completionHandler() }
        } else {
            alert.runModal()
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Refold"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let window = webView.window {
            alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
        } else {
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              url.scheme == "https" || url.scheme == "about" else {
            decisionHandler(.cancel)
            return
        }
        // Authentication providers may use external HTTPS origins. The native bridge itself
        // operates only on the exact Refold origin; external pages cannot send native commands.
        decisionHandler(.allow)
    }

    func history() async throws -> HistoryResult {
        let value = try await invoke("history", payload: nil)
        return try JSONDecoder().decode(HistoryResult.self, from: Data(value.utf8))
    }

    func save(_ entry: LocalEntry) async throws {
        let payload: [String: Any] = [
            "activityId": entry.action.activityID, "nickname": entry.action.name,
            "languageCode": "ko", "durationMs": entry.durationMs, "source": "STOPWATCH",
            "startTime": entry.startTime, "attributedDate": entry.attributedDate, "note": NSNull()
        ]
        _ = try await invoke("save", payload: payload)
    }

    func edit(_ entry: RemoteEntry, durationMs: Int64) async throws {
        guard let id = Int(entry.id), let activityID = Int(entry.activityId) else {
            throw NSError(domain: "RefoldTracker.Protocol", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid numeric entry or activity ID."])
        }
        let payload: [String: Any] = [
            "id": id, "nickname": entry.name, "activityId": activityID,
            "languageCode": entry.languageCode, "durationMilliseconds": durationMs,
            "attributedDate": entry.attributedDate, "startTime": entry.startTime as Any? ?? NSNull(),
            "note": entry.note ?? ""
        ]
        _ = try await invoke("edit", payload: payload)
    }

    func delete(_ entry: RemoteEntry) async throws {
        guard entry.isInScope, let id = Int(entry.id) else {
            throw NSError(domain: "RefoldTracker.Protocol", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid entry for deletion."])
        }
        _ = try await invoke("delete", payload: ["id": id])
    }

    private func invoke(_ method: String, payload: [String: Any]?) async throws -> String {
        guard webView.url?.host == "prod.refold.la" else {
            throw NSError(domain: "RefoldTracker.Auth", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Open the sign-in window and sign in to Refold."])
        }
        let arguments: [String: Any] = ["method": method, "payload": payload ?? [:]]
        let result = try await webView.callAsyncJavaScript("""
            if (location.origin !== 'https://prod.refold.la' || !window.refoldNative) {
                throw new Error('Refold is not loaded yet. Open the sign-in window.');
            }
            try {
                return JSON.stringify({ ok: true, value: await window.refoldNative[method](payload) });
            } catch (error) {
                return JSON.stringify({ ok: false, error: String(error?.message || error) });
            }
            """, arguments: arguments, in: nil, contentWorld: .page)
        guard let string = result as? String else {
            throw NSError(domain: "RefoldTracker.Protocol", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected Refold response."])
        }
        guard let envelope = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any],
              envelope["ok"] as? Bool == true, let value = envelope["value"] else {
            let envelope = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
            throw NSError(domain: "RefoldTracker.Protocol", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: envelope?["error"] as? String ?? "Unexpected Refold response."])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}

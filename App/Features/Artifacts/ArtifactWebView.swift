import HyperVaultKit
import SwiftUI
import UIKit
import WebKit

/// What the page web view is asked to show.
struct ArtifactWebContent: Equatable, Identifiable {
    enum Source: Equatable {
        /// Markup the app fetched itself, rendered against the page's own address.
        case html(String, base: URL)
        /// An address the web view loads for itself (a password prompt, a public group).
        case url(URL)
    }

    let id = UUID()
    let source: Source

    var pageURL: URL {
        switch source {
        case .html(_, let base): return base
        case .url(let url): return url
        }
    }

    static func == (lhs: ArtifactWebContent, rhs: ArtifactWebContent) -> Bool { lhs.id == rhs.id }
}

/// A page, in a web view that holds nothing of the app's.
///
/// A page is arbitrary HTML someone (or something) wrote, run with JavaScript
/// on so the apps people keep work. So the web view is walled in: a data store
/// that keeps nothing (no cookies, no storage that outlives the screen), no
/// token anywhere near it (the app fetched the markup itself and hands over
/// only the markup), no camera, microphone or motion, no new windows, and every
/// link that leaves the page goes where a link should: Safari, or back into
/// the app when it is one of HyperVault's own.
struct ArtifactWebView: UIViewRepresentable {
    let content: ArtifactWebContent
    let router: ArtifactLinkRouter
    var onProgress: (Double) -> Void = { _ in }
    var onFinish: () -> Void = {}
    var onFailure: (String) -> Void = { _ in }
    /// A link to another HyperVault page or screen.
    var onOpenInApp: (URL) -> Void = { _ in }
    /// The "Fix it" link of a broken page, with the error it carries.
    var onRepair: (String?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Nothing the page stores outlives the screen, and nothing of the app's is in it.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        configuration.upgradeKnownHostsToHTTPS = true
        return configuration
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.configuration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        // A peek at a link would load it outside the rules below.
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = Self.paper(in: context.environment)
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.observe(webView)
        context.coordinator.load(content, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // The look can change under an open page.
        webView.underPageBackgroundColor = Self.paper(in: context.environment)
        context.coordinator.load(content, in: webView)
    }

    /// The screen's paper in the look the screen is in. `UIColor(Color)` fixes a dynamic colour to the
    /// look it is converted in (the light one, before the view is on screen), so the colour is resolved
    /// against the environment first. It is what shows before a page has painted and past its edges.
    private static func paper(in environment: EnvironmentValues) -> UIColor {
        UIColor(Color(Palette.background.resolve(in: environment)))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.progress = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: ArtifactWebView
        var progress: NSKeyValueObservation?
        private var loadedID: UUID?
        private var pageURL: URL?

        init(_ parent: ArtifactWebView) {
            self.parent = parent
        }

        func observe(_ webView: WKWebView) {
            progress = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                let value = view.estimatedProgress
                DispatchQueue.main.async { self?.parent.onProgress(value) }
            }
        }

        func load(_ content: ArtifactWebContent, in webView: WKWebView) {
            guard loadedID != content.id else { return }
            loadedID = content.id
            pageURL = content.pageURL
            switch content.source {
            case .html(let html, let base): webView.loadHTMLString(html, baseURL: base)
            case .url(let url): webView.load(URLRequest(url: url))
            }
        }

        // MARK: Navigation

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            let scheme = url.scheme?.lowercased() ?? ""

            // The page's own frames and resources (iframes, embedded video) load as they ask.
            if navigationAction.targetFrame?.isMainFrame == false {
                return decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
            }
            if scheme == "about" || scheme == "blob" || scheme == "data" { return decisionHandler(.allow) }

            switch navigationAction.navigationType {
            case .reload, .backForward:
                return decisionHandler(.allow)
            case .other where isThePage(url):
                // What was asked for: the markup the app handed over, or the address it was told to load.
                return decisionHandler(.allow)
            case .formSubmitted, .formResubmitted:
                // A form that stays on the page's own site works; one that leaves is a link out.
                if url.host == pageURL?.host { return decisionHandler(.allow) }
            default:
                // A jump to a part of the same page is not leaving it.
                if isThePage(url) { return decisionHandler(.allow) }
            }

            route(url)
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            // A download or a type the web view cannot show goes to Safari, which can.
            if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
                route(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        /// The same document, ignoring a fragment.
        private func isThePage(_ url: URL) -> Bool {
            guard let pageURL else { return false }
            return Self.withoutFragment(url) == Self.withoutFragment(pageURL)
        }

        private static func withoutFragment(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.string ?? url.absoluteString
        }

        private func route(_ url: URL) {
            switch parent.router.action(for: url) {
            case .repair(_, let error):
                parent.onRepair(error)
            case .hyperVault(let url):
                parent.onOpenInApp(url)
            case .external(let url):
                UIApplication.shared.open(url)
            case .blocked:
                break
            }
        }

        // MARK: Lifecycle

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onFinish()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The page used more memory than the system would give it: start it again.
            loadedID = nil
            parent.onFailure("The page used too much memory and stopped. Try again.")
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            // Cancelled loads, and the interruption that follows a link we routed elsewhere, are not failures.
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
            parent.onFailure(nsError.localizedDescription)
        }

        // MARK: Page requests

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // target="_blank" and window.open: a link, not a window.
            if let url = navigationAction.request.url { route(url) }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }

        func webView(
            _ webView: WKWebView,
            requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }

        // The page's own alert, confirm and prompt, shown natively.

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            present(on: webView, message: message, actions: [("OK", .default, { completionHandler() })]) { completionHandler() }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            present(
                on: webView, message: message,
                actions: [("Cancel", .cancel, { completionHandler(false) }), ("OK", .default, { completionHandler(true) })]
            ) { completionHandler(false) }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            guard let controller = Self.topViewController(from: webView) else { return completionHandler(nil) }
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            controller.present(alert, animated: true)
        }

        private func present(
            on webView: WKWebView,
            message: String,
            actions: [(String, UIAlertAction.Style, () -> Void)],
            fallback: () -> Void
        ) {
            guard let controller = Self.topViewController(from: webView) else { return fallback() }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            for (title, style, handler) in actions {
                alert.addAction(UIAlertAction(title: title, style: style) { _ in handler() })
            }
            controller.present(alert, animated: true)
        }

        private static func topViewController(from view: UIView) -> UIViewController? {
            var controller = view.window?.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            return controller
        }
    }
}

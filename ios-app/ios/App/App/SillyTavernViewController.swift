import UIKit
import Capacitor
import WebKit

/**
 * SillyTavernViewController
 *
 * Custom view controller that:
 * 1. Shows a "Starting server…" overlay while the Node.js backend boots
 * 2. Polls http://localhost:8000 via URLSession until it responds
 * 3. Loads the URL in the WebView and dismisses the overlay
 * 4. Shows an error screen if the server fails to start within the timeout
 *
 * First launch is slow: nodejs-mobile parses the 14MB bundle on JIT-less
 * Node 18 AND copies 100+ default content files — budget 2-3 minutes.
 */
class SillyTavernViewController: CAPBridgeViewController, WKScriptMessageHandler {

    private var loadingOverlay: UIView?
    private var statusLabel: UILabel?
    private var errorLabel: UILabel?
    private var spinnerView: UIActivityIndicatorView?
    private var pollTimer: Timer?
    private var elapsedTimer: Timer?
    private var pollCount = 0
    private var elapsedSeconds = 0
    private let maxPolls = 720          // 720 × 0.5s = 360s (6 min) timeout — first launch can take 3+ min
    private let pollInterval: TimeInterval = 0.5
    private let serverURL = URL(string: "http://localhost:8000")!

    override func viewDidLoad() {
        NSLog("[ST-Swift] ▶️ viewDidLoad — SillyTavernViewController starting")
        NSLog("[ST-Swift] 📁 Check Documents/st-startup.log for Node.js output")
        super.viewDidLoad()
        NSLog("[ST-Swift] ▶️ super.viewDidLoad complete — showing overlay and polling")
        extendWebViewEdgeToEdge()
        fixWebViewGesturesForSliders()
        setupJSErrorCapture()
        showLoadingOverlay()
        startPolling()
        startElapsedTimer()
    }

    // ── Edge-to-edge WebView ──────────────────────────────────────────────────
    // By default Capacitor respects safe area insets, leaving black bars at the
    // top and bottom. Since index.html already has viewport-fit=cover and ST's
    // CSS can use env(safe-area-inset-*), we extend the WebView to fill the
    // entire screen and inject CSS to pad the top toolbar and bottom input.
    private func extendWebViewEdgeToEdge() {
        // Remove additional safe area insets Capacitor may have set
        additionalSafeAreaInsets = .zero

        // Make WebView ignore safe area and fill the whole screen
        guard let webView = bridge?.webView else { return }
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // Pin WebView to the view edges (not safe area)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Inject CSS that uses iOS safe-area-inset env vars to pad ST's UI
        let safeAreaCSS = WKUserScript(source: """
            document.addEventListener('DOMContentLoaded', function() {
                var s = document.createElement('style');
                s.textContent = `
                    /* Push ST top bar below the status bar notch */
                    #top-bar, .top-bar, #navigation-top {
                        padding-top: env(safe-area-inset-top, 0px) !important;
                    }
                    /* Push ST bottom input above the home indicator */
                    #send_form, #form_sheld, .form_sheld {
                        padding-bottom: env(safe-area-inset-bottom, 0px) !important;
                    }
                    /* Ensure body stretches to fill the viewport */
                    body {
                        padding-top: env(safe-area-inset-top, 0px);
                        padding-bottom: env(safe-area-inset-bottom, 0px);
                    }
                `;
                document.head.appendChild(s);
            });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(safeAreaCSS)
        NSLog("[ST-Swift] 📐 Edge-to-edge layout applied with safe-area CSS")
    }

    // ── Fix sliders (range inputs) ───────────────────────────────────────────
    // WKWebView's scroll view can interfere with HTML range input drags.
    // Instead of overriding gesture delegates (which crashes — UIScrollView
    // owns its pan gesture delegate), inject CSS/JS to make sliders work.
    private func fixWebViewGesturesForSliders() {
        guard let webView = bridge?.webView else { return }
        // Disable bouncing which can interfere with touch handling
        webView.scrollView.bounces = false

        // Inject JS that adds touch-action CSS to range inputs so the browser
        // handles them correctly without scroll interference
        let script = WKUserScript(source: """
            document.addEventListener('DOMContentLoaded', function() {
                var style = document.createElement('style');
                style.textContent = 'input[type=range] { touch-action: none; }';
                document.head.appendChild(style);
            });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)
        NSLog("[ST-Swift] 🎚️ Slider touch-action fix applied")
    }

    // ── JS diagnostics ────────────────────────────────────────────────────────

    private func setupJSErrorCapture() {
        guard let webView = bridge?.webView else {
            NSLog("[ST-Swift] ⚠️ setupJSErrorCapture: webView not available yet")
            return
        }
        // Register message handler for JS→native logging
        webView.configuration.userContentController.add(self, name: "stLog")

        // Inject script at document start to capture JS errors and unhandled rejections
        let script = WKUserScript(source: """
            window.onerror = function(msg, url, line, col, err) {
                window.webkit.messageHandlers.stLog.postMessage('[JS-ERROR] ' + msg + ' @ ' + url + ':' + line);
            };
            window.addEventListener('unhandledrejection', function(e) {
                var reason = e.reason ? (e.reason.stack || e.reason.toString()) : 'unknown';
                window.webkit.messageHandlers.stLog.postMessage('[JS-REJECT] ' + reason);
            });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)
        NSLog("[ST-Swift] 🔧 JS error capture installed")
    }

    // Called by WKScriptMessageHandler when JS posts to 'stLog'
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "stLog" {
            NSLog("[ST-WebView] %@", message.body as? String ?? "(non-string)")
        }
    }

    // Poll DOM state after WebView loads to diagnose ST loading hang
    private func startDOMDiagnostics() {
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self = self, let wv = self.bridge?.webView else { timer.invalidate(); return }
            tick += 1
            if tick > 24 { timer.invalidate(); return }  // stop after 2 minutes
            wv.evaluateJavaScript("""
                (function() {
                    var state = document.readyState;
                    var loading = document.querySelector('#loader, .loader, [class*="loading"], [id*="loading"]');
                    var loadingVisible = loading ? getComputedStyle(loading).display !== 'none' : false;
                    var bodyClasses = document.body ? document.body.className.substring(0, 120) : 'no-body';
                    return state + ' | loading-el:' + loadingVisible + ' | body:' + bodyClasses;
                })()
            """) { result, error in
                if let r = result as? String {
                    NSLog("[ST-Swift] 🔍 DOM@%ds: %@", tick * 5, r)
                } else if let e = error {
                    NSLog("[ST-Swift] 🔍 DOM eval error: %@", e.localizedDescription)
                }
            }
        }
    }

    private func showLoadingOverlay() {
        let overlay = UIView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = "SillyTavern"
        titleLabel.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = UIColor(red: 0.6, green: 0.4, blue: 0.9, alpha: 1.0)
        spinner.startAnimating()

        let statusLbl = UILabel()
        statusLbl.text = "Starting local server…"
        statusLbl.font = UIFont.systemFont(ofSize: 15)
        statusLbl.textColor = UIColor.lightGray
        statusLbl.textAlignment = .center
        statusLbl.numberOfLines = 3

        let hintLabel = UILabel()
        hintLabel.text = "First launch may take 1–3 minutes\nwhile initialising user data."
        hintLabel.font = UIFont.systemFont(ofSize: 12)
        hintLabel.textColor = UIColor.darkGray
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2

        let errorLbl = UILabel()
        errorLbl.text = ""
        errorLbl.font = UIFont.systemFont(ofSize: 13)
        errorLbl.textColor = UIColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)
        errorLbl.textAlignment = .center
        errorLbl.numberOfLines = 5
        errorLbl.isHidden = true

        let disclaimerLbl = UILabel()
        disclaimerLbl.text = "If stuck on this screen for more than 3 minutes,\nforce quit the app and relaunch."
        disclaimerLbl.font = UIFont.systemFont(ofSize: 11)
        disclaimerLbl.textColor = UIColor(white: 0.45, alpha: 1.0)
        disclaimerLbl.textAlignment = .center
        disclaimerLbl.numberOfLines = 2

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(statusLbl)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(disclaimerLbl)
        stack.addArrangedSubview(errorLbl)

        overlay.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -40),
        ])

        view.addSubview(overlay)
        loadingOverlay = overlay
        statusLabel = statusLbl
        errorLabel = errorLbl
        spinnerView = spinner
    }

    private func dismissOverlay(withError message: String? = nil) {
        pollTimer?.invalidate()
        pollTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let errMsg = message {
                self.spinnerView?.stopAnimating()
                self.errorLabel?.text = "Server failed to start:\n\(errMsg)\n\nTry force-closing and reopening the app."
                self.errorLabel?.isHidden = false
                self.statusLabel?.isHidden = true
                // Leave overlay visible so user can read the error
                return
            }

            // Server is ready — load the page then fade out the overlay
            NSLog("[ST-Swift] 🌐 Loading http://localhost:8000 in WebView...")
            if let wv = self.bridge?.webView {
                let req = URLRequest(url: self.serverURL,
                                     cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                     timeoutInterval: 30)
                wv.load(req)
                NSLog("[ST-Swift] 🌐 WebView.load() called")
            } else {
                NSLog("[ST-Swift] ❌ bridge?.webView is nil!")
            }

            // Start DOM diagnostics to detect if ST's loading screen gets stuck
            self.startDOMDiagnostics()

            // Delay overlay removal to let page start rendering
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let overlay = self.loadingOverlay else { return }
                UIView.animate(withDuration: 0.4, animations: {
                    overlay.alpha = 0
                }) { _ in
                    overlay.removeFromSuperview()
                    self.loadingOverlay = nil
                    NSLog("[ST-Swift] ✅ Overlay removed")
                }
            }
        }
    }

    // ── Elapsed time display ──────────────────────────────────────────────────

    private func startElapsedTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.elapsedSeconds += 1
            DispatchQueue.main.async {
                let s = self.elapsedSeconds
                if s < 30 {
                    self.statusLabel?.text = "Starting local server… (\(s)s)"
                } else if s < 90 {
                    self.statusLabel?.text = "Initialising data… (\(s)s)\nThis is normal on first launch."
                } else {
                    self.statusLabel?.text = "Almost ready… (\(s)s)"
                }
            }
        }
    }

    // ── Server readiness polling ──────────────────────────────────────────────

    private func startPolling() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.4
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pollCount += 1

            if self.pollCount > self.maxPolls {
                self.pollTimer?.invalidate()
                let timeoutSec = Int(self.pollInterval * Double(self.maxPolls))
                NSLog("[ST-Swift] ❌ Timed out after %ds — server never responded", timeoutSec)
                self.dismissOverlay(withError: "Timed out after \(timeoutSec)s")
                return
            }

            // Log every 10 polls (~5s) so we can see progress in Xcode console
            if self.pollCount % 10 == 0 {
                let waited = String(format: "%.0f", Double(self.pollCount) * self.pollInterval)
                NSLog("[ST-Swift] ⏳ Still waiting for :8000 — %@s elapsed (poll %d/%d)", waited, self.pollCount, self.maxPolls)
            }

            let task = session.dataTask(with: self.serverURL) { _, response, error in
                if let http = response as? HTTPURLResponse {
                    if http.statusCode < 500 {
                        let waited = String(format: "%.1f", Double(self.pollCount) * self.pollInterval)
                        NSLog("[ST-Swift] ✅ Server responded HTTP %d after %@s — loading WebView", http.statusCode, waited)
                        self.pollTimer?.invalidate()
                        self.dismissOverlay()
                    } else {
                        NSLog("[ST-Swift] ⚠️ Server returned HTTP %d", http.statusCode)
                    }
                } else if let err = error {
                    // Connection refused is normal while Node is booting — only log occasionally
                    if self.pollCount % 20 == 1 {
                        NSLog("[ST-Swift] 🔌 Poll %d: %@", self.pollCount, err.localizedDescription)
                    }
                }
            }
            task.resume()
        }
    }
}

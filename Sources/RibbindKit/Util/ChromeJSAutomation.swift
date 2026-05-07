import AppKit
import Foundation

/// Helpers for executing JavaScript inside Chrome's active tab via AppleScript's
/// `execute javascript` command. Chrome 113+ ships with this gated behind a per-
/// profile setting at `View > Developer > Allow JavaScript from Apple Events`,
/// which the user must enable once. The setting cannot be flipped from outside
/// the user's Chrome menu — Chrome intentionally disables the menu item to
/// AppleScript / Accessibility automation as a security feature (verified
/// empirically: AXPress / AXPick / System Events click on the menu item all
/// no-op even though they report success).
public enum ChromeJSAutomation {
    public enum Failure: Error, CustomStringConvertible {
        case appleScriptDisabled
        case scriptFailed(String)
        case chromeNotRunning

        public var description: String {
            switch self {
            case .appleScriptDisabled:
                return "Chrome's 'Allow JavaScript from Apple Events' is OFF. Enable it once at Chrome > View > Developer > Allow JavaScript from Apple Events."
            case .scriptFailed(let msg): return "Chrome JS execution failed: \(msg)"
            case .chromeNotRunning: return "Chrome is not running."
            }
        }
    }

    /// Probe whether `execute javascript` is currently allowed by running a
    /// trivial expression. Returns true on success, false when Chrome reports
    /// AppleScript error -1743 / 12 (the "JavaScript through AppleScript is
    /// turned off" message) or any other failure.
    public static func isEnabled() -> Bool {
        guard isChromeRunning() else { return false }
        let probe = #"tell application "Google Chrome" to execute active tab of front window javascript "1""#
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: probe) else { return false }
        let result = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return false }
        return result.descriptorType != 0  // any non-null result counts as success
    }

    /// Run `js` in Chrome's active tab. Returns the script's return value (as a
    /// string when reasonable) or throws.
    public static func executeJS(_ js: String) throws -> String {
        guard isChromeRunning() else { throw Failure.chromeNotRunning }
        // Escape the JS source for embedding in an AppleScript string literal:
        // backslashes and double-quotes need to be escaped.
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Google Chrome\" to execute active tab of front window javascript \"\(escaped)\""
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw Failure.scriptFailed("could not compile AppleScript")
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            // Chrome's "AS-JS off" message contains a specific phrase. Detect it
            // so the dispatcher can surface a setup hint instead of generic error.
            let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? ""
            if msg.lowercased().contains("javascript") && msg.lowercased().contains("turned off") {
                throw Failure.appleScriptDisabled
            }
            throw Failure.scriptFailed(msg.isEmpty ? "(unknown)" : msg)
        }
        return result.stringValue ?? ""
    }

    /// Open Chrome's `View > Developer` menu and bring the
    /// `Allow JavaScript from Apple Events` item into focus so the user can
    /// click it with one keystroke (Return). Chrome's macOS menu items DO
    /// respond to user mouse clicks even when AX-press is disabled, so this
    /// helper just navigates the user there — it cannot click the toggle.
    ///
    /// Runs entirely on a background queue: `chrome.activate()` is fast but
    /// the System Events AS that opens View → Developer can take 300–500 ms
    /// (two AX clicks + delays) and would otherwise block Ribbind's main
    /// thread, freezing its menu bar icon. Dispatching async also means the
    /// caller (Settings UI button) returns immediately so the user can click
    /// elsewhere if they change their mind.
    public static func openEnableMenu() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let chrome = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.google.Chrome").first
            else { return }
            chrome.activate()
            // Wait briefly for Chrome to come frontmost before opening the menu.
            Thread.sleep(forTimeInterval: 0.2)
            let openMenuAS = """
            tell application "System Events"
                tell process "Google Chrome"
                    set frontmost to true
                    click menu bar item "View" of menu bar 1
                    delay 0.15
                    click menu item "Developer" of menu 1 of menu bar item "View" of menu bar 1
                    delay 0.15
                end tell
            end tell
            """
            var err: NSDictionary?
            NSAppleScript(source: openMenuAS)?.executeAndReturnError(&err)
        }
    }

    private static func isChromeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.google.Chrome" }
    }

    // MARK: - Target language catalog

    public struct TargetLanguage: Identifiable, Hashable, Sendable {
        public let code: String       // BCP-47-ish (e.g. "ko", "zh-Hans")
        public let displayName: String // human-friendly ("Korean (한국어)")
        public var id: String { code }
    }

    /// Curated set of Chrome's commonly-supported translation targets. The
    /// codes follow Chrome's Translator API expectations (BCP-47). Extend as
    /// needed; the picker in Settings + ShortcutRow renders this list.
    public static let supportedTargetLanguages: [TargetLanguage] = [
        .init(code: "ko",      displayName: "Korean (한국어)"),
        .init(code: "ja",      displayName: "Japanese (日本語)"),
        .init(code: "zh-Hans", displayName: "Chinese, Simplified (简体中文)"),
        .init(code: "zh-Hant", displayName: "Chinese, Traditional (繁體中文)"),
        .init(code: "es",      displayName: "Spanish (Español)"),
        .init(code: "fr",      displayName: "French (Français)"),
        .init(code: "de",      displayName: "German (Deutsch)"),
        .init(code: "it",      displayName: "Italian (Italiano)"),
        .init(code: "pt",      displayName: "Portuguese (Português)"),
        .init(code: "ru",      displayName: "Russian (Русский)"),
        .init(code: "ar",      displayName: "Arabic (العربية)"),
        .init(code: "hi",      displayName: "Hindi (हिन्दी)"),
        .init(code: "vi",      displayName: "Vietnamese (Tiếng Việt)"),
        .init(code: "th",      displayName: "Thai (ภาษาไทย)"),
        .init(code: "id",      displayName: "Indonesian (Bahasa Indonesia)"),
        .init(code: "tr",      displayName: "Turkish (Türkçe)"),
        .init(code: "nl",      displayName: "Dutch (Nederlands)"),
        .init(code: "pl",      displayName: "Polish (Polski)"),
    ]

    public static func displayName(forLanguageCode code: String) -> String {
        if let m = supportedTargetLanguages.first(where: { $0.code == code }) {
            return m.displayName
        }
        return code
    }

    // MARK: - Chrome 138+ Translator API helpers

    public enum ModelStatus: String, Sendable {
        case available     // Model downloaded — Translator works without user gesture
        case downloadable  // Not yet downloaded; create() requires user gesture
        case downloading   // Currently downloading; create() requires user gesture
        case unavailable   // Pair not supported on this device / Chrome build
        case unknown       // Probe failed (Chrome closed, AS-JS off, API missing)
    }

    /// Query Chrome's Translator API for the (en → target) model availability.
    /// Returns `.unknown` on any error so the UI can fall back gracefully.
    public static func translatorAvailability(target: String) -> ModelStatus {
        guard isEnabled() else { return .unknown }
        let safeTarget = target.filter { $0.isLetter || $0 == "-" }
        guard !safeTarget.isEmpty else { return .unknown }
        let js = """
        (async () => {
            try {
                if (typeof Translator === 'undefined') return 'unknown';
                const a = await Translator.availability({sourceLanguage: 'en', targetLanguage: '\(safeTarget)'});
                localStorage.setItem('_ribbindAvailability_en_\(safeTarget)', a);
                return a;
            } catch (e) {
                return 'unknown';
            }
        })();
        try { localStorage.getItem('_ribbindAvailability_en_\(safeTarget)') || 'unknown'; } catch (_) { 'unknown'; }
        """
        // Read what the previous async run wrote to localStorage, if any.
        let readJS = "localStorage.getItem('_ribbindAvailability_en_\(safeTarget)') || 'unknown'"
        // Kick off the probe (async — its result lands in localStorage).
        _ = try? executeJS(js)
        // Read whatever the latest probe wrote (may be stale by one fire,
        // but converges in steady state).
        let raw = (try? executeJS(readJS)) ?? "unknown"
        return ModelStatus(rawValue: raw) ?? .unknown
    }

    /// Inject a one-shot `click` listener into Chrome's active tab. The next
    /// time the user clicks anywhere on the page, the listener calls
    /// `Translator.create()` with the user-gesture privilege and triggers
    /// model download. Progress and completion land in localStorage so the
    /// UI can poll for them.
    public static func installModelDownloadClickListener(target: String) throws {
        let safeTarget = target.filter { $0.isLetter || $0 == "-" }
        guard !safeTarget.isEmpty else {
            throw Failure.scriptFailed("invalid target language code")
        }
        let js = """
        (function() {
            try { localStorage.removeItem('_ribbindModelProgress_en_\(safeTarget)'); } catch (_) {}
            try { localStorage.removeItem('_ribbindModelReady_en_\(safeTarget)'); } catch (_) {}
            try { localStorage.removeItem('_ribbindModelError_en_\(safeTarget)'); } catch (_) {}

            function ribbindOnceClick() {
                document.removeEventListener('click', ribbindOnceClick, true);
                try {
                    if (typeof Translator === 'undefined') {
                        localStorage.setItem('_ribbindModelError_en_\(safeTarget)', 'Translator API not available');
                        return;
                    }
                    Translator.create({
                        sourceLanguage: 'en',
                        targetLanguage: '\(safeTarget)',
                        monitor(m) {
                            m.addEventListener('downloadprogress', (e) => {
                                const pct = Math.round((e.loaded || 0) * 100);
                                localStorage.setItem('_ribbindModelProgress_en_\(safeTarget)', String(pct));
                            });
                        }
                    }).then(t => {
                        return t.translate('hello').then(() => {
                            localStorage.setItem('_ribbindModelReady_en_\(safeTarget)', '1');
                            localStorage.setItem('_ribbindModelProgress_en_\(safeTarget)', '100');
                        });
                    }).catch(err => {
                        localStorage.setItem('_ribbindModelError_en_\(safeTarget)', String(err.message || err));
                    });
                } catch (err) {
                    localStorage.setItem('_ribbindModelError_en_\(safeTarget)', String(err.message || err));
                }
            }
            // Capture-phase listener so page-level click handlers that
            // stopPropagation can't preempt our trigger. {once: true} guarantees
            // single fire even if removeEventListener races.
            document.addEventListener('click', ribbindOnceClick, true);
            return 'installed';
        })();
        """
        _ = try executeJS(js)
    }

    /// Poll the page's localStorage for download progress / completion.
    public struct DownloadState {
        public let progress: Int?    // 0-100, nil if not started
        public let ready: Bool
        public let error: String?
    }

    public static func readModelDownloadState(target: String) -> DownloadState {
        let safeTarget = target.filter { $0.isLetter || $0 == "-" }
        guard !safeTarget.isEmpty else { return DownloadState(progress: nil, ready: false, error: "invalid target") }
        let js = """
        JSON.stringify({
            p: localStorage.getItem('_ribbindModelProgress_en_\(safeTarget)') || null,
            r: localStorage.getItem('_ribbindModelReady_en_\(safeTarget)') || null,
            e: localStorage.getItem('_ribbindModelError_en_\(safeTarget)') || null
        });
        """
        guard let raw = try? executeJS(js),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return DownloadState(progress: nil, ready: false, error: nil) }
        let progress = (obj["p"] as? String).flatMap { Int($0) }
        let ready = (obj["r"] as? String) == "1"
        let error = obj["e"] as? String
        return DownloadState(progress: progress, ready: ready, error: error)
    }
}

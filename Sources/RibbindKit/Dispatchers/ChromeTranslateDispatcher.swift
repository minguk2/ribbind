import Foundation
import AppKit
import ApplicationServices

/// Triggers **Chrome's own** full-page translate — the exact thing right-click ▸
/// *Translate to …* runs — by driving Chrome's UI through the Accessibility API.
///
/// ## Why not JavaScript
///
/// The previous implementation injected ~190 lines of JS that walked every DOM text
/// node and rewrote it through Chrome's `Translator` API. That is a look-alike, not
/// the feature: it mangles inline structure, misses dynamically-added content, is
/// slow on large pages, and needed two one-time per-profile setup gates ("Allow
/// JavaScript from Apple Events" plus a model download). CLAUDE.md's
/// NO FAKE IMPLEMENTATIONS rule is exactly about this. Chrome's real translate is
/// not scriptable, so AX is the only honest route to it.
///
/// ## The mechanism (verified — see `research/09-chrome-native-translate-ax.md`)
///
/// 1. Chrome puts an `AXButton` with `AXDescription == "Translate"` in the omnibox.
///    One `AXPress` opens Chrome's native translate bubble (~113 ms).
/// 2. The bubble is a **separate `AXWindow`** holding one `AXRadioButton` per
///    language. The radio whose `AXValue == 1` is the language currently displayed.
/// 3. Pressing the other radio translates, or restores the original.
///
/// Toggle state therefore comes from Chrome, never from a flag Ribbind keeps. A page
/// the user translated by hand still toggles correctly, and there is no state to get
/// out of sync.
///
/// Target language is Chrome's own setting (Chrome ▸ Settings ▸ Languages), which is
/// why this recipe carries no parameters.
public enum ChromeTranslateDispatcher {

    public enum Failure: Error, CustomStringConvertible {
        case accessibilityNotAuthorized
        case chromeNotRunning
        /// No usable browser window in the AX tree. Chrome's accessibility tree can
        /// degrade (see below) — the cure is restarting Chrome.
        case axTreeUnavailable
        /// The omnibox Translate button isn't there: Chrome offers no translation for
        /// this page (internal pages, PDFs, or a page already in your language).
        case translateUnavailable
        case bubbleNotFound
        case pressFailed(String)

        public var description: String {
            switch self {
            case .accessibilityNotAuthorized: return "Accessibility permission not granted"
            case .chromeNotRunning: return "Google Chrome isn't running"
            case .axTreeUnavailable: return "Chrome exposed no usable window to the Accessibility API"
            case .translateUnavailable: return "Chrome offers no Translate control for this page"
            case .bubbleNotFound: return "Chrome's translate panel didn't appear"
            case .pressFailed(let what): return "AX press failed: \(what)"
            }
        }
    }

    /// Chrome's a11y tree is slow and occasionally hostile, so every lookup is
    /// bounded. `maxDepth` 12 comfortably covers the toolbar (the Translate button
    /// sits ~8 deep) without reaching page content.
    private static let searchDepth = 12
    private static let messagingTimeout: Float = 3.0

    private static func chromeApp() throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityNotAuthorized }
        guard let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.google.Chrome" }) else {
            throw Failure.chromeNotRunning
        }
        let element = AXProbe.app(pid: running.processIdentifier)
        AXProbe.setMessagingTimeout(element, seconds: messagingTimeout)
        return element
    }

    /// The browser window. Deliberately *not* "the first window": the translate
    /// bubble is also a window, and a degraded tree can serve up self-referential
    /// `AXApplication` entries.
    private static func browserWindows(_ app: AXUIElement) -> [AXUIElement] {
        AXProbe.allWindows(of: app).filter { AXProbe.subrole($0) == "AXStandardWindow" }
    }

    /// Windows that are not the browser window — where Chrome renders the bubble.
    private static func auxiliaryWindows(_ app: AXUIElement) -> [AXUIElement] {
        AXProbe.allWindows(of: app).filter { AXProbe.subrole($0) != "AXStandardWindow" }
    }

    private static func translateButton(_ app: AXUIElement) -> AXUIElement? {
        for window in browserWindows(app) {
            let hits = AXProbe.find(in: window, maxDepth: searchDepth) { element, role in
                role == "AXButton" && AXProbe.desc(element) == "Translate"
            }
            if let button = hits.first { return button }
        }
        return nil
    }

    /// Every language radio in the bubble, with its live selected-state.
    private static func bubbleRadios(_ app: AXUIElement) -> [(element: AXUIElement, language: String, selected: Bool)] {
        var out: [(AXUIElement, String, Bool)] = []
        for window in auxiliaryWindows(app) {
            let radios = AXProbe.find(in: window, maxDepth: 14, firstOnly: false) { _, role in
                role == "AXRadioButton"
            }
            for radio in radios {
                let language = AXProbe.title(radio)
                guard !language.isEmpty else { continue }
                out.append((radio, language, AXProbe.value(radio) == "1"))
            }
        }
        // The bubble can expose the same pair more than once; keep the first of each.
        var seen = Set<String>()
        return out.compactMap { entry in
            guard seen.insert(entry.1).inserted else { return nil }
            return (element: entry.0, language: entry.1, selected: entry.2)
        }
    }

    /// What a fire did, for logging and for the notification the user sees.
    public struct Outcome: Sendable {
        public let from: String
        public let to: String
    }

    /// Toggle Chrome's native translate on the frontmost tab.
    ///
    /// MUST NOT be called on the main thread — it polls with `Thread.sleep`, and the
    /// app is a MenuBarExtra whose icon freezes if the main actor blocks.
    @discardableResult
    public static func toggle() throws -> Outcome {
        let app = try chromeApp()
        guard !browserWindows(app).isEmpty else { throw Failure.axTreeUnavailable }

        // A bubble left open from a previous fire would swallow the button press.
        if !bubbleRadios(app).isEmpty { AXProbe.pressEscape() }

        guard let button = translateButton(app) else { throw Failure.translateUnavailable }

        // Open the bubble and wait for it to register in the AX tree.
        //
        // The wait is generous and retried once on purpose: the bubble reliably
        // *appears* on the first press, but it can take longer than a couple of
        // seconds to show up as a window in the AX tree (observed: a 3 s poll
        // reported "no bubble" while the bubble was plainly on screen and a probe
        // moments later listed it). Failing here would leave the user staring at
        // an open panel next to a "didn't respond" notification.
        func openBubble(timeout: TimeInterval) -> [(element: AXUIElement, language: String, selected: Bool)]? {
            let pressResult = AXProbe.perform(button)
            guard pressResult == .success else { return nil }
            return AXProbe.poll(timeout: timeout, interval: 0.1) {
                let found = bubbleRadios(app)
                return found.count >= 2 ? found : nil
            }
        }
        var radiosOrNil = openBubble(timeout: 6.0)
        if radiosOrNil == nil {
            NSLog("[Ribbind] chrome translate: bubble not seen after first press, retrying once")
            radiosOrNil = openBubble(timeout: 4.0)
        }
        guard let radios = radiosOrNil else { throw Failure.bubbleNotFound }

        // The radio marked selected is what's on screen now; the other is where the
        // user wants to go. Chrome owns this state, so the toggle can't desync.
        let current = radios.first(where: { $0.selected })?.language ?? "?"
        guard let target = radios.first(where: { !$0.selected }) else {
            // Only one language offered and it's already showing.
            AXProbe.pressEscape()
            throw Failure.translateUnavailable
        }
        let result = AXProbe.perform(target.element)
        guard result == .success else {
            AXProbe.pressEscape()
            throw Failure.pressFailed("language radio \"\(target.language)\" (AXError \(result.rawValue))")
        }
        NSLog("[Ribbind] chrome translate: %@ -> %@", current, target.language)
        return Outcome(from: current, to: target.language)
    }
}

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
/// ## Why one button is not enough (2026-08-22)
///
/// The omnibox button only exists while Chrome *offers* a translation, and Chrome
/// offers nothing for a page whose language is on the profile's never-translate list
/// (which defaults to accept-languages). With `accept_languages = en-US,en,ko` that
/// covers every Korean page — measured: `ko.wikipedia.org` has no button while
/// `example.com` does, so this is not a blanket "every language you read". The button
/// is likewise absent on a page Chrome simply has not offered on yet, and appears
/// once its bubble has been shown there. In all those states the shortcut answered
/// "Chrome offers no Translate control for this page" and did nothing.
///
/// Chrome still translates those pages; it just makes the user ask, through ⋮ ▸
/// *Translate…*. That opens the exact same native bubble, so it is an honest
/// fallback rather than a look-alike, and once a page has been translated the
/// omnibox button appears and the fast path takes over again.
///
/// ### What the ⋮ path actually looks like (probed 2026-08-22, Chrome 151.0.7922.172)
///
/// * The button is `AXPopUpButton AXDescription="Chrome"`, and only **`AXPress`**
///   opens its menu — `AXShowMenu` returns success and opens nothing.
/// * While the menu is open Chrome's `AXWindows` goes **empty**; the menu is reachable
///   only as `AXFocusedWindow`/`AXMainWindow` — an `AXWindow` with subrole
///   `AXUnknown`. `AXProbe.allWindows` unions those sources, which is why it is used
///   here instead of `AXWindows`.
/// * The item is `AXMenuItem` titled **`Translate…`** — *not* `locale.pak`'s
///   `Translate page`, which belongs to a different surface. Matching on the pak
///   string alone found nothing.
/// * The page context menu is a dead end: the web area advertises `AXShowMenu`, the
///   action returns success, and no menu item is exposed to AX at all. That path was
///   implemented, measured, and removed rather than shipped on faith — reaching it
///   would need a synthetic right-click, which can land on a link or clear the
///   user's selection.
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
        /// Neither route reached Chrome's translate bubble. After the ⋮ fallback
        /// landed, "a page already in your language" is no longer a cause — what is
        /// left is a surface Chrome itself cannot translate: `chrome://` internal
        /// pages, the PDF viewer, view-source, and the New Tab page.
        case translateUnavailable
        case bubbleNotFound
        case pressFailed(String)

        public var description: String {
            switch self {
            case .accessibilityNotAuthorized: return "Accessibility permission not granted"
            case .chromeNotRunning: return "Google Chrome isn't running"
            case .axTreeUnavailable: return "Chrome exposed no usable window to the Accessibility API"
            case .translateUnavailable:
                return "Chrome can't translate this page — no omnibox Translate button and no ⋮ ▸ Translate… item "
                     + "(Chrome internal pages, the PDF viewer and view-source have neither)"
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

        // Two ways into the same native bubble, cheapest first. Both end with
        // Chrome's own translate UI open — neither fakes a translation.
        let radios = try openViaOmnibox(app) ?? openViaAppMenu(app)
        guard let radios else { throw Failure.translateUnavailable }

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

    // MARK: - Ways into the bubble

    private typealias Radios = [(element: AXUIElement, language: String, selected: Bool)]

    /// Path 1 — the omnibox button. Present only while Chrome *offers* a translation,
    /// which excludes every page whose language is on the profile's accept-languages
    /// list. Returns `nil` (not a throw) when the button simply isn't there, so the
    /// caller can fall through.
    private static func openViaOmnibox(_ app: AXUIElement) throws -> Radios? {
        guard let button = translateButton(app) else { return nil }
        guard let radios = pressAndAwaitBubble(app, button, retry: true) else {
            throw Failure.bubbleNotFound
        }
        return radios
    }

    /// Path 2 — ⋮ ▸ *Translate…*. This is Chrome asking itself to translate a page it
    /// did not volunteer, so it works on English and Korean pages alike.
    private static func openViaAppMenu(_ app: AXUIElement) -> Radios? {
        guard let dots = appMenuButton(app) else { return nil }
        guard AXProbe.perform(dots) == .success else { return nil }

        // The menu takes a moment, and while it is open Chrome's `AXWindows` can go
        // empty — so the item is hunted across every root we can still reach, not
        // just the browser window.
        let item = AXProbe.poll(timeout: 2.0, interval: 0.1) {
            menuSearchRoots(app)
                .flatMap { root in
                    AXProbe.find(in: root, maxDepth: 16, firstOnly: false) { _, role in
                        role == "AXMenuItem" || role == "AXCell"
                    }
                }
                .first(where: { isTranslateCommandLabel(label(of: $0)) })
        }
        guard let item else {
            AXProbe.pressEscape()   // never leave the ⋮ menu hanging open
            return nil
        }
        guard AXProbe.perform(item) == .success else {
            AXProbe.pressEscape()
            return nil
        }
        guard let radios = awaitBubble(app, timeout: 6.0) else {
            AXProbe.pressEscape()
            return nil
        }
        return radios
    }

    /// Exercise the ⋮ fallback **in the shipping code path** and stop one press short
    /// of translating, so the route can be verified on a page the user is working in.
    ///
    /// Returns the bubble's languages, or `nil` if the route did not reach a bubble.
    /// Test-only: `toggle()` is the production entry point.
    public static func probeAppMenuRoute() -> [(language: String, selected: Bool)]? {
        guard let app = try? chromeApp() else { return nil }
        if !bubbleRadios(app).isEmpty { AXProbe.pressEscape() }
        guard let radios = openViaAppMenu(app) else { return nil }
        AXProbe.pressEscape()   // leave the page exactly as it was
        return radios.map { (language: $0.language, selected: $0.selected) }
    }

    // MARK: - Bubble plumbing

    /// Press `element`, then wait for the bubble to register in the AX tree.
    ///
    /// The wait is generous and retried on purpose: the bubble reliably *appears* on
    /// the first press, but it can take longer than a couple of seconds to show up as
    /// a window in the AX tree (observed: a 3 s poll reported "no bubble" while the
    /// bubble was plainly on screen and a probe moments later listed it). Failing here
    /// would leave the user staring at an open panel next to a "didn't respond"
    /// notification.
    private static func pressAndAwaitBubble(_ app: AXUIElement, _ element: AXUIElement, retry: Bool) -> Radios? {
        func attempt(_ timeout: TimeInterval) -> Radios? {
            guard AXProbe.perform(element) == .success else { return nil }
            return awaitBubble(app, timeout: timeout)
        }
        if let radios = attempt(6.0) { return radios }
        guard retry else { return nil }
        NSLog("[Ribbind] chrome translate: bubble not seen after first press, retrying once")
        return attempt(4.0)
    }

    private static func awaitBubble(_ app: AXUIElement, timeout: TimeInterval) -> Radios? {
        AXProbe.poll(timeout: timeout, interval: 0.1) {
            let found = bubbleRadios(app)
            return found.count >= 2 ? found : nil
        }
    }

    // MARK: - Element lookup

    /// The ⋮ button. Chrome labels it `AXDescription == "Chrome"`; the `contains`
    /// arm covers channel-suffixed builds ("Chrome Canary", "Chrome Beta").
    private static func appMenuButton(_ app: AXUIElement) -> AXUIElement? {
        for window in browserWindows(app) {
            let hits = AXProbe.find(in: window, maxDepth: searchDepth) { element, role in
                guard role == "AXPopUpButton" || role == "AXMenuButton" || role == "AXButton" else { return false }
                let d = AXProbe.desc(element)
                return d == "Chrome" || d.hasPrefix("Chrome ")
            }
            if let hit = hits.first { return hit }
        }
        return nil
    }

    /// Where an open Chrome menu can surface. Chrome renders menus as Views widgets,
    /// and which root they hang off has moved between versions — and `AXWindows` can
    /// return empty *while a menu is open*. Union every reachable root and let the
    /// label match decide.
    private static func menuSearchRoots(_ app: AXUIElement) -> [AXUIElement] {
        var roots = AXProbe.allWindows(of: app)
        for child in AXProbe.children(of: app) where AXProbe.role(child) == "AXMenu" {
            roots.append(child)
        }
        return roots
    }

    // MARK: - Labels

    private static func label(of element: AXUIElement) -> String {
        let title = AXProbe.title(element)
        return title.isEmpty ? AXProbe.desc(element) : title
    }

    /// ⋮ ▸ *Translate…* — the observed title, ellipsis and all. Normalising the
    /// ellipsis first means the same test covers `Translate…`, `Translate...`, and a
    /// future `Translate page`.
    ///
    /// Kept deliberately tight. A loose `contains("translate")` would also match the
    /// user's `Google Translate` bookmark, Live Caption's *Translate captions to*,
    /// and *Translate screen* — pressing any of those would do something the user did
    /// not ask for.
    private static func isTranslateCommandLabel(_ raw: String) -> Bool {
        let normalized = raw
            .replacingOccurrences(of: "\u{2026}", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if normalized == "translate" { return true }
        if normalized == "translate page" || normalized == "translate this page" { return true }
        // Korean-UI Chrome renders the same item as "번역…" / "페이지 번역".
        let ko = normalized.replacingOccurrences(of: " ", with: "")
        return ko == "번역" || ko == "페이지번역"
    }
}

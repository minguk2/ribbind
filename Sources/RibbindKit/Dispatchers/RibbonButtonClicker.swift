import AppKit
import ApplicationServices
import Foundation

/// Clicks a named button inside a running Office app's Accessibility tree. Used for
/// Ribbon-modal commands like Format Painter, SmartArt, Align, etc. — things whose UX
/// is "click the button, enter a brush/dialog mode." Neither AppleScript (ExecuteMso /
/// do Visual Basic / run VB macro) nor keyboard-bound fciName/Macro commands reproduce
/// the modal state reliably in Word Mac 16.108; simulating the button click does.
public enum RibbonButtonClicker {
    /// AXUIElement cache keyed by `(pid, role, title)`. Avoids the ~200 ms AX
    /// tree walk on every hotkey fire — critical for Word Highlight latency
    /// (user-visible: ~800 ms before, ~250 ms cached). Cache is invalidated
    /// per-app launch (PID change) and lazily on cell-not-found.
    @MainActor private static var elementCache: [String: AXUIElement] = [:]

    @MainActor
    private static func cachedDescendant(
        of root: AXUIElement,
        cacheKey: String,
        matching predicate: (AXUIElement) -> Bool,
        find: (AXUIElement) -> AXUIElement?
    ) -> AXUIElement? {
        if let hit = elementCache[cacheKey], predicate(hit) {
            return hit
        }
        guard let fresh = find(root) else { return nil }
        elementCache[cacheKey] = fresh
        return fresh
    }

    @MainActor
    public static func invalidateCache() {
        elementCache.removeAll()
    }

    public enum Failure: Error, CustomStringConvertible {
        case appNotRunning(String)
        case accessibilityNotAuthorized
        case elementNotFound(String)
        case pressFailed(AXError)
        /// Chrome.Translate-specific: Translator API needs a one-time user
        /// gesture to download the per-language-pair model. The dispatcher
        /// throws this so the BindingCoordinator can show a notification
        /// pointing at Ribbind Settings → Google Chrome → Initialize.
        case chromeTranslateGestureRequired(source: String, target: String)
        /// Source language equals target language — nothing to translate.
        case chromeTranslateSameLanguage(language: String)
        /// Chrome reports the (source, target) pair has no available model.
        case chromeTranslatePairUnavailable(source: String, target: String)
        /// Chrome 138+ Translator API not exposed in this build.
        case chromeTranslateAPIMissing
        /// Translator.create / availability / translate failed for an
        /// unexpected reason — payload is the JS-side error message.
        case chromeTranslateInternal(String)

        public var description: String {
            switch self {
            case .appNotRunning(let n):
                return "\(n) is not running — open it first"
            case .accessibilityNotAuthorized:
                return "Accessibility permission not granted. Grant it in System Settings → Privacy & Security → Accessibility."
            case .elementNotFound(let q):
                return "Could not find accessibility element: \(q)"
            case .pressFailed(let e):
                return "AXUIElementPerformAction(press) returned error \(e.rawValue)"
            case .chromeTranslateGestureRequired(let s, let t):
                return "Chrome needs a one-time user gesture to download the \(s)→\(t) translation model. Open Ribbind Settings → Google Chrome → Initialize translation model."
            case .chromeTranslateSameLanguage(let l):
                return "Page is already in target language (\(l)) — nothing to translate."
            case .chromeTranslatePairUnavailable(let s, let t):
                return "Chrome can't translate \(s) → \(t) on this device. Try a different target language."
            case .chromeTranslateAPIMissing:
                return "Chrome 138+ required for built-in Translator API."
            case .chromeTranslateInternal(let m):
                return "Translator failed: \(m)"
            }
        }
    }

    /// Describes how to locate a Ribbon control by its accessibility attributes. Word Mac
    /// can expose the same control as different AX roles across versions and tabs, so we
    /// match by role + any of title/help/description.
    public struct RibbonTarget: Sendable {
        public let role: String
        public let titleContains: String?
        public let helpContains: String?
        public let descriptionContains: String?

        public init(role: String, titleContains: String? = nil, helpContains: String? = nil, descriptionContains: String? = nil) {
            self.role = role
            self.titleContains = titleContains
            self.helpContains = helpContains
            self.descriptionContains = descriptionContains
        }

        public static let wordFormatPainter = RibbonTarget(
            role: kAXCheckBoxRole as String,
            titleContains: "Format",
            helpContains: "Copy formatting from one location"
        )
    }

    /// Press the first element in the given running app that matches `target`.
    public static func press(target: RibbonTarget, inApp app: AppTarget) throws {
        guard AXIsProcessTrusted() else {
            throw Failure.accessibilityNotAuthorized
        }
        let pid = try pidForRunningApp(app)
        let root = AXUIElementCreateApplication(pid)

        // Defense-in-depth: reject targets that would match the first element in the
        // tree. `DispatchRecipe` already rejects these at decode time, but axClick
        // matchers can be constructed directly from code too.
        let hasNeedle = [target.titleContains, target.helpContains, target.descriptionContains]
            .compactMap { $0 }.contains { !$0.isEmpty }
        guard hasNeedle else {
            throw Failure.elementNotFound("axClick target has no non-empty matcher — refusing to press first matching role")
        }

        guard let element = findDescendant(of: root, matching: { attributes in
            guard (attributes[kAXRoleAttribute as String] as? String) == target.role else { return false }
            if let needle = target.titleContains, !needle.isEmpty {
                guard let t = attributes[kAXTitleAttribute as String] as? String, t.contains(needle) else { return false }
            }
            if let needle = target.helpContains, !needle.isEmpty {
                guard let h = attributes[kAXHelpAttribute as String] as? String, h.contains(needle) else { return false }
            }
            if let needle = target.descriptionContains, !needle.isEmpty {
                guard let d = attributes[kAXDescriptionAttribute as String] as? String, d.contains(needle) else { return false }
            }
            return true
        }, maxDepth: 25) else {
            throw Failure.elementNotFound("role=\(target.role) title~=\(target.titleContains ?? "*") help~=\(target.helpContains ?? "*")")
        }

        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw Failure.pressFailed(result)
        }
    }

    /// Press the first menu-bar menu item in `app` whose AXTitle equals `title`.
    /// Walks the app's menu bar tree (menu bar items → menu → menu items, recursively
    /// into submenus). AXPress auto-opens the parent chain if necessary.
    public static func pressMenuItem(titled title: String, inApp app: AppTarget) throws {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityNotAuthorized }
        let pid = try pidForRunningApp(app)
        let root = AXUIElementCreateApplication(pid)

        // Get the app's menu bar (not window children — menu bar is a separate attribute).
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = menuBarValue, CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
            throw Failure.elementNotFound("menu bar of \(app.processName)")
        }
        let menuBarEl = menuBar as! AXUIElement

        guard let item = findDescendant(of: menuBarEl, matching: { attributes in
            (attributes[kAXRoleAttribute as String] as? String) == (kAXMenuItemRole as String)
                && (attributes[kAXTitleAttribute as String] as? String) == title
        }, maxDepth: 10) else {
            throw Failure.elementNotFound("menu item \"\(title)\" in \(app.processName) menu bar")
        }

        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success else { throw Failure.pressFailed(result) }
    }

    /// Convenience for Word Mac's Format Painter checkbox on the Home tab.
    /// Word exposes it as AXCheckBox title="Format" with help text
    /// "Copy formatting from one location and apply it to another".
    public static func pressWordFormatPainter() throws {
        try activate(.word)
        Thread.sleep(forTimeInterval: 0.4)
        try press(target: .wordFormatPainter, inApp: .word)
    }

    /// Two-step axClick: open a Ribbon dropdown menu, then click a cell inside
    /// it. Used for Word's Text Highlight Color / Font Color pickers under
    /// Option D (no Automation TCC). The menu's cells are AXRadioButtons keyed
    /// by VoiceOver description (e.g. "Yellow", "Bright Green"); the parent
    /// is an AXMenuButton on the Home tab.
    ///
    /// Sequence:
    ///   1. Find parent (role + title-contains).
    ///   2. AXShowMenu — opens the popup. Sleep ~250 ms for it to render.
    ///   3. Find cell anywhere in the app tree (the popup may be a sibling
    ///      window or detached AXMenu, not a child of the parent button).
    ///   4. AXPress the cell.
    ///
    /// Throws `Failure.elementNotFound` if either parent or cell is missing.
    /// Common failure modes:
    ///   - Ribbon collapsed → parent not found → user expands Ribbon
    ///   - AX permission missing → throws `accessibilityNotAuthorized`
    ///   - Office version changed cell descriptions → user re-binds via the
    ///     Add-from-Word picker (which captures fresh descriptions)
    @MainActor
    public static func showMenuThenClick(
        parentRole: String,
        parentTitleContains: String,
        cellRole: String,
        cellDescription: String,
        inApp app: AppTarget
    ) throws {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityNotAuthorized }
        let pid = try pidForRunningApp(app)
        let root = AXUIElementCreateApplication(pid)

        // 1. Locate parent menu button — use the cache to skip the ~200 ms
        //    full AX walk on subsequent fires. Cache key is per-pid so a Word
        //    relaunch automatically invalidates entries from the prior PID.
        let parentKey = "\(pid)|\(parentRole)|\(parentTitleContains)"
        let parent = cachedDescendant(of: root, cacheKey: parentKey,
            matching: { el in
                let attrs = attributeSnapshot(el)
                return (attrs[kAXRoleAttribute as String] as? String) == parentRole
                    && ((attrs[kAXTitleAttribute as String] as? String)?.contains(parentTitleContains) ?? false)
            },
            find: { root in
                findDescendant(of: root, matching: { attrs in
                    guard (attrs[kAXRoleAttribute as String] as? String) == parentRole else { return false }
                    guard let t = attrs[kAXTitleAttribute as String] as? String else { return false }
                    return t.contains(parentTitleContains)
                }, maxDepth: 25)
            }
        )
        guard let parent else {
            throw Failure.elementNotFound("parent role=\(parentRole) title~=\(parentTitleContains) (Ribbon may be collapsed)")
        }

        // 2. Open the dropdown.
        let showResult = AXUIElementPerformAction(parent, "AXShowMenu" as CFString)
        guard showResult == .success else {
            throw Failure.pressFailed(showResult)
        }

        // 3. Poll for the cell up to 600 ms in 30 ms increments, then press
        //    immediately when found. Avoids the perceptible 300 ms wall the
        //    user reported on Word Highlight, while still tolerating slow
        //    machines / cold menu opens. Re-walks from app root each tick
        //    because the popup is often rendered in a separate AXWindow,
        //    not as a child of the parent button. Description must match
        //    EXACTLY (Word's color palettes have both "Red" and "Dark Red"
        //    — `contains` would hit the wrong cell depending on tree order).
        var cell: AXUIElement?
        for _ in 0..<20 {
            cell = findDescendant(of: root, matching: { attrs in
                guard (attrs[kAXRoleAttribute as String] as? String) == cellRole else { return false }
                guard let d = attrs[kAXDescriptionAttribute as String] as? String else { return false }
                return d == cellDescription
            }, maxDepth: 25)
            if cell != nil { break }
            Thread.sleep(forTimeInterval: 0.03)
        }
        guard let cell else {
            // Close the menu (Escape) so we don't leave it open for the user.
            _ = try? closeOpenMenu(in: app)
            throw Failure.elementNotFound("cell role=\(cellRole) description=\"\(cellDescription)\" (exact) inside menu of \(parentTitleContains)")
        }

        // 4. Press the cell.
        let result = AXUIElementPerformAction(cell, kAXPressAction as CFString)
        guard result == .success else {
            _ = try? closeOpenMenu(in: app)
            throw Failure.pressFailed(result)
        }
    }

    /// Toggle Chrome's built-in Translate via JavaScript injection (NOT pixel
    /// clicks). On every fire we run a self-contained toggle script in Chrome's
    /// active tab via AppleScript's `execute javascript` — pure backend, no
    /// cursor movement, no UI flicker.
    ///
    /// The script uses Chrome 138+'s built-in `Translator` and `LanguageDetector`
    /// APIs (same engine as Chrome's own URL-bar translate icon — `cr.googleTranslate`
    /// / `chrome.translate` are wrappers around the same model). On first fire it
    /// detects the page language, walks every text node, replaces with translated
    /// text, and stores the original on a flag. On second fire it reads the flag
    /// and restores originals.
    ///
    /// Requires Chrome's `View > Developer > Allow JavaScript from Apple Events`
    /// to be enabled (one-time, per-profile). This setting is intentionally NOT
    /// AX-/AppleScript-toggleable by Chrome's design, so the user must click it
    /// once with their mouse. Ribbind's Settings → Google Chrome tab surfaces a
    /// status indicator + "Open Chrome menu" helper for this.
    public static func chromeTranslateToggle(targetLanguage: String) throws {
        // Clear any previous result so polling reads only THIS run's outcome.
        _ = try? ChromeJSAutomation.executeJS("localStorage.removeItem('_ribbindLastResult'); ''")

        let js = chromeTranslateToggleJS(targetLanguage: targetLanguage)
        do {
            _ = try ChromeJSAutomation.executeJS(js)
        } catch ChromeJSAutomation.Failure.appleScriptDisabled {
            throw Failure.elementNotFound(
                "Chrome's 'Allow JavaScript from Apple Events' is OFF — open Ribbind Settings → "
                + "Google Chrome tab and click 'Enable in Chrome' to fix this once."
            )
        } catch {
            throw Failure.elementNotFound("chromeTranslateToggle JS failed: \(error)")
        }

        // The toggle JS is an async IIFE — `execute javascript` returns
        // immediately with an empty value. The JS continues in the page and
        // eventually writes its result to `localStorage._ribbindLastResult`.
        // Poll briefly to catch fast-fail cases (GESTURE_REQUIRED, SAME_LANGUAGE,
        // etc.) so the BindingCoordinator can surface a notification. For
        // long-running successes (large pages) the poll times out and we
        // return success — the translation continues in the page; the user
        // sees text change progressively.
        let deadline = Date().addingTimeInterval(1.2)
        var raw: String? = nil
        while Date() < deadline {
            if let r = try? ChromeJSAutomation.executeJS("localStorage.getItem('_ribbindLastResult') || ''"),
               !r.isEmpty {
                raw = r
                break
            }
            Thread.sleep(forTimeInterval: 0.075)
        }

        guard let raw, !raw.isEmpty else {
            // Result not in yet — assume in flight, caller treats as success.
            NSLog("[Ribbind] chromeTranslateToggle: result still in flight (long page?), assuming success")
            return
        }
        NSLog("[Ribbind] chromeTranslateToggle result: %@", raw)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let ok = (obj["ok"] as? Bool) ?? false
        if ok { return }

        let code = (obj["code"] as? String) ?? ""
        let source = (obj["source"] as? String) ?? "?"
        let target = (obj["target"] as? String) ?? "?"
        switch code {
        case "GESTURE_REQUIRED":
            throw Failure.chromeTranslateGestureRequired(source: source, target: target)
        case "SAME_LANGUAGE":
            throw Failure.chromeTranslateSameLanguage(language: source)
        case "PAIR_UNAVAILABLE":
            throw Failure.chromeTranslatePairUnavailable(source: source, target: target)
        case "API_MISSING":
            throw Failure.chromeTranslateAPIMissing
        default:
            let detail = (obj["detail"] as? String) ?? code
            throw Failure.chromeTranslateInternal(detail)
        }
    }

    /// Build the page-side toggle script. Uses Chrome 138+'s built-in
    /// `Translator` and `LanguageDetector` APIs — same translation engine the
    /// URL-bar translate icon uses, but invoked directly. Models run on-device
    /// after a one-time download per language pair (no external network calls
    /// at translation time, no API keys, no rate limits). State is kept on
    /// `<html data-ribbindTranslated>` + each text node's `__ribbindOrig`
    /// property; toggle restores originals.
    ///
    /// **First-fire onboarding**: when `Translator.availability(...)` returns
    /// `'downloadable'` or `'downloading'`, `Translator.create(...)` requires
    /// a real user gesture (Chrome security policy — synthetic CGEvent /
    /// AppleScript injection do NOT qualify). On that path we return
    /// `{ok:false, code:'GESTURE_REQUIRED'}` so the dispatcher can surface a
    /// macOS notification pointing the user at Ribbind's "Initialize translation
    /// model" Settings flow. After a one-time download via that flow,
    /// availability becomes `'available'` and every fire works without gesture
    /// permanently.
    private static func chromeTranslateToggleJS(targetLanguage: String) -> String {
        return """
        (async function() {
            const root = document.documentElement;
            const FLAG = 'ribbindTranslated';
            const STORE = '__ribbindOrig';

            function out(o) {
                try { localStorage.setItem('_ribbindLastResult', JSON.stringify(o)); } catch (_) {}
                return JSON.stringify(o);
            }

            // ---- TOGGLE OFF: restore originals ----
            if (root.dataset[FLAG]) {
                let restored = 0;
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                const nodes = [];
                while (walker.nextNode()) nodes.push(walker.currentNode);
                for (const n of nodes) {
                    if (n[STORE] !== undefined) {
                        n.textContent = n[STORE];
                        delete n[STORE];
                        restored++;
                    }
                }
                delete root.dataset[FLAG];
                return out({ok: true, action: 'restored', count: restored});
            }

            // ---- TOGGLE ON ----
            if (typeof Translator === 'undefined') {
                return out({ok: false, code: 'API_MISSING', detail: 'Chrome 138+ required for built-in Translator API'});
            }

            const target = '\(targetLanguage)';

            // Detect source language (fall back to en if detector unavailable)
            let sourceLang = 'en';
            try {
                if (typeof LanguageDetector !== 'undefined') {
                    const detector = await LanguageDetector.create();
                    const sample = (document.body.innerText || '').substring(0, 1000);
                    if (sample.length >= 5) {
                        const results = await detector.detect(sample);
                        if (results && results.length > 0 && results[0].detectedLanguage) {
                            sourceLang = results[0].detectedLanguage;
                        }
                    }
                }
            } catch (_) { /* keep default 'en' */ }

            if (sourceLang === target) {
                return out({ok: false, code: 'SAME_LANGUAGE', source: sourceLang, target: target});
            }

            // Check model availability before attempting create
            let availability;
            try {
                availability = await Translator.availability({sourceLanguage: sourceLang, targetLanguage: target});
            } catch (e) {
                return out({ok: false, code: 'AVAILABILITY_FAILED', source: sourceLang, target: target, detail: String(e.message || e)});
            }
            if (availability === 'unavailable') {
                return out({ok: false, code: 'PAIR_UNAVAILABLE', source: sourceLang, target: target});
            }

            // Create the translator. If model isn't downloaded, this requires
            // a user gesture — we'll surface that as a typed error.
            let translator;
            try {
                translator = await Translator.create({sourceLanguage: sourceLang, targetLanguage: target});
            } catch (e) {
                const msg = String(e.message || e);
                if (msg.toLowerCase().includes('user gesture')) {
                    return out({
                        ok: false, code: 'GESTURE_REQUIRED',
                        source: sourceLang, target: target,
                        availability: availability,
                        hint: 'Open Ribbind Settings → Google Chrome → Initialize translation model'
                    });
                }
                return out({ok: false, code: 'CREATE_FAILED', source: sourceLang, target: target, detail: msg});
            }

            // Walk DOM text nodes
            const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'INPUT', 'CODE', 'PRE']);
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                acceptNode: function(n) {
                    const text = n.textContent;
                    if (!text || text.trim().length < 2) return NodeFilter.FILTER_REJECT;
                    let p = n.parentNode;
                    while (p) {
                        if (p.nodeType === Node.ELEMENT_NODE && SKIP_TAGS.has(p.tagName)) {
                            return NodeFilter.FILTER_REJECT;
                        }
                        p = p.parentNode;
                    }
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            const nodes = [];
            while (walker.nextNode()) nodes.push(walker.currentNode);

            // Translate sequentially. The on-device model is fast (~few ms per
            // short string); sequential is simpler and keeps memory usage
            // bounded on long pages.
            let translated = 0, failed = 0;
            for (const n of nodes) {
                const orig = n.textContent;
                try {
                    const tr = await translator.translate(orig);
                    n[STORE] = orig;
                    n.textContent = tr;
                    translated++;
                } catch (e) { failed++; }
            }

            root.dataset[FLAG] = target;
            return out({
                ok: true, action: 'translated',
                source: sourceLang, target: target,
                translated: translated, failed: failed, total: nodes.length
            });
        })();
        """
    }

    /// Send Escape to close any popup that AXShowMenu opened. Safe to call
    /// even when no menu is open. Best-effort; failure is non-fatal.
    private static func closeOpenMenu(in app: AppTarget) throws {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Activate the Ribbon tab whose title exactly matches `name` (e.g. "Home",
    /// "Insert"). Needed for dispatch paths that target buttons on a non-current tab:
    /// Office's Ribbon only renders the active tab's controls into the AX tree, so
    /// without switching tabs the subsequent axClick can't find its target.
    ///
    /// Strategy: AX-scan the tree **in two passes** — prefer `AXRadioButton` (which
    /// is what the tab strip uses in Word/PowerPoint Mac 16.x, verified via
    /// `word-enumerate-buttons`), fall back to `AXButton` only if no radio matches.
    /// Two passes matter: Word's AX tree also contains an `AXButton t="Home"` that
    /// is NOT the tab — pressing it does nothing for our purpose. The radio is the
    /// real tab. `maxDepth: 25` matches `press()` — tabs sit deeper than 15.
    ///
    /// If the radio's `AXValue == 1` it's already selected; we skip the press to
    /// avoid a visual flicker and return success so the caller proceeds.
    ///
    /// Silent no-ops on: no tab found (Ribbon collapsed), press failed (tab
    /// disabled). The outer axClick will attempt anyway and report its own error.
    @discardableResult
    @MainActor
    public static func activateTab(name: String, inApp app: AppTarget) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let pid = try? pidForRunningApp(app) else { return false }
        let root = AXUIElementCreateApplication(pid)

        // Use the cache: tab radios don't move once Ribbon is rendered, so
        // walking the AX tree on every hotkey fire is pure latency. Cache
        // miss path runs the original two-pass scan.
        let cacheKey = "\(pid)|TAB|\(name)"
        let tab = cachedDescendant(of: root, cacheKey: cacheKey,
            matching: { el in
                let attrs = attributeSnapshot(el)
                guard let r = attrs[kAXRoleAttribute as String] as? String,
                      (r == (kAXRadioButtonRole as String) || r == (kAXButtonRole as String))
                else { return false }
                return (attrs[kAXTitleAttribute as String] as? String) == name
            },
            find: { root in
                // Pass 1: AXRadioButton (the Ribbon tab strip).
                let radio = findDescendant(of: root, matching: { attrs in
                    let role = attrs[kAXRoleAttribute as String] as? String
                    guard role == (kAXRadioButtonRole as String) else { return false }
                    guard let t = attrs[kAXTitleAttribute as String] as? String else { return false }
                    return t == name
                }, maxDepth: 25)
                if radio != nil { return radio }
                // Pass 2: AXButton fallback (unusual variants).
                return findDescendant(of: root, matching: { attrs in
                    let role = attrs[kAXRoleAttribute as String] as? String
                    guard role == (kAXButtonRole as String) else { return false }
                    guard let t = attrs[kAXTitleAttribute as String] as? String else { return false }
                    return t == name
                }, maxDepth: 25)
            }
        )

        guard let tab else {
            NSLog("[Ribbind] activateTab: no tab named \"%@\" in %@ (Ribbon collapsed?)", name, app.processName)
            return false
        }

        // AXValue on a radio is NSNumber 1 when selected. Skip the press when
        // already active so the UI doesn't blink on every hotkey fire — and
        // skip the 400 ms post-press sleep too (huge latency win on the hot
        // path where the user is already on Home).
        if let v = attributeSnapshot(tab)[kAXValueAttribute as String] as? NSNumber, v.intValue == 1 {
            return true
        }

        let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        if result != .success {
            NSLog("[Ribbind] activateTab: press \"%@\" failed with AXError %d", name, result.rawValue)
            return false
        }
        Thread.sleep(forTimeInterval: 0.4)
        return true
    }

    /// Walk the app's menu-bar tree and collect every `AXMenuItem` title. Used by the
    /// "Add from app" picker to surface menu items alongside Ribbon buttons.
    public static func enumerateMenuItems(inApp app: AppTarget) throws -> [(title: String, menuPath: [String])] {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityNotAuthorized }
        let pid = try pidForRunningApp(app)
        let root = AXUIElementCreateApplication(pid)

        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = menuBarValue, CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
            return []
        }
        let menuBarEl = menuBar as! AXUIElement

        var out: [(String, [String])] = []
        func walk(_ el: AXUIElement, path: [String], depth: Int) {
            guard depth < 8 else { return }
            let attrs = attributeSnapshot(el)
            let role = attrs[kAXRoleAttribute as String] as? String
            let title = (attrs[kAXTitleAttribute as String] as? String) ?? ""
            if role == (kAXMenuItemRole as String), !title.isEmpty {
                out.append((title, path))
            }
            let newPath = title.isEmpty ? path : path + [title]
            if let children = childrenOf(el) {
                for child in children { walk(child, path: newPath, depth: depth + 1) }
            }
        }
        walk(menuBarEl, path: [], depth: 0)
        return out
    }

    /// Debug helper: return every actionable element reachable from the app root, with all
    /// its identity attributes. Useful for discovering the actual title/role of Ribbon
    /// controls across Office versions.
    public static func enumerateElements(inApp app: AppTarget, maxDepth: Int = 25) throws -> [(title: String, description: String, role: String, help: String, identifier: String)] {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityNotAuthorized }
        let pid = try pidForRunningApp(app)
        let root = AXUIElementCreateApplication(pid)
        var out: [(String, String, String, String, String)] = []

        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            let attrs = attributeSnapshot(node)
            let role = (attrs[kAXRoleAttribute as String] as? String) ?? ""
            let title = (attrs[kAXTitleAttribute as String] as? String) ?? ""
            let desc = (attrs[kAXDescriptionAttribute as String] as? String) ?? ""
            let help = (attrs[kAXHelpAttribute as String] as? String) ?? ""
            let identifier = (attrs[kAXIdentifierAttribute as String] as? String) ?? ""
            if !title.isEmpty || !desc.isEmpty || !help.isEmpty || !identifier.isEmpty {
                out.append((title, desc, role, help, identifier))
            }
            if depth >= maxDepth { continue }
            if let children = childrenOf(node) {
                for child in children {
                    stack.append((child, depth + 1))
                }
            }
        }
        return out
    }

    // MARK: - Helpers

    public static func activate(_ app: AppTarget) throws {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID(for: app)
        }) else {
            throw Failure.appNotRunning(app.processName)
        }
        running.activate()
    }

    private static func pidForRunningApp(_ app: AppTarget) throws -> pid_t {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID(for: app)
        }) else {
            throw Failure.appNotRunning(app.processName)
        }
        return running.processIdentifier
    }

    private static func bundleID(for app: AppTarget) -> String {
        switch app {
        case .word: return "com.microsoft.Word"
        case .powerpoint: return "com.microsoft.Powerpoint"
        case .chrome: return "com.google.Chrome"
        }
    }

    /// Depth-first search for the first AXUIElement whose attribute snapshot passes `matches`.
    /// `matches` receives a map of every scalar attribute the element exposes.
    private static func findDescendant(
        of root: AXUIElement,
        matching matches: ([String: Any]) -> Bool,
        maxDepth: Int
    ) -> AXUIElement? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            let attrs = attributeSnapshot(node)
            if matches(attrs) { return node }
            if depth >= maxDepth { continue }
            if let children = childrenOf(node) {
                for child in children {
                    stack.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    private static func attributeSnapshot(_ element: AXUIElement) -> [String: Any] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let attrList = names as? [String] else { return [:] }

        var out: [String: Any] = [:]
        for name in attrList {
            // Skip children-ish attributes — they explode the snapshot.
            if name == kAXChildrenAttribute as String { continue }
            if name == kAXVisibleChildrenAttribute as String { continue }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
               let v = value {
                out[name] = v
            }
        }
        return out
    }

    private static func childrenOf(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return nil }
        return array
    }
}

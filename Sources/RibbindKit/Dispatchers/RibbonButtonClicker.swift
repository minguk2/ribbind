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

    /// Press the first element in the frontmost document window that matches `target`.
    public static func press(target: RibbonTarget, inApp app: AppTarget) throws {
        guard AXIsProcessTrusted() else {
            throw Failure.accessibilityNotAuthorized
        }
        let pid = try pidForRunningApp(app)
        let appRoot = AXUIElementCreateApplication(pid)
        let root = actionRoot(from: appRoot)

        // Defense-in-depth: reject targets that would match the first element in the
        // tree. `DispatchRecipe` already rejects these at decode time, but axClick
        // matchers can be constructed directly from code too.
        let hasNeedle = [target.titleContains, target.helpContains, target.descriptionContains]
            .compactMap { $0 }.contains { !$0.isEmpty }
        guard hasNeedle else {
            throw Failure.elementNotFound("axClick target has no non-empty matcher — refusing to press first matching role")
        }

        guard let element = findDescendant(of: root.element, matching: { attributes in
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
            throw Failure.elementNotFound("role=\(target.role) title~=\(target.titleContains ?? "*") help~=\(target.helpContains ?? "*") in \(root.label)")
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
        let appRoot = AXUIElementCreateApplication(pid)
        let root = actionRoot(from: appRoot)

        // 1. Locate parent menu button — use the cache to skip the ~200 ms
        //    full AX walk on subsequent fires. Cache key includes the active
        //    window scope so multiple Word/PPT documents don't share stale
        //    Ribbon elements.
        let parentKey = "\(pid)|\(root.cacheScope)|\(parentRole)|\(parentTitleContains)"
        let parent = cachedDescendant(of: root.element, cacheKey: parentKey,
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
            throw Failure.elementNotFound("parent role=\(parentRole) title~=\(parentTitleContains) in \(root.label) (Ribbon may be collapsed)")
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
            cell = findDescendant(of: appRoot, matching: { attrs in
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
        let appRoot = AXUIElementCreateApplication(pid)
        let root = actionRoot(from: appRoot)

        // Use the cache: tab radios don't move once Ribbon is rendered, so
        // walking the AX tree on every hotkey fire is pure latency. Cache
        // miss path runs the original two-pass scan. The active window is part
        // of the key because Office exposes one Ribbon per document window.
        let cacheKey = "\(pid)|\(root.cacheScope)|TAB|\(name)"
        let tab = cachedDescendant(of: root.element, cacheKey: cacheKey,
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
            NSLog("[Ribbind] activateTab: no tab named \"%@\" in %@ %@ (Ribbon collapsed?)", name, app.processName, root.label)
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

    private struct ActionRoot {
        let element: AXUIElement
        let cacheScope: String
        let label: String
    }

    /// Office exposes one Ribbon per document window. Search the focused/main
    /// window first so AXPress doesn't hit a matching button in another open deck.
    private static func actionRoot(from appRoot: AXUIElement) -> ActionRoot {
        if let window = attributeElement(appRoot, kAXFocusedWindowAttribute as String)
            ?? attributeElement(appRoot, kAXMainWindowAttribute as String) {
            let attrs = attributeSnapshot(window)
            let title = (attrs[kAXTitleAttribute as String] as? String) ?? ""
            let position = axPointDescription(attrs[kAXPositionAttribute as String])
            let size = axSizeDescription(attrs[kAXSizeAttribute as String])
            let scope = "window|\(title)|\(position)|\(size)"
            let label = title.isEmpty ? "focused window" : "focused window \"\(title)\""
            return ActionRoot(element: window, cacheScope: scope, label: label)
        }
        return ActionRoot(element: appRoot, cacheScope: "app", label: "app root")
    }

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

    private static func attributeElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return (raw as! AXUIElement)
    }

    private static func axPointDescription(_ value: Any?) -> String {
        guard let value else { return "pos=?" }
        let raw = value as CFTypeRef
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return "pos=?" }
        let axValue = raw as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint,
              AXValueGetValue(axValue, .cgPoint, &point) else {
            return "pos=?"
        }
        return String(format: "pos=%.0f,%.0f", point.x, point.y)
    }

    private static func axSizeDescription(_ value: Any?) -> String {
        guard let value else { return "size=?" }
        let raw = value as CFTypeRef
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return "size=?" }
        let axValue = raw as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize,
              AXValueGetValue(axValue, .cgSize, &size) else {
            return "size=?"
        }
        return String(format: "size=%.0f,%.0f", size.width, size.height)
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

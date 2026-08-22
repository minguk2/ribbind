import Foundation
import AppKit
import ApplicationServices

/// Thread-safe, **non-`@MainActor`** Accessibility primitives.
///
/// `RibbonButtonClicker` has similar helpers, but they are `private` and its element
/// cache forces `@MainActor` on the methods that use them — which is wrong for the
/// long-running work in this file's callers (a deck-wide font pass, a Chrome menu
/// poll). Blocking the main actor freezes the MenuBarExtra icon, so these run off it.
///
/// ## Why the searches look paranoid
///
/// Both guards below were paid for empirically (see `research/09-chrome-native-translate-ax.md`):
///
/// * **Cycles.** Chrome's `AXWindows` can return elements whose role is
///   `AXApplication` and whose children include themselves. A plain depth-first walk
///   doubles per level — measured 54,716 nodes and 23–26 s before giving up, with
///   node counts *identical* on a huge page and on `example.org`, proving it was the
///   cycle and not page content.
/// * **Web content.** An `AXWebArea` subtree is unbounded and irrelevant to browser
///   or Ribbon chrome.
///
/// So every traversal here is breadth-first, depth-capped, node-capped, and prunes
/// `AXApplication` / `AXWebArea`. With those guards the same lookup that took 23 s
/// takes 39 ms.
public enum AXProbe {

    // MARK: - Attributes

    public static func app(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// Bound every AX call on this element's process, so a wedged app surfaces as an
    /// `AXError` instead of blocking the calling thread indefinitely.
    public static func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s == "1" || s.lowercased() == "true" }
        return nil
    }

    public static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute as String) ?? ""
    }

    public static func subrole(_ element: AXUIElement) -> String {
        string(element, kAXSubroleAttribute as String) ?? ""
    }

    public static func title(_ element: AXUIElement) -> String {
        string(element, kAXTitleAttribute as String) ?? ""
    }

    public static func desc(_ element: AXUIElement) -> String {
        string(element, kAXDescriptionAttribute as String) ?? ""
    }

    public static func value(_ element: AXUIElement) -> String {
        string(element, kAXValueAttribute as String) ?? ""
    }

    public static func isEnabled(_ element: AXUIElement) -> Bool {
        bool(element, kAXEnabledAttribute as String) ?? true
    }

    public static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    /// Windows of an application element, with self-referential entries removed.
    /// Anything whose role is not literally `AXWindow` is a lie the tree is telling.
    ///
    /// Do not use this alone — see `allWindows(of:)`. `AXWindows` is empty on Chrome
    /// whenever Chrome is not the active application (verified: 0 windows when
    /// backgrounded, 1 the moment it is activated), even though the window plainly
    /// exists and `AXFocusedWindow` returns it.
    public static func windows(of appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array.filter { role($0) == "AXWindow" }
    }

    private static func single(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value else { return nil }
        let candidate = raw as! AXUIElement
        return role(candidate) == "AXWindow" ? candidate : nil
    }

    /// Every window we can reach, from all three sources, de-duplicated.
    ///
    /// `AXWindows` alone is not enough (empty while the app is backgrounded), and
    /// focused/main alone is not enough either (they never include an auxiliary
    /// window such as Chrome's translate bubble). Union them.
    public static func allWindows(of appElement: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func add(_ candidate: AXUIElement?) {
            guard let candidate else { return }
            if out.contains(where: { CFEqual($0, candidate) }) { return }
            out.append(candidate)
        }
        for window in windows(of: appElement) { add(window) }
        for child in children(of: appElement) where role(child) == "AXWindow" { add(child) }
        add(single(appElement, kAXFocusedWindowAttribute as String))
        add(single(appElement, kAXMainWindowAttribute as String))
        return out
    }

    public static func actionNames(of element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let array = value as? [String] else { return [] }
        return array
    }

    public static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    // MARK: - Actions

    @discardableResult
    public static func perform(_ element: AXUIElement, _ action: String = kAXPressAction as String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    /// Post a real Escape key event.
    ///
    /// `AXUIElementPerformAction(popup, "AXCancel")` does **not** close an open
    /// popup menu in Office — verified by screenshot while debugging the Replace
    /// Fonts dialog, where a menu left open silently swallowed the next press on a
    /// different control and looked like "the second menu never opened".
    public static func pressEscape() {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.12)
    }

    /// Post a Return key event.
    public static func pressReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Type `text` as unicode keystrokes.
    ///
    /// Needed for menu type-ahead: in a long scrollable popup menu (PowerPoint's
    /// 581-entry font list) pressing an off-screen `AXMenuItem` — via `AXPress`
    /// *or* `AXPick` — silently activates item 0 instead of the target. Typing the
    /// name is what a person does, and it is the only thing that selects correctly.
    public static func type(_ text: String, perCharacterDelay: TimeInterval = 0.05) {
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var unit = UniChar(scalar.value)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                up.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: perCharacterDelay)
        }
    }

    /// Ask the UI to scroll `element` into view.
    ///
    /// Matters for long popup menus: an item below the fold can't be activated by
    /// `AXPress` (the press lands on the highlighted item instead), but once it is
    /// scrolled into view the press hits the right row.
    @discardableResult
    public static func scrollToVisible(_ element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
    }

    /// Set a menu's selected child, which both highlights and scrolls to it.
    @discardableResult
    public static func setSelectedChild(_ container: AXUIElement, _ child: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(container, kAXSelectedChildrenAttribute as CFString, [child] as CFArray)
    }

    // MARK: - Search

    /// Breadth-first, depth-capped, node-capped, cycle-pruned search.
    ///
    /// `maxNodes` is a hard stop, not a nicety: it is what turns a cyclic tree from a
    /// hang into a miss.
    public static func find(
        in root: AXUIElement,
        maxDepth: Int,
        maxNodes: Int = 4000,
        firstOnly: Bool = true,
        where match: (AXUIElement, String) -> Bool
    ) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let elementRole = role(element)
            // Prune: AXApplication inside a window subtree is a cycle back to the
            // app root; AXWebArea is unbounded page content.
            if elementRole == "AXApplication" || elementRole == "AXWebArea" { continue }
            if match(element, elementRole) {
                found.append(element)
                if firstOnly { return found }
            }
            if depth < maxDepth {
                for child in children(of: element) { queue.append((child, depth + 1)) }
            }
        }
        return found
    }

    /// Poll `probe` until it returns non-nil or `timeout` elapses.
    public static func poll<T>(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        _ probe: () -> T?
    ) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = probe() { return value }
            Thread.sleep(forTimeInterval: interval)
        }
        return probe()
    }

    // MARK: - Diagnostics

    public struct Node: Sendable {
        public let depth: Int
        public let role: String
        public let subrole: String
        public let title: String
        public let desc: String
        public let value: String
        public let identifier: String
        public let enabled: Bool
        public let actions: [String]
        public let valueSettable: Bool
        public let childCount: Int

        public var line: String {
            var out = String(repeating: "  ", count: depth) + role
            if !subrole.isEmpty { out += "(\(subrole))" }
            if !title.isEmpty { out += " title=\"\(title)\"" }
            if !desc.isEmpty { out += " desc=\"\(desc)\"" }
            if !value.isEmpty { out += " val=\"\(value)\"" }
            if !identifier.isEmpty { out += " id=\"\(identifier)\"" }
            if !enabled { out += " DISABLED" }
            if !actions.isEmpty { out += " acts=\(actions)" }
            if valueSettable { out += " [valueSettable]" }
            if childCount > 0 { out += " kids=\(childCount)" }
            return out
        }
    }

    /// Flatten a subtree for spike subcommands. Same pruning and caps as `find`.
    public static func dump(_ root: AXUIElement, maxDepth: Int, maxNodes: Int = 400) -> [Node] {
        var out: [Node] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            if depth > maxDepth || out.count >= maxNodes { return }
            let elementRole = role(element)
            if elementRole == "AXApplication" && depth > 0 { return }
            let kids = elementRole == "AXWebArea" ? [] : children(of: element)
            out.append(Node(
                depth: depth,
                role: elementRole,
                subrole: subrole(element),
                title: title(element),
                desc: desc(element),
                value: value(element),
                identifier: string(element, "AXIdentifier") ?? "",
                enabled: isEnabled(element),
                actions: actionNames(of: element),
                valueSettable: isSettable(element, kAXValueAttribute as String),
                childCount: kids.count
            ))
            for child in kids { walk(child, depth + 1) }
        }
        walk(root, 0)
        return out
    }
}

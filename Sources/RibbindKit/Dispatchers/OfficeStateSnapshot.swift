import AppKit
import ApplicationServices
import Foundation

/// State snapshot of Word / PowerPoint used by the e2e verifier. Fields are
/// read via AppleScript (so they don't require Office to be frontmost — Apple
/// Events are delivered to backgrounded apps just fine) plus a tiny AX read
/// for the active Ribbon tab. Diff across two snapshots drives positive +
/// negative assertions per `verify-dispatch` protocol.
///
/// Only read-only properties — never writes. The whole point is that the
/// snapshot is an independent ground truth against which dispatch effects are
/// judged.
public struct OfficeStateSnapshot: Equatable, Sendable {
    public let app: AppTarget
    public let timestamp: Date

    // Universal fields (Word + PPT)
    public let selectionText: String?
    public let selectionKind: String?        // word: "text"/"range"; ppt: "text range"/"shape range"/"slides"/"none"
    public let activeTabName: String?        // Ribbon tab that's currently rendered ("Home", "Insert"…)
    public let fontColor: [Int]?             // 16-bit RGB list {r, g, b}; nil when no font selected
    public let fontBold: Bool?               // nil if no font state available
    public let fontName: String?             // Word: name of font object of selection (selection-scoped)

    // Word-specific
    public let wordShadingBg: [Int]?         // 16-bit RGB of shading.background pattern color (legacy field — Ribbind no longer writes here for highlights)
    public let wordHighlightName: String?    // WdColorIndex enum name (e.g. "yellow", "no highlight") of the first character; populated by `highlight color index of text object`
    public let wordDocumentCount: Int?

    // PowerPoint-specific
    public let pptShapeCountCurrentSlide: Int?
    public let pptActiveSlideIndex: Int?
    public let pptPresentationCount: Int?

    // MARK: - Read

    /// Run the snapshot reader AS against the live app. Returns nil fields for
    /// anything the app couldn't report (no document open, selection is empty,
    /// Automation not granted, etc.) — so the snapshot always succeeds even
    /// when the target is in an "idle" state.
    @MainActor
    public static func take(for app: AppTarget) -> OfficeStateSnapshot {
        switch app {
        case .word:      return takeWord()
        case .powerpoint: return takePowerPoint()
        case .chrome:    return takeChrome()
        }
    }

    /// Chrome doesn't expose Office-style state (no selection text, no shape
    /// counts, no shading). The e2e harness only needs a valid snapshot for
    /// scenarios marked `manualVerifyOnly: true` — return all-nil so diffs
    /// always come back empty.
    @MainActor
    private static func takeChrome() -> OfficeStateSnapshot {
        return OfficeStateSnapshot(
            app: .chrome,
            timestamp: Date(),
            selectionText: nil,
            selectionKind: nil,
            activeTabName: nil,
            fontColor: nil,
            fontBold: nil,
            fontName: nil,
            wordShadingBg: nil,
            wordHighlightName: nil,
            wordDocumentCount: nil,
            pptShapeCountCurrentSlide: nil,
            pptActiveSlideIndex: nil,
            pptPresentationCount: nil
        )
    }

    /// Field-by-field diff. Returns the keys whose values changed between
    /// `before` and `after`, paired with both sides for the failure message.
    public func diff(against other: OfficeStateSnapshot) -> [(field: String, before: String, after: String)] {
        var out: [(String, String, String)] = []
        func check<T: Equatable>(_ name: String, _ a: T?, _ b: T?) {
            if a != b {
                out.append((name, String(describing: a as Any), String(describing: b as Any)))
            }
        }
        check("selectionText",       self.selectionText, other.selectionText)
        check("selectionKind",       self.selectionKind, other.selectionKind)
        check("activeTabName",       self.activeTabName, other.activeTabName)
        check("fontColor",           self.fontColor, other.fontColor)
        check("fontBold",            self.fontBold, other.fontBold)
        check("fontName",            self.fontName, other.fontName)
        check("wordShadingBg",       self.wordShadingBg, other.wordShadingBg)
        check("wordHighlightName",   self.wordHighlightName, other.wordHighlightName)
        check("wordDocumentCount",   self.wordDocumentCount, other.wordDocumentCount)
        check("pptShapeCountCurrentSlide", self.pptShapeCountCurrentSlide, other.pptShapeCountCurrentSlide)
        check("pptActiveSlideIndex", self.pptActiveSlideIndex, other.pptActiveSlideIndex)
        check("pptPresentationCount", self.pptPresentationCount, other.pptPresentationCount)
        return out
    }

    // MARK: - Word reader

    @MainActor
    private static func takeWord() -> OfficeStateSnapshot {
        // Single AS round-trip — reading multiple fields in one tell block is
        // faster and more consistent (no state change between reads).
        // Read font attributes from the FIRST CHARACTER of the first document.
        // This is selection-independent — the scratch doc is shared across
        // all scenarios, and tests write to the whole text range, so char 1's
        // attributes reflect what the dispatch just did. Avoids the
        // "selection collapsed after write → read fails" failure mode of
        // selection-based reads.
        let source = """
        tell application "Microsoft Word"
            set acc to ""
            try
                set acc to acc & "docs=" & (count of documents) & linefeed
            end try
            try
                tell first document
                    set c to first character of text object
                    set acc to acc & "text=" & (content of text object of selection) & linefeed
                    try
                        set fc to color of font object of c
                        if fc is not missing value then
                            set acc to acc & "fontColor=" & (item 1 of fc as text) & "," & (item 2 of fc as text) & "," & (item 3 of fc as text) & linefeed
                        end if
                    end try
                    try
                        set acc to acc & "bold=" & (bold of font object of c as text) & linefeed
                    end try
                end tell
            end try
            -- Read shading at APP scope (not inside `tell first document`) — Word's
            -- `selection` resolves correctly as a global property; nesting under
            -- `tell first document` makes `text object of selection` evaluate to
            -- missing value (verified empirically 2026-04-25).
            -- Use `font object of selection` (NOT `text object of selection`):
            -- `shading of text object` is paragraph-scoped (the v0.6.0 highlight bug);
            -- `shading of font object` reads the selection-scoped shading the dispatch
            -- writes to. (Verified empirically 2026-04-25 PM.)
            try
                set bg to background pattern color of shading of font object of selection
                if bg is not missing value then
                    set acc to acc & "shading=" & (item 1 of bg as text) & "," & (item 2 of bg as text) & "," & (item 3 of bg as text) & linefeed
                end if
            end try
            -- Read the highlight color index (WdColorIndex enum). After the
            -- v0.6.0 highlight rework, Ribbind writes here (not into shading)
            -- so Word's Home > Text Highlight Color > No Color can clear it.
            try
                tell first document
                    tell first character of text object
                        set hc to highlight color index of text object
                        set acc to acc & "highlightName=" & (hc as text) & linefeed
                    end tell
                end tell
            end try
            -- Selection-scoped font name (matches the dispatch path which writes via
            -- `name of font object of selection`).
            try
                set fn to name of font object of selection
                if fn is not missing value then
                    set acc to acc & "fontName=" & fn & linefeed
                end if
            end try
            return acc
        end tell
        """
        let blob = (try? AppleScriptRunner.run(source)) ?? nil ?? ""
        let fields = parseKV(blob)

        return OfficeStateSnapshot(
            app: .word,
            timestamp: Date(),
            selectionText: fields["text"],
            selectionKind: fields["kind"],
            activeTabName: readActiveTab(for: .word),
            fontColor: parseIntTriplet(fields["fontColor"]),
            fontBold: fields["bold"].map { $0 == "true" },
            fontName: fields["fontName"],
            wordShadingBg: parseIntTriplet(fields["shading"]),
            wordHighlightName: fields["highlightName"],
            wordDocumentCount: fields["docs"].flatMap(Int.init),
            pptShapeCountCurrentSlide: nil,
            pptActiveSlideIndex: nil,
            pptPresentationCount: nil
        )
    }

    // MARK: - PowerPoint reader

    @MainActor
    private static func takePowerPoint() -> OfficeStateSnapshot {
        // Retry once if the first read returns no shape-count field —
        // PowerPoint sometimes races between "make new presentation" + "add
        // slide" and our read arriving; a short sleep resolves it.
        func attempt() -> [String: String] {
            let blob = (try? AppleScriptRunner.run(sourceBody)) ?? nil ?? ""
            return parseKV(blob)
        }
        var fields = attempt()
        if fields["shapeCount"] == nil && (Int(fields["slideCount"] ?? "0") ?? 0) > 0 {
            Thread.sleep(forTimeInterval: 0.3)
            fields = attempt()
        }
        return OfficeStateSnapshot(
            app: .powerpoint,
            timestamp: Date(),
            selectionText: fields["text"],
            selectionKind: fields["kind"],
            activeTabName: readActiveTab(for: .powerpoint),
            fontColor: parseIntTriplet(fields["fontColor"]),
            fontBold: fields["bold"].map { $0 == "true" },
            fontName: fields["fontName"],
            wordShadingBg: nil,
            wordHighlightName: nil,
            wordDocumentCount: nil,
            pptShapeCountCurrentSlide: fields["shapeCount"].flatMap(Int.init),
            pptActiveSlideIndex: fields["slideIdx"].flatMap(Int.init),
            pptPresentationCount: fields["pres"].flatMap(Int.init)
        )
    }

    private static let sourceBody: String = """
        tell application "Microsoft PowerPoint"
            set acc to ""
            try
                set acc to acc & "pres=" & (count of presentations) & linefeed
            end try
            try
                set sc to count of slides of active presentation
                set acc to acc & "slideCount=" & sc & linefeed
                if sc > 0 then
                    set sl to slide 1 of active presentation
                    set acc to acc & "slideIdx=" & (slide index of sl) & linefeed
                    set acc to acc & "shapeCount=" & (count of shapes of sl) & linefeed
                end if
            end try
            try
                set sel to selection of active window
                try
                    set tr to text range of sel
                    set acc to acc & "text=" & (content of tr) & linefeed
                    set fc to font color of font of tr
                    set acc to acc & "fontColor=" & (item 1 of fc as text) & "," & (item 2 of fc as text) & "," & (item 3 of fc as text) & linefeed
                end try
            end try
            return acc
        end tell
        """

    // MARK: - Helpers

    private static func parseKV(_ blob: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in blob.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let val = String(line[line.index(after: eq)...])
            out[key] = val
        }
        return out
    }

    private static func parseIntTriplet(_ raw: String?) -> [Int]? {
        guard let raw, raw != "?", !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 3 ? parts : nil
    }

    /// Known Ribbon tab names across Word and PowerPoint Mac. Used as an
    /// allow-list so our tab reader doesn't accidentally return the view-mode
    /// radio (Print Layout / Web Layout / Normal / Slide Sorter …) — those
    /// are AXRadioButtons with the same role and a selected-state bit, but
    /// they live in a side panel, not the Ribbon. Only Ribbon tab names
    /// should pass through.
    private static let ribbonTabNames: Set<String> = [
        // Common to both
        "Home", "Insert", "Design", "Review", "View",
        // Word-specific
        "Draw", "Layout", "References", "Mailings", "Developer", "Zotero",
        // PowerPoint-specific
        "Transitions", "Animations", "Slide Show", "Recording",
        "Shape Format", "Picture Format", "Table Design", "Table Layout",
        "Chart Design"
    ]

    /// Read the currently-selected Ribbon tab's title by walking the AX tree
    /// for `AXRadioButton` elements whose `AXValue == 1`. Filtered against
    /// `ribbonTabNames` so we skip the view-mode radio buttons that share
    /// the same role+value shape but aren't on the Ribbon.
    @MainActor
    private static func readActiveTab(for app: AppTarget) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        // Chrome has no Ribbon, so there's no "active tab" to read.
        if app == .chrome { return nil }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == OfficeAppProbe.bundleID(for: app)
        }) else { return nil }
        let root = AXUIElementCreateApplication(running.processIdentifier)
        return findFirstSelectedTab(root: root, maxDepth: 25)
    }

    private static func findFirstSelectedTab(root: AXUIElement, maxDepth: Int) -> String? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            if let r = role as? String, r == (kAXRadioButtonRole as String) {
                var value: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &value)
                if let v = value as? NSNumber, v.intValue == 1 {
                    var title: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(node, kAXTitleAttribute as CFString, &title)
                    if let t = title as? String, ribbonTabNames.contains(t) {
                        return t
                    }
                }
            }
            if depth >= maxDepth { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let arr = children as? [AXUIElement] {
                for c in arr { stack.append((c, depth + 1)) }
            }
        }
        return nil
    }
}

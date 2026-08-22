import Foundation
import AppKit
import ApplicationServices

/// Applies one font to an entire presentation by driving PowerPoint's own
/// **Format ▸ Replace Fonts…** dialog over the Accessibility API, once per font the
/// deck actually uses, then setting the theme's major/minor fonts to match.
///
/// ## Why the dialog instead of a shape sweep
///
/// A per-shape AppleScript loop *cannot* be exhaustive, and the user asked for
/// "빠짐없이" (no exceptions). PowerPoint's AppleScript cannot index into group
/// children: `count of shapes of <group>` returns a correct count, but
/// `shape 1 of <group>` fails `-1700`/`-1728` on every property. A real 61-slide
/// deck had 22 groups. `count of fonts of active presentation` works, but
/// `font 1 of …` also fails `-1700`, so even the used-font list is unreachable from
/// AppleScript.
///
/// Replace Fonts is PowerPoint's own feature: it reaches grouped shapes, table
/// cells, masters, layouts and notes, and each replacement lands on the normal undo
/// stack. Shipping a shape sweep and calling it exhaustive would be exactly the
/// approximation CLAUDE.md's NO FAKE IMPLEMENTATIONS rule forbids.
///
/// Everything below is backed by `research/08-ppt-replace-fonts-ax.md`.
public enum PowerPointFontReplacer {

    // MARK: - Types

    public struct Presentation: Identifiable, Hashable, Sendable {
        public let index: Int
        public let name: String
        public let path: String?
        public var id: String { "\(index)|\(name)" }
        public var isSaved: Bool { (path?.hasPrefix("/")) == true }
        public var folder: String? {
            guard let path else { return nil }
            return (path as NSString).deletingLastPathComponent
        }
    }

    public enum Phase: Equatable, Sendable {
        case preparing
        case openingDialog
        case readingFonts
        case replacing(font: String)
        case settingThemeFonts
        case closingDialog
        case done
    }

    public struct Progress: Equatable, Sendable {
        public let phase: Phase
        public let completed: Int
        public let total: Int
        public let message: String
    }

    public struct Report: Sendable {
        public let target: String
        public let replaced: [String]
        public let failed: [String]
        public let themeSlots: [String]
        public let themeFailures: [String]
        public let usedFontsBefore: Int?
        public let usedFontsAfter: Int?
        public let duration: TimeInterval
        /// True only when nothing failed AND PowerPoint itself confirms the deck is
        /// down to a single font in use.
        ///
        /// `failed` now also carries anything still listed in the dialog's
        /// "Replace:" list at the end, so a run that quietly replaced nothing can no
        /// longer report success — that false positive is exactly what this guards.
        public var isComplete: Bool { failed.isEmpty && (usedFontsAfter ?? 99) <= 1 }
    }

    public enum Failure: Error, CustomStringConvertible {
        case accessibilityNotAuthorized
        case powerPointNotRunning
        case noPresentationOpen
        case automationDenied
        case wrongPresentationFront(expected: String, actual: String)
        case menuItemMissing
        case dialogNotFound
        case popupNotFound(String)
        case fontNotSelectable(font: String, popup: String, got: String)
        case targetFontUnavailable(String)
        case replaceStalled(font: String)
        case cancelled(afterReplacements: Int)

        public var description: String {
            switch self {
            case .accessibilityNotAuthorized:
                return "Accessibility permission not granted"
            case .powerPointNotRunning:
                return "PowerPoint isn't running"
            case .noPresentationOpen:
                return "No presentation is open in PowerPoint"
            case .automationDenied:
                return "PowerPoint denied Apple Events. Allow it in System Settings → Privacy & Security → Automation."
            case .wrongPresentationFront(let expected, let actual):
                return "Couldn't bring \"\(expected)\" to the front (PowerPoint is showing \"\(actual)\"). Switch to it in PowerPoint and try again."
            case .menuItemMissing:
                return "PowerPoint's Format ▸ Replace Fonts… menu item wasn't found"
            case .dialogNotFound:
                return "The Replace Font dialog didn't open"
            case .popupNotFound(let which):
                return "The \"\(which)\" control wasn't found in the Replace Font dialog"
            case .fontNotSelectable(let font, let popup, let got):
                return "Couldn't select \"\(font)\" in the \(popup) list (it read back as \"\(got)\")"
            case .targetFontUnavailable(let font):
                return "PowerPoint doesn't offer \"\(font)\" in its font list"
            case .replaceStalled(let font):
                return "PowerPoint stopped responding while replacing \"\(font)\""
            case .cancelled(let n):
                return "Cancelled after \(n) replacement(s)"
            }
        }
    }

    public final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        public init() {}
        public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    // MARK: - AX identifiers (verified — research/08)

    /// Three ASCII periods, **not** U+2026. `AXTitle` is matched exactly, so this
    /// distinction decides whether the menu item is found at all.
    private static let menuItemTitle = "Replace Fonts..."
    private static let dialogTitle = "Replace Font"   // singular, unlike the menu item
    private static let replacePopupDesc = "Font list to be replaced"
    private static let withPopupDesc = "Available font list"

    // MARK: - Read-only queries

    public static func listOpenPresentations(timeout: TimeInterval = 4) throws -> [Presentation] {
        try requirePowerPoint()
        let script = listPresentationsScript
        let fields = parseKV(try runScript(script, timeout: timeout) ?? "")
        let count = Int(fields["count"] ?? "0") ?? 0
        // `1...count` traps when count is 0 — and 0 is the normal case whenever
        // PowerPoint has no document open, which the Settings panel polls into
        // every few seconds. Guard first; do NOT rely on max(count, 0), which
        // still yields the invalid range 1...0.
        return presentations(from: fields)
    }

    /// Pure parse step, split out so the zero-presentation case is unit-testable
    /// without Office running. That case crashed the app: `1...count` traps when
    /// count is 0, and the Settings panel polls this every few seconds, so an empty
    /// PowerPoint took Ribbind down repeatedly.
    public static func presentations(from fields: [String: String]) -> [Presentation] {
        let count = Int(fields["count"] ?? "0") ?? 0
        guard count > 0 else { return [] }
        return (1...count).compactMap { index -> Presentation? in
            guard let name = fields["name\(index)"] else { return nil }
            return Presentation(index: index, name: name, path: fields["path\(index)"])
        }
    }

    static let listPresentationsScript = """
    tell application "Microsoft PowerPoint"
        set accumulator to ""
        set presentationCount to count of presentations
        set accumulator to accumulator & "count=" & presentationCount & linefeed
        repeat with presentationIndex from 1 to presentationCount
            try
                set accumulator to accumulator & "name" & presentationIndex & "=" & (name of presentation presentationIndex) & linefeed
            end try
            try
                set accumulator to accumulator & "path" & presentationIndex & "=" & (full name of presentation presentationIndex) & linefeed
            end try
        end repeat
        try
            set accumulator to accumulator & "active=" & (name of active presentation) & linefeed
        end try
        return accumulator
    end tell
    """

    public static func activePresentationName(timeout: TimeInterval = 5) -> String? {
        let script = "tell application \"Microsoft PowerPoint\" to return name of active presentation"
        return try? runScript(script, timeout: timeout) ?? nil
    }

    public static func usedFontCount(timeout: TimeInterval = 5) -> Int? {
        let script = "tell application \"Microsoft PowerPoint\" to return (count of fonts of active presentation) as string"
        guard let raw = try? runScript(script, timeout: timeout) ?? nil else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The fonts PowerPoint itself offers — read out of the Replace Fonts dialog's
    /// "With:" list, which is literally "every font PowerPoint can apply" (581 items
    /// on the test machine, fully enumerable, not lazily paged).
    ///
    /// Costs one dialog open/close, so callers should cache it.
    public static func applicableFonts() throws -> [String] {
        let app = try requirePowerPoint(activate: true)
        let dialog = try openDialog(app)
        defer { closeDialog(app, dialog) }
        guard let popup = control(in: dialog, description: withPopupDesc) else {
            throw Failure.popupNotFound("With:")
        }
        return try menuTitles(of: popup).filter { !$0.isEmpty }
    }

    /// The fonts this deck currently uses, from the dialog's "Replace:" list.
    public static func usedFonts() throws -> [String] {
        let app = try requirePowerPoint(activate: true)
        let dialog = try openDialog(app)
        defer { closeDialog(app, dialog) }
        guard let popup = control(in: dialog, description: replacePopupDesc) else {
            throw Failure.popupNotFound("Replace:")
        }
        return try menuTitles(of: popup).filter { !$0.isEmpty }
    }

    // MARK: - The run

    /// Replace every font in `presentation` with `target`.
    ///
    /// Blocking; **must not** run on the main thread (it polls with `Thread.sleep`,
    /// and the app is a MenuBarExtra whose icon freezes if the main actor blocks).
    @discardableResult
    public static func run(
        target: String,
        presentation: Presentation,
        setThemeFonts: Bool,
        cancel: CancellationToken,
        progress: @escaping (Progress) -> Void
    ) throws -> Report {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let started = Date()
        let app = try requirePowerPoint(activate: true)

        progress(Progress(phase: .preparing, completed: 0, total: 0,
                          message: "Bringing \(presentation.name) to the front…"))
        try bringToFront(presentation)
        try checkCancel(cancel, 0)

        let before = usedFontCount()

        progress(Progress(phase: .openingDialog, completed: 0, total: 0,
                          message: "Opening PowerPoint's Replace Fonts…"))
        var refs = try ensureDialog(app)
        var closed = false
        defer { if !closed { if let live = findDialog(app) { closeDialog(app, live) } } }

        progress(Progress(phase: .readingFonts, completed: 0, total: 0,
                          message: "Reading the fonts this deck uses…"))
        // Read the SHORT "Replace:" list only.
        //
        // Enumerating the 581-entry "With:" list here used to come first, and that
        // long read let the menu close on its own — the following Escape then hit
        // the dialog (Escape == Cancel), so the used-font read came back empty and
        // the run reported "nothing to replace" while changing nothing. The target
        // needs no enumeration: type-select proves it exists, because the value is
        // read back and must match exactly.
        let used = try menuTitles(of: refs.replacePopup).filter { !$0.isEmpty }
        guard !used.isEmpty else {
            // Empty means the dialog went away or PowerPoint didn't answer — NOT
            // "this deck has no fonts". Never report that as success.
            throw Failure.dialogNotFound
        }
        let workList = used.filter { $0 != target }
        var replaced: [String] = []
        var failed: [String] = []

        for (index, font) in workList.enumerated() {
            try checkCancel(cancel, replaced.count)
            progress(Progress(phase: .replacing(font: font),
                              completed: index, total: workList.count,
                              message: "Replacing \(font) → \(target)…"))

            // Re-acquire every iteration: the previous step's Escape may have
            // dismissed the dialog, and a stale element press is a silent no-op.
            do { refs = try ensureDialog(app) } catch {
                failed.append(font)
                continue
            }

            do {
                try select(font, in: refs.replacePopup, popupName: "Replace:", byTyping: false)
                try select(target, in: refs.withPopup, popupName: "With:", byTyping: true)
            } catch {
                NSLog("[Ribbind] deck font: selecting %@ -> %@ failed: %@", font, target, String(describing: error))
                failed.append(font)
                continue
            }

            // Re-read BOTH fields immediately before committing. The two popups
            // start on the same font when the dialog opens, and a selection that
            // silently didn't stick would make this press replace a font with
            // itself — looking like success while the real font survives.
            let fromNow = AXProbe.value(refs.replacePopup)
            let toNow = AXProbe.value(refs.withPopup)
            guard fromNow == font, toNow == target else {
                NSLog("[Ribbind] deck font: aborting press, fields read Replace=%@ With=%@ (wanted %@ -> %@)",
                      fromNow, toNow, font, target)
                failed.append(font)
                continue
            }
            _ = AXProbe.perform(refs.replaceButton)

            // Completion signal: the font leaves the "Replace:" list.
            let gone = AXProbe.poll(timeout: 30.0, interval: 0.5) { () -> Bool? in
                guard let live = findDialog(app),
                      let popup = control(in: live, description: replacePopupDesc),
                      let titles = try? menuTitles(of: popup) else { return nil }
                return titles.contains(font) ? nil : true
            } ?? false

            if gone { replaced.append(font) } else { failed.append(font) }
        }

        // Proof, read from PowerPoint itself: whatever the "Replace:" list still
        // holds is still in use.
        if let live = findDialog(app), let popup = control(in: live, description: replacePopupDesc) {
            let leftover = ((try? menuTitles(of: popup)) ?? []).filter { !$0.isEmpty && $0 != target }
            for font in leftover where !failed.contains(font) { failed.append(font) }
        }

        progress(Progress(phase: .closingDialog, completed: replaced.count,
                          total: workList.count, message: "Closing the dialog…"))
        let dialogClosed = findDialog(app).map { closeDialog(app, $0) } ?? true
        closed = true
        if !dialogClosed {
            // Not fatal — the fonts are already applied — but say so rather than
            // pretending the screen is clean.
            failed.append("(Replace Font dialog stayed open — close it manually)")
        }

        var themeSlots: [String] = []
        var themeFailures: [String] = []
        if setThemeFonts {
            progress(Progress(phase: .settingThemeFonts, completed: replaced.count,
                              total: workList.count, message: "Setting the theme's heading and body fonts…"))
            let outcome = applyThemeFonts(target: target)
            themeSlots = outcome.ok
            themeFailures = outcome.failed
        }

        let after = usedFontCount()
        progress(Progress(phase: .done, completed: replaced.count, total: workList.count,
                          message: "Finished."))
        return Report(target: target, replaced: replaced, failed: failed,
                      themeSlots: themeSlots, themeFailures: themeFailures,
                      usedFontsBefore: before, usedFontsAfter: after,
                      duration: Date().timeIntervalSince(started))
    }

    // MARK: - Silent apply (no PowerPoint window)

    /// Apply `target` to every reachable text run **without opening any PowerPoint
    /// window**, by writing `font name` directly through AppleScript.
    ///
    /// This is what the Settings panel uses. PowerPoint's own
    /// `Format ▸ Replace Fonts…` reaches more (it is the only thing that gets inside
    /// grouped shapes) but it is a real PowerPoint window that pops up on screen,
    /// which is not acceptable for a one-click action.
    ///
    /// Coverage here: slide shapes, placeholders, text boxes, table cells, notes
    /// pages, the slide master and its custom layouts.
    /// **Not covered: text inside grouped shapes.** PowerPoint's AppleScript cannot
    /// address a group's children at all — indexing fails -1700/-1728,
    /// `group items` fails -1708, and a bulk `every shape` set fails -10006 (all
    /// verified). Groups are counted and reported rather than silently skipped.
    ///
    /// Index-addressed throughout: `repeat with shp in shapes of …` hangs on real
    /// decks, while `shape j of slide i` reads ~880 shapes in 16 s.
    static func silentApplyScript(target: String) throws -> String {
        let literal = try AppleScriptRunner.literal(target)
        return """
        tell application "Microsoft PowerPoint"
            set targetFontName to \(literal)
            set changedCount to 0
            set groupCount to 0
            set groupChildCount to 0
            set failureCount to 0
            set thePresentation to active presentation

            repeat with slideIndex from 1 to (count of slides of thePresentation)
                set theSlide to slide slideIndex of thePresentation
                repeat with shapeIndex from 1 to (count of shapes of theSlide)
                    set theShape to shape shapeIndex of theSlide
                    set shapeKind to ""
                    try
                        set shapeKind to (shape type of theShape) as string
                    end try
                    if shapeKind contains "group" then
                        set groupCount to groupCount + 1
                        try
                            set groupChildCount to groupChildCount + (count of shapes of theShape)
                        end try
                    else
                        try
                            if (has table of theShape) then
                                set theTable to table object of theShape
                                repeat with rowIndex from 1 to (count of rows of theTable)
                                    repeat with columnIndex from 1 to (count of columns of theTable)
                                        try
                                            set cellShape to shape of cell columnIndex of row rowIndex of theTable
                                            set font name of font of text range of text frame of cellShape to targetFontName
                                            set changedCount to changedCount + 1
                                        on error
                                            set failureCount to failureCount + 1
                                        end try
                                    end repeat
                                end repeat
                            else if (has text frame of theShape) then
                                set font name of font of text range of text frame of theShape to targetFontName
                                set changedCount to changedCount + 1
                            end if
                        on error
                            set failureCount to failureCount + 1
                        end try
                    end if
                end repeat

                try
                    set notesPage to notes page of theSlide
                    repeat with noteIndex from 1 to (count of shapes of notesPage)
                        try
                            set font name of font of text range of text frame of shape noteIndex of notesPage to targetFontName
                            set changedCount to changedCount + 1
                        end try
                    end repeat
                end try
            end repeat

            try
                set theMaster to slide master of thePresentation
                repeat with masterIndex from 1 to (count of shapes of theMaster)
                    try
                        set font name of font of text range of text frame of shape masterIndex of theMaster to targetFontName
                        set changedCount to changedCount + 1
                    end try
                end repeat
                repeat with layoutIndex from 1 to (count of custom layouts of theMaster)
                    set theLayout to custom layout layoutIndex of theMaster
                    repeat with layoutShapeIndex from 1 to (count of shapes of theLayout)
                        try
                            set font name of font of text range of text frame of shape layoutShapeIndex of theLayout to targetFontName
                            set changedCount to changedCount + 1
                        end try
                    end repeat
                end repeat
            end try

            return "changed=" & changedCount & linefeed & "groups=" & groupCount & linefeed & "groupChildren=" & groupChildCount & linefeed & "failures=" & failureCount & linefeed
        end tell
        """
    }

    /// Run the silent apply. No windows, no dialog, no focus stealing.
    public static func applySilently(
        target: String,
        presentation: Presentation,
        setThemeFonts: Bool,
        progress: @escaping (Progress) -> Void
    ) throws -> Report {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let started = Date()
        _ = try requirePowerPoint()   // deliberately does NOT activate PowerPoint

        progress(Progress(phase: .preparing, completed: 0, total: 0,
                          message: "Checking \(presentation.name)…"))
        guard activePresentationName() == presentation.name else {
            throw Failure.wrongPresentationFront(expected: presentation.name,
                                                 actual: activePresentationName() ?? "nothing")
        }
        let before = usedFontCount()

        progress(Progress(phase: .replacing(font: target), completed: 0, total: 1,
                          message: "Applying \(target) to every slide…"))
        let script = try silentApplyScript(target: target)
        // Big decks take a while; this is one Apple Event per text run.
        guard let raw = try runScript(script, timeout: 600) else { throw Failure.dialogNotFound }
        let fields = parseKV(raw)
        let changed = Int(fields["changed"] ?? "0") ?? 0
        let groups = Int(fields["groups"] ?? "0") ?? 0
        let groupChildren = Int(fields["groupChildren"] ?? "0") ?? 0

        var failed: [String] = []
        if groups > 0 {
            failed.append("\(groups) grouped shape(s) containing \(groupChildren) item(s) — PowerPoint's scripting can't reach inside groups")
        }

        var themeSlots: [String] = []
        var themeFailures: [String] = []
        if setThemeFonts {
            progress(Progress(phase: .settingThemeFonts, completed: 1, total: 1,
                              message: "Setting the theme's heading and body fonts…"))
            let outcome = applyThemeFonts(target: target)
            themeSlots = outcome.ok
            themeFailures = outcome.failed
        }

        let after = usedFontCount()
        progress(Progress(phase: .done, completed: 1, total: 1, message: "Finished."))
        return Report(target: target,
                      replaced: changed > 0 ? ["\(changed) text run(s)"] : [],
                      failed: failed,
                      themeSlots: themeSlots, themeFailures: themeFailures,
                      usedFontsBefore: before, usedFontsAfter: after,
                      duration: Date().timeIntervalSince(started))
    }

    // MARK: - Exhaustive apply (file rewrite, still no window)

    /// Apply `target` to **everything**, including text inside grouped shapes, by
    /// closing the deck and rewriting the `.pptx` itself, then reopening it.
    ///
    /// Opens no PowerPoint window. This is the only path that satisfies "no
    /// exceptions": PowerPoint's scripting cannot reach a group's children, and its
    /// own Replace Fonts dialog can only do so on screen.
    ///
    /// Trade-off the caller must surface: the document is saved, closed, rewritten
    /// and reopened, so the undo stack is gone. A timestamped backup is written next
    /// to the original first.
    public static func applyByRewritingFile(
        target: String,
        presentation: Presentation,
        progress: @escaping (Progress) -> Void
    ) throws -> Report {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let started = Date()
        _ = try requirePowerPoint()   // no activation: this path shows nothing
        guard let path = presentation.path, presentation.isSaved else {
            throw Failure.wrongPresentationFront(expected: presentation.name,
                                                 actual: "an unsaved document — save it first")
        }
        let before = usedFontCount()

        progress(Progress(phase: .preparing, completed: 0, total: 3,
                          message: "Saving and closing \(presentation.name)…"))
        let literal = try AppleScriptRunner.literal(presentation.name)
        _ = try runScript("""
        tell application "Microsoft PowerPoint"
            set theDoc to presentation \(literal)
            try
                save theDoc
            end try
            close theDoc
        end tell
        """, timeout: 180)

        // PowerPoint releases the file lazily; wait until it really is closed before
        // touching the bytes, or the rewrite races its own save.
        _ = AXProbe.poll(timeout: 60, interval: 0.4) { () -> Bool? in
            let names = (try? listOpenPresentations(timeout: 4))?.map(\.name) ?? []
            return names.contains(presentation.name) ? nil : true
        }

        progress(Progress(phase: .replacing(font: target), completed: 1, total: 3,
                          message: "Rewriting every font reference in the file…"))
        let summary = try PptxFontRewriter.rewriteFile(at: path, to: target)

        progress(Progress(phase: .closingDialog, completed: 2, total: 3,
                          message: "Reopening \(presentation.name)…"))
        let pathLiteral = try AppleScriptRunner.literal(path)
        _ = try runScript("tell application \"Microsoft PowerPoint\" to open \(pathLiteral)", timeout: 180)

        let after = usedFontCount()
        progress(Progress(phase: .done, completed: 3, total: 3, message: "Finished."))
        var replaced = summary.replacedFonts
        if replaced.isEmpty && summary.rewrittenAttributes > 0 {
            replaced = ["\(summary.rewrittenAttributes) font reference(s)"]
        }
        return Report(target: target,
                      replaced: replaced,
                      failed: [],
                      themeSlots: summary.changedParts.contains { $0.hasPrefix("ppt/theme/") } ? ["theme"] : [],
                      themeFailures: [],
                      usedFontsBefore: before, usedFontsAfter: after,
                      duration: Date().timeIntervalSince(started))
    }

    // MARK: - Theme fonts

    /// Set the theme's major/minor fonts so newly typed text matches too.
    ///
    /// A slot counts as success only when the value **reads back** as the target — a
    /// write that reports OK but doesn't stick is a failure, not a success. Empty
    /// east-asian / complex-script slots that refuse writes are informational: empty
    /// means "inherit", which is already correct.
    static func themeFontScript(target: String) throws -> String {
        let literal = try AppleScriptRunner.literal(target)
        return """
        tell application "Microsoft PowerPoint"
            set targetFontName to \(literal)
            set accumulator to ""
            try
                set theScheme to theme font scheme of theme of slide master of active presentation
                repeat with slotIndex from 1 to (count of major theme fonts of theScheme)
                    try
                        set name of major theme font slotIndex of theScheme to targetFontName
                    end try
                    try
                        set accumulator to accumulator & "major" & slotIndex & "=" & (name of major theme font slotIndex of theScheme) & linefeed
                    end try
                end repeat
                repeat with slotIndex from 1 to (count of minor theme fonts of theScheme)
                    try
                        set name of minor theme font slotIndex of theScheme to targetFontName
                    end try
                    try
                        set accumulator to accumulator & "minor" & slotIndex & "=" & (name of minor theme font slotIndex of theScheme) & linefeed
                    end try
                end repeat
            on error errorText number errorNumber
                set accumulator to accumulator & "fatal=" & errorNumber & " " & errorText & linefeed
            end try
            return accumulator
        end tell
        """
    }

    static func applyThemeFonts(target: String) -> (ok: [String], failed: [String]) {
        guard let script = try? themeFontScript(target: target) else { return ([], ["invalid font name"]) }
        guard let raw = try? runScript(script, timeout: 20) ?? nil else { return ([], ["theme script failed"]) }
        let fields = parseKV(raw)
        var ok: [String] = []
        var failed: [String] = []
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            guard key.hasPrefix("major") || key.hasPrefix("minor") else { continue }
            if value == target {
                ok.append(key)
            } else if !value.isEmpty {
                // Populated slot that kept a different font — a real failure.
                failed.append("\(key) stayed \"\(value)\"")
            }
            // Empty slot: inherits, nothing to report.
        }
        return (ok, failed)
    }

    // MARK: - Dialog plumbing

    private struct DialogRefs {
        let dialog: AXUIElement
        let replacePopup: AXUIElement
        let withPopup: AXUIElement
        let replaceButton: AXUIElement
    }

    /// Get a live dialog and freshly-resolved controls, reopening it if it went away.
    ///
    /// Necessary because closing a popup menu costs an Escape, and Escape with no
    /// menu open is Cancel — so the dialog can vanish underneath us between steps.
    /// Re-resolving is cheap (the dialog's children are flat) and turns a stale
    /// reference from a silent no-op into a non-event.
    private static func ensureDialog(_ app: AXUIElement) throws -> DialogRefs {
        let dialog = try openDialog(app)
        guard let replacePopup = control(in: dialog, description: replacePopupDesc),
              let withPopup = control(in: dialog, description: withPopupDesc),
              let replaceButton = button(in: dialog, titled: "Replace") else {
            throw Failure.dialogNotFound
        }
        return DialogRefs(dialog: dialog, replacePopup: replacePopup,
                          withPopup: withPopup, replaceButton: replaceButton)
    }



    /// - Parameter activate: bring PowerPoint forward first. **Only pass true for
    ///   the paths that actually drive its UI.** Read-only queries must not: the
    ///   Settings panel polls the presentation list every few seconds, and
    ///   activating there yanked PowerPoint in front of whatever the user was doing,
    ///   over and over, for as long as the panel was visible.
    private static func requirePowerPoint(activate: Bool = false) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityNotAuthorized }
        guard let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.microsoft.Powerpoint" }) else {
            throw Failure.powerPointNotRunning
        }
        // PowerPoint's dialog and popup menus only respond while it is the active
        // app, so the UI-driving paths do need this.
        if activate && !running.isActive {
            running.activate()
            Thread.sleep(forTimeInterval: 0.7)
        }
        let app = AXProbe.app(pid: running.processIdentifier)
        AXProbe.setMessagingTimeout(app, seconds: 8.0)
        return app
    }

    /// PowerPoint has no `activate`/`select` verb for a presentation, so raising the
    /// right deck goes through AX — and is then **verified**, because restyling the
    /// wrong document is the worst outcome this feature can produce.
    private static func bringToFront(_ presentation: Presentation) throws {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.microsoft.Powerpoint" }?
            .activate()
        Thread.sleep(forTimeInterval: 0.6)

        if activePresentationName() == presentation.name { return }

        let app = try requirePowerPoint()
        let base = (presentation.name as NSString).deletingPathExtension
        for window in AXProbe.allWindows(of: app)
        where AXProbe.subrole(window) == "AXStandardWindow" {
            let title = AXProbe.title(window)
            if title == presentation.name || title.hasPrefix(base) {
                _ = AXProbe.perform(window, "AXRaise")
                break
            }
        }
        let settled = AXProbe.poll(timeout: 3.0, interval: 0.2) { () -> Bool? in
            activePresentationName() == presentation.name ? true : nil
        } ?? false
        guard settled else {
            throw Failure.wrongPresentationFront(expected: presentation.name,
                                                 actual: activePresentationName() ?? "nothing")
        }
    }

    private static func openDialog(_ app: AXUIElement) throws -> AXUIElement {
        if let existing = findDialog(app) { return existing }
        guard let item = menuItem(app, titled: menuItemTitle) else { throw Failure.menuItemMissing }
        guard AXProbe.isEnabled(item) else { throw Failure.noPresentationOpen }
        _ = AXProbe.perform(item)
        guard let dialog = AXProbe.poll(timeout: 5.0, interval: 0.1, { findDialog(app) }) else {
            throw Failure.dialogNotFound
        }
        return dialog
    }

    private static func findDialog(_ app: AXUIElement) -> AXUIElement? {
        AXProbe.allWindows(of: app).first { AXProbe.title($0) == dialogTitle }
    }

    /// Close the Replace Font dialog and **confirm it is gone**.
    ///
    /// PowerPoint deliberately keeps this dialog open after each Replace so a person
    /// can do several in a row. For Ribbind the whole operation is one action, so
    /// leaving the window on screen afterwards is wrong — the user asked for it to
    /// close by itself.
    ///
    /// Verified rather than fire-and-forget: press Close, poll for the window to
    /// disappear, and fall back to Escape (which is Cancel for a dialog) if it is
    /// still there. Returns true when the dialog is really gone.
    @discardableResult
    private static func closeDialog(_ app: AXUIElement, _ dialog: AXUIElement) -> Bool {
        if let close = button(in: dialog, titled: "Close") {
            _ = AXProbe.perform(close)
            if AXProbe.poll(timeout: 2.0, interval: 0.1, { findDialog(app) == nil ? true : nil }) == true {
                return true
            }
        }
        AXProbe.pressEscape()
        if AXProbe.poll(timeout: 1.5, interval: 0.1, { findDialog(app) == nil ? true : nil }) == true {
            return true
        }
        NSLog("[Ribbind] deck font: Replace Font dialog would not close")
        return false
    }

    private static func menuItem(_ app: AXUIElement, titled: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        let menuBar = raw as! AXUIElement
        return AXProbe.find(in: menuBar, maxDepth: 6) { element, role in
            role == "AXMenuItem" && AXProbe.title(element) == titled
        }.first
    }

    /// The dialog's children are flat at depth 1, so this is a cheap lookup.
    private static func control(in dialog: AXUIElement, description: String) -> AXUIElement? {
        AXProbe.children(of: dialog).first { AXProbe.desc($0) == description }
    }

    private static func button(in dialog: AXUIElement, titled: String) -> AXUIElement? {
        AXProbe.children(of: dialog).first {
            AXProbe.role($0) == "AXButton" && AXProbe.title($0) == titled
        }
    }

    /// Open a popup and read its menu item titles.
    ///
    /// An already-open menu swallows the next press, and `AXCancel` does not close
    /// one, so every interaction starts with a real Escape.
    private static func menuTitles(of popup: AXUIElement) throws -> [String] {
        let items = openMenu(of: popup)
        let titles = items.map { AXProbe.title($0) }
        if !items.isEmpty { AXProbe.pressEscape() }   // a menu IS open — safe to escape
        return titles
    }

    /// Open a popup's menu and return its items, leaving the menu OPEN.
    ///
    /// Two hard-won details:
    ///
    /// * Tries `AXPress` then `AXShowMenu`. PowerPoint's two popups don't agree on
    ///   which action opens them, and a wrong guess reads as "the list is empty"
    ///   rather than as an error.
    /// * **Never** presses Escape first. Escape with no menu open is Cancel, which
    ///   dismisses the Replace Font dialog itself — that bug made every font read
    ///   come back empty. Escape is only ever used to close a menu we know is open.
    private static func openMenu(of popup: AXUIElement) -> [AXUIElement] {
        for action in [kAXPressAction as String, "AXShowMenu"] {
            guard AXProbe.perform(popup, action) == .success else { continue }
            if let items = AXProbe.poll(timeout: 3.0, interval: 0.1, { () -> [AXUIElement]? in
                guard let menu = AXProbe.children(of: popup).first(where: { AXProbe.role($0) == "AXMenu" }) else { return nil }
                let children = AXProbe.children(of: menu)
                return children.isEmpty ? nil : children
            }) {
                return items
            }
        }
        return []
    }

    /// Choose `font` in a popup and confirm it stuck.
    ///
    /// `byTyping` matters. In the short "Replace:" list, pressing the `AXMenuItem`
    /// works. In the 581-entry "With:" list it does **not**: pressing an off-screen
    /// item — via `AXPress` or `AXPick` — silently activates item 0 ("Font
    /// Collections") instead. Typing the name uses the menu's type-ahead, which is
    /// what a person does and the only thing that selects correctly.
    ///
    /// Either way the value is read back and must match exactly. A selection that
    /// silently didn't stick would make the next Replace press act on the wrong font.
    private static func select(_ font: String, in popup: AXUIElement, popupName: String, byTyping: Bool) throws {
        var lastSeen = "(never opened)"
        // Retry is safe because every attempt ends in a read-back: a wrong value is
        // detected, never committed.
        for attempt in 1...3 {
            // ALWAYS wait for the menu to actually contain items before touching it.
            // The previous version slept a flat 0.5 s after pressing and then typed.
            // PowerPoint's "With:" menu holds 581 entries and can take longer than
            // that to populate; typing into a menu that isn't up yet drops the
            // keystrokes and the following Return commits whatever is highlighted —
            // item 0, "Font Collections". That race is what made whole runs fail.
            let items = openMenu(of: popup)
            guard !items.isEmpty else {
                lastSeen = "(menu wouldn't open)"
                continue
            }

            if byTyping {
                // Menu type-ahead. Required for the long list: pressing an
                // off-screen AXMenuItem — via AXPress or AXPick — silently
                // activates item 0 instead of the target.
                AXProbe.type(font)
                Thread.sleep(forTimeInterval: 0.35)
                AXProbe.pressReturn()
            } else if let item = items.first(where: { AXProbe.title($0) == font }) {
                _ = AXProbe.perform(item)
            } else {
                AXProbe.pressEscape()
                throw Failure.fontNotSelectable(font: font, popup: popupName, got: "(not in list)")
            }

            Thread.sleep(forTimeInterval: 0.45)
            lastSeen = AXProbe.value(popup)
            if lastSeen == font { return }

            NSLog("[Ribbind] deck font: %@ attempt %d selected %@ instead of %@ — retrying",
                  popupName, attempt, lastSeen, font)
            // Leave no menu open before the next attempt.
            AXProbe.pressEscape()
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw Failure.fontNotSelectable(font: font, popup: popupName, got: lastSeen)
    }

    // MARK: - Validation hooks

    /// Compile-only accessors so the harness can gate the generated AppleScript
    /// without Office running and without triggering Automation prompts.
    public static func themeFontScriptForValidation(target: String) -> String {
        (try? themeFontScript(target: target)) ?? "-- unbuildable"
    }

    public static func listPresentationsScriptForValidation() -> String {
        listPresentationsScript
    }

    // MARK: - Helpers

    private static func checkCancel(_ token: CancellationToken, _ done: Int) throws {
        if token.isCancelled { throw Failure.cancelled(afterReplacements: done) }
    }

    private static func runScript(_ source: String, timeout: TimeInterval) throws -> String? {
        do {
            return try AppleScriptRunner.runBounded(source, timeout: timeout)
        } catch let failure as AppleScriptRunner.Failure {
            if case .executionFailed(let code, _) = failure, code == -1743 {
                throw Failure.automationDenied
            }
            throw failure
        }
    }

    /// Split on the FIRST `=` only — deck names and font names can contain one.
    public static func parseKV(_ blob: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            out[key] = value
        }
        return out
    }
}

import AppKit
import Foundation

/// Dispatches paste-with-format commands for Word and PowerPoint without
/// showing the Edit > Paste Special dialog or the Edit menu animation.
///
/// Routing per (app, pasteType):
/// - Word + any direct paste type → AppleScript `paste special ... data type X`
///   (instant, no dialog)
/// - Word + `default` / `matchFormatting` → menu-bar AX press of the
///   pre-built menu item (instant)
/// - PowerPoint + `default` / `matchFormatting` → menu-bar AX press
/// - PowerPoint + `unformatted` → NSPasteboard clipboard swap (extract plain
///   text, rewrite the clipboard, AS-paste, optionally restore originals on
///   a background queue ~300 ms later)
/// - PowerPoint + Word-only types (rtf / asPicture / asHtml) → typed
///   `Failure.unsupported` so the binding coordinator can surface a
///   notification; these aren't included in the PPT picker so end users
///   shouldn't hit this branch in practice.
public enum PasteDispatcher {
    public enum Failure: Error, CustomStringConvertible {
        case unsupported(pasteType: String, app: AppTarget)
        case appleScriptError(String)
        case menuItemNotFound(String)

        public var description: String {
            switch self {
            case .unsupported(let t, let a):
                return "Paste type '\(t)' is not supported for \(a.processName)."
            case .appleScriptError(let m):
                return "AppleScript paste failed: \(m)"
            case .menuItemNotFound(let n):
                return "Menu item '\(n)' not found in target app."
            }
        }
    }

    /// Apply the requested paste type in the target app. The caller is
    /// expected to have confirmed the target app is frontmost (the
    /// `HotkeyMonitor` gate already does this for hotkey dispatch).
    ///
    /// **Text-only gate**: if the clipboard does not contain readable plain
    /// text (e.g. only image / file / RTF binary types), the paste-format
    /// path is skipped and a plain `Paste` is invoked instead. Rationale:
    /// "Unformatted Text" / "Match Formatting" / Word's `paste special data
    /// type paste text` are all text transformations — applying them to an
    /// image clipboard either fails (Word AS errors, PPT swap writes an
    /// empty plain-text item that pastes nothing) or silently strips the
    /// image. End-user expectation is that ⌘V on an image clipboard pastes
    /// the image normally, regardless of the picker's text-paste setting.
    @MainActor
    public static func dispatch(pasteType: String, app: AppTarget) throws {
        // Bypass paste-format transformations when clipboard isn't text.
        // `default` already does a plain paste, so it's a no-op there.
        if pasteType != "default" && !clipboardHasText() {
            try pressMenu("Paste", inApp: app)
            return
        }

        switch (app, pasteType) {
        // ----- Word: direct AppleScript paste special -----
        case (.word, "unformatted"):
            try runWordPasteSpecial(dataType: "paste text")
        case (.word, "keepSourceFormat"):
            try runWordPasteSpecial(dataType: "paste rtf")
        case (.word, "asPicture"):
            try runWordPasteSpecial(dataType: "paste enhanced metafile")
        case (.word, "asHtml"):
            try runWordPasteSpecial(dataType: "paste html")

        // ----- Both: menu-bar AX press (instant, no menu animation) -----
        case (.word, "default"), (.powerpoint, "default"):
            try pressMenu("Paste", inApp: app)
        case (.word, "matchFormatting"), (.powerpoint, "matchFormatting"):
            try pressMenu("Paste and Match Formatting", inApp: app)

        // ----- PowerPoint: clipboard swap for unformatted -----
        case (.powerpoint, "unformatted"):
            try pasteUnformattedViaClipboardSwap()

        default:
            throw Failure.unsupported(pasteType: pasteType, app: app)
        }
    }

    /// True iff the system pasteboard currently holds at least one
    /// non-empty plain-text item. Used as the gate that decides whether to
    /// engage the paste-format transformations or fall back to a plain
    /// `Paste`. Cheap to call (no AS, no AX) — single NSPasteboard read.
    @MainActor
    private static func clipboardHasText() -> Bool {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty {
            return true
        }
        // Some apps put text on the pasteboard only under the RTF / HTML
        // types (no .string mirror). Treat those as text too — Word's
        // `paste rtf` and `paste html` paths consume them directly, and
        // PPT's clipboard swap will fall through to its own .string
        // extraction (which may be empty, but that's a separate concern).
        for type in [NSPasteboard.PasteboardType.rtf,
                     NSPasteboard.PasteboardType.html] {
            if pb.data(forType: type) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Word

    /// Build and run a Word paste-special AppleScript with the given data
    /// type token (e.g. `paste text`, `paste rtf`, `paste enhanced metafile`,
    /// `paste html`). Word's `paste special` command on `selection` writes
    /// directly into the document and returns immediately — no dialog, no
    /// Ribbon animation.
    @MainActor
    private static func runWordPasteSpecial(dataType: String) throws {
        // Defense-in-depth: only allow the small set of vetted data-type
        // tokens. Catalog dispatch supplies these constants — but if a future
        // change ever pipes user input here, this prevents AS injection.
        let allowed: Set<String> = [
            "paste text", "paste rtf", "paste enhanced metafile",
            "paste html", "paste metafile picture", "paste bitmap",
            "paste device independent bitmap", "paste hyperlink",
        ]
        guard allowed.contains(dataType) else {
            throw Failure.unsupported(pasteType: dataType, app: .word)
        }
        let source = """
        tell application "Microsoft Word"
            paste special selection data type \(dataType)
        end tell
        """
        do {
            _ = try AppleScriptRunner.run(source)
        } catch {
            throw Failure.appleScriptError(String(describing: error))
        }
    }

    // MARK: - Menu bar AX press

    @MainActor
    private static func pressMenu(_ title: String, inApp app: AppTarget) throws {
        do {
            try RibbonButtonClicker.pressMenuItem(titled: title, inApp: app)
        } catch {
            throw Failure.menuItemNotFound("\(title) (\(error))")
        }
    }

    // MARK: - PowerPoint clipboard swap

    /// Strip the clipboard down to plain text, AS-paste, and (in the
    /// background) restore the original clipboard ~300 ms later so a
    /// subsequent paste in another app gets the original formatting back.
    /// This is how TextExpander-style "paste plain" features work — the
    /// only path that gives PPT instant unformatted paste without a dialog.
    @MainActor
    private static func pasteUnformattedViaClipboardSwap() throws {
        let pb = NSPasteboard.general
        let plain = pb.string(forType: .string) ?? ""

        // Snapshot every type → data so we can rebuild the clipboard later.
        var saved: [(String, Data)] = []
        if let items = pb.pasteboardItems {
            for item in items {
                for type in item.types {
                    if let data = item.data(forType: type) {
                        saved.append((type.rawValue, data))
                    }
                }
            }
        }

        // Rewrite clipboard with plain text only, then ask PPT to paste.
        pb.clearContents()
        pb.setString(plain, forType: .string)

        let source = """
        tell application "Microsoft PowerPoint"
            paste object view of document window 1
        end tell
        """
        var pasteError: Error?
        do {
            _ = try AppleScriptRunner.run(source)
        } catch {
            pasteError = error
        }

        // Schedule restore on a background queue. Even if the paste failed
        // we still want to put the user's clipboard back. 300 ms gives
        // PowerPoint time to ingest the plain-text clipboard.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                let item = NSPasteboardItem()
                for (type, data) in saved {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                pb.writeObjects([item])
            }
        }

        if let pasteError {
            throw Failure.appleScriptError(String(describing: pasteError))
        }
    }
}

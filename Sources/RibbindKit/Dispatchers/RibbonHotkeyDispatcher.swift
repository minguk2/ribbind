import Foundation
import KeyboardShortcuts

/// Registers global hotkeys that fire one of the Ribbon-only dispatch paths (ExecuteMso
/// via AppleScript, or AXPress on a Ribbon control). Used for commands that have no
/// menu item or keymap representation reachable via native Word/PowerPoint bindings.
public enum RibbonHotkeyDispatcher {
    public static func unregister(commandId: String) {
        let name = KeyboardShortcuts.Name(commandId)
        KeyboardShortcuts.disable(name)
    }

    /// Runs the ExecuteMso AppleScript and returns whether the AS actually
    /// executed cleanly. Word 16.x has recently removed the `do Visual Basic`
    /// verb so this path is often a no-op in current builds; callers must
    /// respect the return value and try the next recipe instead of pretending
    /// success. Always returning `true` here is what caused the v0.5.0 Format
    /// Painter regression: axClick failed (TCC not granted), the wordKeyBinding
    /// fallback silently errored, and the dispatcher reported "dispatched".
    @discardableResult
    public static func fireExecuteMso(idMso: String, targetApp: AppTarget) -> Bool {
        let source = buildExecuteMsoScript(idMso: idMso, targetApp: targetApp)
        guard !source.isEmpty else { return false }
        do {
            try AppleScriptRunner.run(source)
            return true
        } catch {
            NSLog("ExecuteMso failed for \(idMso): \(error)")
            return false
        }
    }

    /// Run a bundled-catalog AppleScript source verbatim. The catalog supplies the
    /// full script (including the `tell application "..."` block). Returns true on
    /// success. The script is part of the signed app binary — user input never flows
    /// into this path, so no escaping is applied here.
    ///
    /// Before running the script, pre-probes the Automation TCC for the target app
    /// (inferred from `tell application "..."`). If -1743 is returned, logs a clear
    /// message and returns false — this surfaces the permission issue to callers
    /// (like the e2e harness) instead of letting the inner `try/end try` in the
    /// recipe silently swallow the TCC denial.
    @discardableResult
    public static func fireAppleScript(source: String, commandId: String) -> Bool {
        // Detect and probe the target app from `tell application "..."`.
        let targetApp: String? = {
            guard let r = source.range(of: #"tell application "([^"]+)""#, options: .regularExpression)
            else { return nil }
            let inside = source[r]
            guard let q1 = inside.firstIndex(of: "\""),
                  let q2 = inside[inside.index(after: q1)...].firstIndex(of: "\"") else { return nil }
            return String(inside[inside.index(after: q1)..<q2])
        }()
        if let app = targetApp {
            // `get name` is a cheap local-resolve and doesn't reliably round-trip
            // to the target app. `count of documents` / `count of presentations`
            // forces a real AE send — -1743 surfaces immediately on TCC denial.
            let countedClass = app.contains("PowerPoint") ? "presentations" : "documents"
            let probe = "tell application \"\(app)\" to count \(countedClass)"
            do {
                _ = try AppleScriptRunner.run(probe)
            } catch {
                // Probe failed. Most common cause is TCC denial (-1743). Log it
                // distinctively so dispatch callers can detect the state even
                // though the real recipe's `try/end try` would silently swallow
                // the error. Return false so the coordinator tries next recipe
                // or reports "no dispatch recipe succeeded".
                NSLog("[Ribbind] appleScript fire failed for %@: Not authorized to send Apple events to %@ — probe error: %@ (grant Automation permission in System Settings → Privacy & Security → Automation → Ribbind)",
                      commandId, app, String(describing: error))
                return false
            }
        }
        do {
            try AppleScriptRunner.run(source)
            return true
        } catch {
            NSLog("[Ribbind] appleScript fire failed for %@: %@",
                  commandId, String(describing: error))
            return false
        }
    }

    /// AppleScript source that triggers `CommandBars.ExecuteMso "<idMso>"` in the target
    /// app. `idMso` is validated against a conservative allow-list before interpolation.
    public static func buildExecuteMsoScript(idMso: String, targetApp: AppTarget) -> String {
        // Defense-in-depth: idMso values from Microsoft's public list are alphanumeric
        // only. Reject anything else so a malicious catalog entry cannot inject script.
        let safe = idMso.filter { $0.isLetter || $0.isNumber }
        guard safe == idMso, !safe.isEmpty else { return "" }
        switch targetApp {
        case .word:
            return """
            tell application "Microsoft Word"
                activate
                do Visual Basic "Application.CommandBars.ExecuteMso \\"\(safe)\\""
            end tell
            """
        case .powerpoint:
            // NOTE: PowerPoint's AS dictionary has NO `do Visual Basic` verb, so the Word
            // path doesn't translate. `run VB macro` only invokes pre-registered macros —
            // it doesn't evaluate arbitrary VBA. Until we ship a .ppam add-in with wrapper
            // macros like `Sub Mso_ShapeHeart() CommandBars.ExecuteMso "ShapeHeart" End Sub`,
            // this script compiles cleanly but fires error -18 (macro not found). It's a
            // no-op in the meantime; PowerPoint commands that need this path should also
            // carry an axClick recipe as the real primary.
            return """
            tell application "Microsoft PowerPoint"
                activate
                run VB macro macro name "Mso_\(safe)"
            end tell
            """
        case .chrome:
            // Chrome has no ExecuteMso (no Office Ribbon). Return empty so the caller
            // treats this dispatch path as a no-op for Chrome commands.
            return ""
        }
    }
}

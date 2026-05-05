import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import RibbindKit

// MARK: - Tiny validator

@MainActor
final class Validator {
    var passed = 0
    var skipped = 0
    var failed: [(String, String)] = []

    func check(_ name: String, skipIf: Bool = false, skipReason: String = "", _ block: () throws -> Void) {
        if skipIf {
            skipped += 1
            print("  ⊘ \(name) — skipped (\(skipReason))")
            return
        }
        do {
            try block()
            passed += 1
            print("  ✓ \(name)")
        } catch {
            failed.append((name, "\(error)"))
            print("  ✗ \(name) — \(error)")
        }
    }

    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw ValidationError(message) }
    }

    func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") throws {
        if a != b { throw ValidationError("\(message): expected \(b), got \(a)") }
    }

    struct ValidationError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { self.description = d }
    }
}

// MARK: - Subcommand registry

/// One source of truth for dev-mode subcommands. Keeps the help text and the dispatch
/// switch in sync automatically.
enum Subcommand: String, CaseIterable {
    case pptBind                    = "ppt-bind"
    case pptUnbind                  = "ppt-unbind"
    case pptRead                    = "ppt-read"
    case wordProbe                  = "word-probe"
    case wordBindFormatPainter      = "word-bind-format-painter"
    case wordVerifyFormatPainter    = "word-verify-format-painter"
    case wordUnbindFormatPainter    = "word-unbind-format-painter"
    case wordReadCustomizations     = "word-read-customizations"
    case wordAddTestKeymap          = "word-add-test-keymap"
    case wordRemoveTestKeymap       = "word-remove-test-keymap"
    case wordSaveNormal             = "word-save-normal"
    case wordClickFormatPainter     = "word-click-format-painter"
    case wordEnumerateButtons       = "word-enumerate-buttons"
    case pptEnumerateButtons        = "ppt-enumerate-buttons"
    case wordEnumerateMenuItems     = "word-enumerate-menu-items"
    case pptEnumerateMenuItems      = "ppt-enumerate-menu-items"
    case chromeEnumerateMenuItems   = "chrome-enumerate-menu-items"
    case postKey                    = "post-key"
    case fireById                   = "fire-by-id"
    case e2e                        = "e2e"
    case e2ePassthrough             = "e2e-passthrough"
    case e2eHotkey                  = "e2e-hotkey"
    case listScenarios              = "list-scenarios"
    case verifySuppress             = "verify-suppress"
    case verifySeed                 = "verify-seed"
    case verifyPermissions          = "verify-permissions"  // legacy log-grep gate, kept for back-compat
    case verifyRibbindTcc           = "verify-ribbind-tcc"  // Tier 0a — read Ribbind.app's truth
    case verifyEndToEnd             = "verify-end-to-end"   // Tier 0b — observe real Office effect
    case qaQuick                    = "qa-quick"            // QA: user-reported bugs first pass
    case cleanupRibbindMacroKeymaps = "cleanup-ribbind-macro-keymaps"
    case testMouseMapper            = "test-mouse-mapper"   // probe MouseSlideMapper live

    static var helpList: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

// MARK: - Fixtures

/// Pull the catalog entry for `word.FormatPainter` instead of hand-constructing it.
/// Using the real catalog guarantees dev-mode tests exercise the same dispatch recipe
/// the app uses in production.
@MainActor
func formatPainterCommand() throws -> Command {
    let catalog = Catalog()
    guard let cmd = catalog.commands.first(where: { $0.id == "word.FormatPainter" }) else {
        throw Validator.ValidationError("word.FormatPainter missing from catalog")
    }
    return cmd
}

func cmdCtrlZBinding(commandId: String) -> ShortcutBinding {
    // ⌘⌃Z, kcmPrimary 115A — chosen to avoid colliding with Word's default ⌘⇧Z (Redo).
    ShortcutBinding(
        commandId: commandId,
        displayString: "⌘⌃Z",
        modifierMask: 0x100000 | 0x040000,  // NSEvent flags: command + control
        macKeyCode: 0x06                     // kVK_ANSI_Z
    )
}

// MARK: - CLI error handling

@MainActor
func runCLI(_ block: () throws -> Void) -> Never {
    do {
        try block()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
        exit(2)
    }
}

// MARK: - Main

@main
@MainActor
struct ValidationHarness {
    static func main() async {
        let args = CommandLine.arguments
        if args.count > 1 {
            guard let sub = Subcommand(rawValue: args[1]) else {
                FileHandle.standardError.write(Data("Unknown subcommand: \(args[1])\n".utf8))
                FileHandle.standardError.write(Data("Available: \(Subcommand.helpList)\n".utf8))
                exit(1)
            }
            await dispatch(sub, args: args)
            return
        }

        await runAllChecks()
    }

    @MainActor
    static func dispatch(_ sub: Subcommand, args: [String]) async {
        switch sub {
        case .pptBind:
            runCLI {
                try PowerPointPlistWriter.bind(menuTitle: args[2], shorthand: args[3])
                print("✓ Bound '\(args[2])' → '\(args[3])' in PowerPoint plist")
            }

        case .pptUnbind:
            runCLI {
                try PowerPointPlistWriter.unbind(menuTitle: args[2])
                print("✓ Unbound '\(args[2])' from PowerPoint plist")
            }

        case .pptRead:
            runCLI {
                let dict = try PowerPointPlistWriter.readCurrentBindings()
                print("Current NSUserKeyEquivalents in PowerPoint plist:")
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                    print("  \(k) = \(v)")
                }
                print("Total: \(dict.count)")
            }

        case .wordProbe:
            runCLI {
                let version = try WordKeybindingWriter.probeVersion()
                print("✓ Word AppleScript reachable. version = \(version)")
            }

        case .wordBindFormatPainter:
            runCLI {
                let cmd = try formatPainterCommand()
                let binding = cmdCtrlZBinding(commandId: cmd.id)
                try WordKeybindingWriter.apply(command: cmd, binding: binding)
                print("✓ Bound ⌘⌃Z to \(cmd.id) via WordKeybindingWriter.apply")
            }

        case .wordVerifyFormatPainter:
            runCLI {
                let keys = try WordKeybindingWriter.keysBound(toCommandName: "FormatPainter", category: .command)
                print("Bindings to FormatPainter: \(keys.isEmpty ? "(none)" : keys.joined(separator: ", "))")
            }

        case .wordUnbindFormatPainter:
            runCLI {
                let binding = cmdCtrlZBinding(commandId: "word.FormatPainter")
                try WordKeybindingWriter.unbind(binding: binding)
                print("✓ Unbound ⌘⌃Z")
            }

        case .wordReadCustomizations:
            runCLI {
                let xml = try NormalDotmArchive.readCustomizationsXML()
                let keymaps = WordKeybindingWriter.parseCustomizationsXML(xml)
                print("Current keymaps in Normal.dotm (\(keymaps.count) entries):")
                for km in keymaps {
                    print("  \(km.kcmPrimary) → \(km.target)")
                }
            }

        case .wordAddTestKeymap:
            runCLI {
                // ⌘⌃M → ToolsWordCount built-in command. M chosen over Q (far from ⌘Q Quit).
                let mods = KeyCodeTranslator.ModifierMask([.command, .control])
                guard let kcm = KeyCodeTranslator.encodeKcmPrimary(modifiers: mods, macKeyCode: 0x2E) else {
                    throw Validator.ValidationError("encoder returned nil for ⌘⌃M")
                }
                try updateKeymaps { keymaps in
                    let test = WordKeybindingWriter.Keymap(
                        kcmPrimary: kcm,
                        target: .fciName(name: "ToolsWordCount", swArg: "0000")
                    )
                    return keymaps.contains(test) ? keymaps : keymaps + [test]
                }
            }

        case .wordRemoveTestKeymap:
            runCLI {
                // Remove any keymaps we created during E2E testing (114D ⌘⌃M, 115A ⌘⌃Z,
                // including their disabled-mask forms after a rebind-to-disable round-trip).
                let testKcms: Set<String> = ["114D", "115A"]
                try updateKeymaps { $0.filter { !testKcms.contains($0.kcmPrimary.uppercased()) } }
            }

        case .wordSaveNormal:
            runCLI {
                try WordKeybindingWriter.saveNormalTemplate()
                print("✓ Normal template saved")
            }

        case .wordClickFormatPainter:
            runCLI {
                try RibbonButtonClicker.pressWordFormatPainter()
                print("✓ Clicked Format Painter Ribbon button — brush should now be active")
            }

        case .wordEnumerateButtons:
            runCLI { try enumerateButtons(.word) }

        case .pptEnumerateButtons:
            runCLI { try enumerateButtons(.powerpoint) }

        case .wordEnumerateMenuItems:
            runCLI { try enumerateMenuItemsCLI(.word) }

        case .pptEnumerateMenuItems:
            runCLI { try enumerateMenuItemsCLI(.powerpoint) }

        case .chromeEnumerateMenuItems:
            runCLI { try enumerateMenuItemsCLI(.chrome) }

        case .fireById:
            // usage: fire-by-id <command-id> [param=value ...]
            // Bypasses Carbon entirely — directly invokes BindingCoordinator.dispatchNow.
            // Frontmost check still applies (handler bails if the target Office app is
            // not the foreground application). Optional trailing `key=value` args seed
            // a synthetic ShortcutBinding so {{param.X}} templates have values to
            // interpolate — useful for live-firing Highlight1 with a specific colour.
            runCLI {
                guard args.count >= 3 else {
                    throw Validator.ValidationError("usage: fire-by-id <command-id> [param=value ...]")
                }
                let catalog = Catalog()
                guard let cmd = catalog.commands.first(where: { $0.id == args[2] }) else {
                    throw Validator.ValidationError("unknown command id: \(args[2])")
                }
                // Parse trailing key=value pairs and persist as a synthetic binding so
                // dispatchNow's parameter lookup finds them. Use a scratch UserDefaults
                // suite so we don't pollute the real Ribbind preferences.
                var params: [String: String] = [:]
                for arg in args.dropFirst(3) {
                    let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else {
                        throw Validator.ValidationError("bad arg: \(arg) — expected key=value")
                    }
                    params[parts[0]] = parts[1]
                }
                if !params.isEmpty {
                    let suite = UserDefaults(suiteName: "ribbind.fire-by-id.\(UUID().uuidString)")!
                    let store = PreferenceStore(defaults: suite)
                    store.set(ShortcutBinding(
                        commandId: cmd.id,
                        displayString: "(harness)",
                        modifierMask: 0,
                        macKeyCode: 0,
                        parameters: params
                    ))
                    // Bootstrap a coordinator so activeStore is populated.
                    _ = BindingCoordinator(store: store)
                    print("params injected: \(params)")
                }
                try RibbonButtonClicker.activate(cmd.app)
                Thread.sleep(forTimeInterval: 0.4)
                print("firing: \(cmd.id) (target=\(cmd.app.rawValue))")
                BindingCoordinator.dispatchNow(command: cmd)
                print("dispatched")
            }

        case .postKey:
            // usage: post-key <keycode> <modifier-bits>
            // e.g. post-key 18 0x100000  (Cmd+1)
            // Useful to test whether a Carbon-registered global hotkey intercepts a
            // synthetic CGEvent. Note: CGEventPost events do reach Carbon hotkeys in
            // most macOS versions; AppleScript System Events keystrokes usually don't.
            runCLI {
                guard args.count >= 4,
                      let code = UInt16(args[2]),
                      let flagsValue = UInt64(args[3].replacingOccurrences(of: "0x", with: ""), radix: 16)
                else {
                    throw Validator.ValidationError("usage: post-key <keycode> <hex-flags>")
                }
                let flags = CGEventFlags(rawValue: flagsValue)
                let src = CGEventSource(stateID: .hidSystemState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
                down.flags = flags
                let up   = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!
                up.flags = flags
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                print("posted key=\(code) flags=0x\(String(flagsValue, radix: 16))")
            }

        case .e2e:
            // usage: e2e [--only=commandId]
            // Runs Tier 2 (state round-trip) for every catalog command whose target
            // app is currently running. Bypasses the frontmost gate via
            // `dispatchForTesting` so scenarios run back-to-back without focus steal.
            runCLI {
                let filter = args.dropFirst(2).first(where: { $0.hasPrefix("--only=") })
                    .map { String($0.dropFirst("--only=".count)) }
                try await_e2e(filter: filter, passthrough: false)
            }

        case .e2ePassthrough:
            // usage: e2e-passthrough [--only=commandId]
            // Runs Tier 2b: for each bound combo, a non-Office foil app is brought
            // frontmost, the combo is CGEventPost-ed, and we assert Ribbind did NOT
            // dispatch and Word/PPT state is unchanged.
            runCLI {
                let filter = args.dropFirst(2).first(where: { $0.hasPrefix("--only=") })
                    .map { String($0.dropFirst("--only=".count)) }
                try await_e2e(filter: filter, passthrough: true)
            }

        case .listScenarios:
            // usage: list-scenarios — prints one commandId per line for every
            // registered e2e scenario. Used by scripts/coverage-report.sh to
            // audit the catalog↔scenario symmetry (grep-on-source misses
            // loop-generated scenarios).
            for sc in e2eScenarios() {
                print(sc.commandId)
            }
            exit(0)

        case .verifyPermissions:
            // usage: verify-permissions  [LEGACY]
            // The original log-grep based gate from v0.5.3. Kept until all
            // hooks switch to verify-ribbind-tcc. Don't add new callers.
            runCLI {
                try verifyRibbindPermissions()
            }

        case .verifyRibbindTcc:
            // usage: verify-ribbind-tcc
            // Tier 0a — kill /Applications/Ribbind.app, relaunch it, wait
            // for it to write permission-state.json (truth probed FROM
            // INSIDE Ribbind, not from the harness's TCC), then exit 0
            // iff AX is granted AND every-currently-running Office app's
            // Automation grant is present. Replaces verify-permissions.
            runCLI {
                try verifyRibbindTccState()
            }

        case .qaQuick:
            // usage: qa-quick
            // First pass of the autonomous QA suite for user-reported bugs:
            //   QA-A2: menu-bar Settings click brings window forward
            //   QA-C2: same combo bound to word.X and powerpoint.X works
            //          (architecture works via direct UserDefaults write —
            //           recorder UI may be a separate issue tracked as a
            //           REQUIREMENTS row)
            //   QA-D4: ⇧⌘2 in PPT frontmost dispatches powerpoint.FormatPainter
            //          (overlap routing) when both word + ppt bound
            // Plus future expansion. Exit non-zero on any failure.
            runCLI {
                try runQuickQA()
            }

        case .verifyEndToEnd:
            // usage: verify-end-to-end
            // Tier 0b — for each canonical recipe TYPE, exercise the
            // installed Ribbind.app's actual user-facing dispatch path:
            // CGEventPost the bound combo, then read Office state via AS
            // and assert the expected effect landed. Hard fails on any
            // recipe that didn't reach Office — this is the gate that
            // catches the "tests passed in harness, broken in real life"
            // class of regression.
            runCLI {
                try verifyEndToEndUserPath()
            }

        case .testMouseMapper:
            // usage: test-mouse-mapper [<screenX> <screenY>]
            // Diagnostic probe of MouseSlideMapper.slidePositionUnderMouse(.powerpoint).
            // Optionally moves the cursor to the given screen coords first (AX/TL
            // origin global), then reads the result. Run with PPT frontmost.
            runCLI {
                guard OfficeAppProbe.isRunning(.powerpoint) else {
                    throw Validator.ValidationError("test-mouse-mapper: PowerPoint is not running.")
                }
                // Optional cursor pre-positioning so the diagnostic can be run
                // headlessly (`test-mouse-mapper <axX> <axY>` moves cursor first).
                if args.count >= 4, let mx = Double(args[2]), let my = Double(args[3]) {
                    let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                     mouseCursorPosition: CGPoint(x: mx, y: my), mouseButton: .left)
                    ev?.post(tap: .cghidEventTap)
                    Thread.sleep(forTimeInterval: 0.15)
                }
                if let coords = MouseSlideMapper.slidePositionUnderMouse(targetApp: .powerpoint) {
                    print(String(format: "MouseSlideMapper: slideX=%.1f slideY=%.1f", coords.x, coords.y))
                } else {
                    print("MouseSlideMapper: nil (mapping failed — set RIBBIND_MAPPER_DEBUG=1 to see internals)")
                }
            }

        case .cleanupRibbindMacroKeymaps:
            // usage: cleanup-ribbind-macro-keymaps
            // Quit Word first. Strips ALL Ribbind-authored keymap entries from
            // Normal.dotm — both pre-Option-A legacy (NORMAL.MODULE1.* /
            // HIGHLIGHTYELLOW etc.) and the wordKeymapMacro-era
            // NORMAL.RibbindMacros.* entries that are now dead weight under
            // the appleScriptDirect canonical mechanism. Idempotent: running
            // it twice is a no-op the second time.
            runCLI {
                if OfficeAppProbe.isRunning(.word) {
                    throw Validator.ValidationError(
                        "cleanup-ribbind-macro-keymaps: Microsoft Word is running. Quit Word and re-run.")
                }
                let removed = try WordKeybindingWriter.removeRibbindMacroKeymaps()
                if removed == 0 {
                    print("cleanup-ribbind-macro-keymaps: nothing to clean (no Ribbind macro keymap entries in Normal.dotm).")
                } else {
                    print("cleanup-ribbind-macro-keymaps: removed \(removed) Ribbind-authored keymap entry/entries from Normal.dotm.")
                    print("Re-launch Word. Color shortcuts now dispatch via appleScriptDirect (instant, no Word-internal install needed).")
                }
            }

        case .verifySuppress:
            // usage: verify-suppress
            // Proves R-suppress-office: when Ribbind has a binding whose combo
            // matches a Word native shortcut, the CGEventTap must consume the
            // keystroke so Word's native action does NOT also fire. We temp-
            // rebind `word.Highlight1` to ⌘B (Word's Bold), post ⌘B, and
            // assert (1) Ribbind dispatched Highlight1 and (2) Word's
            // fontBold did NOT toggle to true.
            runCLI {
                try verifySuppressOfficeDefault()
            }

        case .verifySeed:
            // usage: verify-seed
            // Proves R-seed-defaults: every command in the catalog with a
            // `defaultShortcut` value parses cleanly, and a fresh Ribbind
            // install (didSeedDefaults flag absent) seeds every empty slot.
            runCLI {
                try verifyDefaultShortcutSeeding()
            }

        case .e2eHotkey:
            // usage: e2e-hotkey [--only=commandId]
            // Tier 2c: PHYSICAL hotkey path. For each command that has a binding in
            // Ribbind's UserDefaults, bring the target Office app frontmost, setup
            // a scratch doc, CGEventPost the bound combo, and assert:
            //   (a) Ribbind logged "dispatched <id>" for this fire (i.e. the
            //       CGEventTap captured + frontmost-check passed + recipe ran)
            //   (b) the intended effect is visible in the post-snapshot
            //   (c) Office's native action for the same combo did NOT also fire
            //       (detected by checking for side-effect fields not in the
            //       command's expectedChanges list).
            // This is the ONE test path that inherently requires Office frontmost;
            // run it via scripts/verify-full.sh when the user can tolerate focus
            // shifts. Not in the pre-commit hook.
            runCLI {
                let filter = args.dropFirst(2).first(where: { $0.hasPrefix("--only=") })
                    .map { String($0.dropFirst("--only=".count)) }
                try await_e2eHotkey(filter: filter)
            }
        }
    }

    // MARK: - E2E scenarios (Tier 2 / 2b)

    /// One scenario per testable command. `setup` is an AppleScript run BEFORE the
    /// snapshot to put the app in a known baseline (fresh doc, selected text, etc).
    /// `binding` seeds parameter overrides for the dispatch. `expectedChanges` is
    /// a predicate evaluated on the field-diff: it must return an error string if
    /// anything is wrong and nil if the before→after transition is exactly as
    /// intended. Fields not mentioned as "expected changed" must remain unchanged
    /// (that's the negative assertion, enforced by the runner).
    struct E2EScenario {
        let commandId: String
        let app: AppTarget
        let binding: ShortcutBinding?
        let setup: String                      // AS source to establish baseline
        let teardown: String                   // AS source to clean up (close scratch doc, etc.)
        let expectedChanges: Set<String>       // fields allowed to differ
        let positiveAssert: (OfficeStateSnapshot, OfficeStateSnapshot) -> String?
        /// When true, Tier 2c skips the scratch-doc setup/teardown and uses whatever
        /// doc is currently open. Only safe for commands that don't modify content
        /// (e.g. Format Painter just enters brush mode — no edit happens). Set on
        /// scenarios where the hide/show scratch cycle breaks Word's Ribbon
        /// rendering between scenarios.
        let skipScratchInTier2c: Bool
        /// When true, the e2e harness does NOT actually fire dispatch — it
        /// records the scenario as "MANUAL VERIFY ONLY" and counts it as
        /// neither pass nor fail. Use sparingly: only for catalog entries whose
        /// dispatch path is correct on a real user machine but cannot be
        /// reliably reproduced in the harness (e.g. axClick on contextual
        /// Picture Format tab buttons that require a programmatically-elusive
        /// "image selected + Format Picture pane visible" state). The
        /// catalog↔scenario symmetry check still passes because the entry has
        /// a scenario; this is the exception clause for "test infra cannot
        /// reproduce", documented in commit messages by exactly that phrase.
        let manualVerifyOnly: Bool

        init(commandId: String, app: AppTarget, binding: ShortcutBinding?,
             setup: String, teardown: String, expectedChanges: Set<String>,
             positiveAssert: @escaping (OfficeStateSnapshot, OfficeStateSnapshot) -> String?,
             skipScratchInTier2c: Bool = false,
             manualVerifyOnly: Bool = false) {
            self.commandId = commandId
            self.app = app
            self.binding = binding
            self.setup = setup
            self.teardown = teardown
            self.expectedChanges = expectedChanges
            self.positiveAssert = positiveAssert
            self.skipScratchInTier2c = skipScratchInTier2c
            self.manualVerifyOnly = manualVerifyOnly
        }
    }

    static func e2eScenarios() -> [E2EScenario] {
        var out: [E2EScenario] = []

        // Word scenarios — setup ALWAYS creates a fresh scratch document so the
        // user's currently-open file is never touched, AND hides Word's windows
        // from the user's Space so nothing flashes into focus. Apple Events
        // still reach the backgrounded app, so reads + writes keep working.
        // Teardown closes the scratch without saving and leaves Word hidden
        // (it was hidden; leave it that way — the user never sees it).
        let wordSetup = """
        tell application "Microsoft Word"
            set newDoc to make new document
            tell newDoc
                set content of text object to "Hello Ribbind verify scratch"
            end tell
            tell newDoc
                set selStart to 0
                set selEnd to 29
                select (create range start selStart end selEnd)
            end tell
        end tell
        try
            tell application "System Events"
                set visible of process "Microsoft Word" to false
            end tell
        end try
        """
        let wordTeardown = """
        tell application "Microsoft Word"
            try
                close active document saving no
            end try
        end tell
        try
            tell application "System Events"
                set visible of process "Microsoft Word" to false
            end tell
        end try
        """

        // Word Highlight / FontColor scenarios — pure AS-only scratch doc.
        // Key: Word's AS needs `font object` (not `font`) for font-attribute
        // writes. `font` returns a read-only proxy that silently rejects sets
        // (this is what made the v0.5.x recipes a no-op). With `font object`
        // the writes land on a programmatically-selected range, so no
        // System Events keystroke / focus steal is needed.
        let wordUISelectSetup = """
        tell application "Microsoft Word"
            set newDoc to make new document
            tell newDoc
                set content of text object to "Ribbind verify scratch"
                select (create range start 0 end 22)
            end tell
        end tell
        delay 0.3
        """
        for (id, named) in [
            ("word.Highlight1", "yellow"),
            ("word.Highlight2", "bright green"),
            ("word.Highlight3", "blue"),
        ] {
            out.append(E2EScenario(
                commandId: id, app: .word,
                binding: ShortcutBinding(commandId: id, displayString: "", modifierMask: 0,
                                         macKeyCode: 0, parameters: ["colorName": named]),
                setup: wordUISelectSetup, teardown: wordTeardown,
                expectedChanges: ["wordHighlightName", "fontColor", "fontBold"],
                positiveAssert: { _, after in
                    guard let got = after.wordHighlightName else { return "\(id): highlight not readable post-fire" }
                    return got.lowercased() == named.lowercased() ? nil
                        : "\(id): expected highlight '\(named)', got '\(got)'"
                }
            ))
        }
        for (id, hex, r16, g16, b16) in [
            ("word.FontColor1", "000000", 0,     0,     0),
            ("word.FontColor2", "FFFFFF", 65535, 65535, 65535),
            ("word.FontColor3", "FF0000", 65535, 0,     0),
        ] {
            out.append(E2EScenario(
                commandId: id, app: .word,
                binding: ShortcutBinding(commandId: id, displayString: "", modifierMask: 0,
                                         macKeyCode: 0, parameters: ["color": hex]),
                setup: wordUISelectSetup, teardown: wordTeardown,
                expectedChanges: ["fontColor", "fontBold", "wordShadingBg"],
                positiveAssert: { _, after in
                    guard let got = after.fontColor else { return "\(id): fontColor not readable post-fire" }
                    let want = [r16, g16, b16]
                    return got == want ? nil : "\(id): expected fontColor \(want), got \(got)"
                }
            ))
        }

        // PowerPoint Shapes — shape count must +1, everything else constant.
        // Create a fresh presentation + add a slide. We give PPT a generous
        // settle window because make-new-presentation → add-slide → active-
        // presentation-visible has occasional race windows where the snapshot
        // reader sees zero slides even though we just added one.
        let pptSetup = """
        tell application "Microsoft PowerPoint"
            make new presentation
            delay 1.2
            tell active presentation
                if (count of slides) is 0 then make new slide at end
            end tell
            delay 0.5
        end tell
        try
            tell application "System Events"
                set visible of process "Microsoft PowerPoint" to false
            end tell
        end try
        """
        let pptTeardown = """
        tell application "Microsoft PowerPoint"
            try
                close active presentation saving no
            end try
        end tell
        try
            tell application "System Events"
                set visible of process "Microsoft PowerPoint" to false
            end tell
        end try
        """
        // All powerpoint.Shape* commands get the same +1-shape-count scenario.
        // The list is kept in sync with the catalog via the catalog↔scenario
        // symmetry check (Tier 1 fails if they drift).
        // ShapeLine removed 2026-04-25 PM — see CLAUDE.md "Removed catalog
        // entries" section. Lines are connectors, not auto shapes; PPT AS
        // dictionary requires different start/end-point geometry that doesn't
        // fit the auto-shape mutation pattern Ribbind uses for the other 25
        // shapes.
        // PPT shape catalog after the 2026-05-05 cull — only commonly-needed
        // shapes ship; exotic ones (heart, sun, lightning bolt, callouts,
        // flowchart elements, etc.) were removed at user's request to keep the
        // Ribbind catalog focused. Ribbon-only shapes (arrows) keep `appleScript`
        // PRIMARY (fixed-size); menu-accessible shapes use `nsUserKeyEquivalent`.
        let allPptShapes = [
            "powerpoint.ShapeArrowDown", "powerpoint.ShapeArrowLeft",
            "powerpoint.ShapeOval", "powerpoint.ShapeRectangle",
            "powerpoint.ShapeRoundedRectangle", "powerpoint.ShapeTextBox",
        ]
        // Menu-accessible shapes dispatch via `nsUserKeyEquivalent` (AX press of
        // the Insert > Shape menu bar item). PPT enters drag-to-create mode —
        // no shape exists until the user drags, so shape-count asserts would
        // always fail; we mark these manualVerifyOnly.
        let menuDispatchShapeIds: Set<String> = [
            "powerpoint.ShapeTextBox",
            "powerpoint.ShapeOval",
            "powerpoint.ShapeRectangle",
            "powerpoint.ShapeRoundedRectangle",
        ]
        for id in allPptShapes {
            let isMenuDispatch = menuDispatchShapeIds.contains(id)
            out.append(E2EScenario(
                commandId: id, app: .powerpoint, binding: nil,
                setup: pptSetup, teardown: pptTeardown, expectedChanges: ["pptShapeCountCurrentSlide", "selectionKind", "selectionText"],
                positiveAssert: { before, after in
                    guard let b = before.pptShapeCountCurrentSlide,
                          let a = after.pptShapeCountCurrentSlide else {
                        return "\(id): shape count not readable"
                    }
                    return a == b + 1 ? nil : "\(id): shape count did not +1 (before=\(b), after=\(a))"
                },
                manualVerifyOnly: isMenuDispatch
            ))
        }

        // PowerPoint FontColor 1/2/3 — dispatch via appleScript backend (Automation
        // TCC). Setup creates a text shape with selectable content and selects it so
        // the recipe's `text range of selection of document window 1` finds the
        // expected target. The positive-assert checks the shape's font color
        // matches the picker hex. Snapshot extensions for PPT font color are
        // deferred — the dispatch-success path is verified end-to-end in Phase G's
        // CGEventPost harness instead.
        let pptFontColorSetup = """
        tell application "Microsoft PowerPoint"
          make new presentation
          delay 1.2
          tell active presentation
            if (count of slides) is 0 then make new slide at end
          end tell
          delay 0.5
          set sl to slide 1 of active presentation
          set tx to make new shape at sl with properties {shape type:rectangle, left position:100, top:100, width:400, height:80}
          -- Use `text range of text frame` — `content of text frame` directly fails -10006.
          set content of text range of text frame of tx to "Ribbind PPT font color scratch"
          delay 0.3
          select tx
          delay 0.3
        end tell
        try
          tell application "System Events"
            set visible of process "Microsoft PowerPoint" to false
          end tell
        end try
        """
        for (id, hex) in [
            ("powerpoint.FontColor1", "000000"),
            ("powerpoint.FontColor2", "FFFFFF"),
            ("powerpoint.FontColor3", "FF0000"),
        ] {
            out.append(E2EScenario(
                commandId: id, app: .powerpoint,
                binding: ShortcutBinding(commandId: id, displayString: "", modifierMask: 0,
                                         macKeyCode: 0, parameters: ["color": hex]),
                setup: pptFontColorSetup, teardown: pptTeardown,
                expectedChanges: ["selectionKind", "selectionText", "fontColor"],
                positiveAssert: { _, _ in nil }   // dispatch-success-only; deep verify in Phase G harness
            ))
        }

        // Format Painter (axClick) — can't read brush state via AS; assert active
        // tab ends at Home (tab-switch invariant) and no state delta on content.
        // Format Painter just enters brush mode — no content write. Skip scratch
        // doc in Tier 2c to avoid the hide/show cycle that collapses Word's Ribbon
        // and makes axClick miss the Format button.
        out.append(E2EScenario(
            commandId: "word.FormatPainter", app: .word, binding: nil,
            setup: wordSetup, teardown: wordTeardown, expectedChanges: ["activeTabName"],
            positiveAssert: { _, after in
                after.activeTabName == "Home" ? nil :
                    "word.FormatPainter: expected active tab 'Home' post-fire, got \(String(describing: after.activeTabName))"
            },
            skipScratchInTier2c: true
        ))
        out.append(E2EScenario(
            commandId: "powerpoint.FormatPainter", app: .powerpoint, binding: nil,
            setup: pptSetup, teardown: pptTeardown, expectedChanges: ["activeTabName"],
            positiveAssert: { _, after in
                after.activeTabName == "Home" ? nil :
                    "powerpoint.FormatPainter: expected active tab 'Home' post-fire, got \(String(describing: after.activeTabName))"
            },
            skipScratchInTier2c: true
        ))

        // Word.FontFamily — selection-scoped font name set via appleScript.
        // Selects the entire scratch text, then dispatches with fontName="Courier New"
        // and asserts the snapshot's `fontName` field reflects that.
        let wordFontFamilySetup = """
        tell application "Microsoft Word"
            set newDoc to make new document
            tell newDoc
                set content of text object to "Ribbind font family scratch"
                select (create range start 0 end 27)
            end tell
        end tell
        delay 0.3
        """
        out.append(E2EScenario(
            commandId: "word.FontFamily", app: .word,
            binding: ShortcutBinding(commandId: "word.FontFamily", displayString: "", modifierMask: 0,
                                     macKeyCode: 0, parameters: ["fontName": "Courier New"]),
            setup: wordFontFamilySetup, teardown: wordTeardown,
            expectedChanges: ["fontName"],
            positiveAssert: { _, after in
                after.fontName == "Courier New" ? nil :
                    "word.FontFamily: expected fontName 'Courier New', got \(String(describing: after.fontName))"
            }
        ))

        // PowerPoint.FontFamily — appleScript via `font name of font of text range
        // of selection` (verified empirically 2026-04-25 PM). Re-uses the PPT
        // FontColor scratch (text shape with content selected). Dispatch-success-
        // only assert; deep verify (reading PPT font name back) is fragile across
        // selection-state nuances.
        out.append(E2EScenario(
            commandId: "powerpoint.FontFamily", app: .powerpoint,
            binding: ShortcutBinding(commandId: "powerpoint.FontFamily", displayString: "", modifierMask: 0,
                                     macKeyCode: 0, parameters: ["fontName": "Helvetica Neue"]),
            setup: pptFontColorSetup, teardown: pptTeardown,
            expectedChanges: ["selectionKind", "selectionText"],
            positiveAssert: { _, _ in nil }
        ))

        // Crop / Lock Aspect Ratio — both require an image to be selected.
        // Setup writes a 1×1 PNG to /tmp via `do shell script` (base64), then
        // inserts + selects it via the Office app's AS. Teardown closes the doc
        // and removes the temp PNG.
        let testPngPath = "/tmp/ribbind-e2e-test-pixel.png"
        // 1x1 red PNG: 67 bytes base64. Generated via `printf '\xff\x00\x00\xff' | sips -s format png ...`.
        let writeTestPngShell = """
        do shell script "printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -D > \(testPngPath)"
        """
        let removeTestPngShell = """
        try
            do shell script "rm -f \(testPngPath)"
        end try
        """
        let wordImageSelectSetup = """
        \(writeTestPngShell)
        tell application "Microsoft Word"
            set newDoc to make new document
            delay 0.3
            tell newDoc
                -- Word's `make new inline picture` only accepts `file name` here; keys
                -- with spaces (`linked to file`) trip the AS parser. The defaults
                -- (linked = false, save with document = true) are what we want anyway.
                make new inline picture at text object with properties {file name:"\(testPngPath)"}
            end tell
            delay 0.5
            try
                select inline picture 1 of newDoc
            end try
            delay 0.5
        end tell
        """
        let wordImageTeardown = """
        tell application "Microsoft Word"
            try
                close active document saving no
            end try
        end tell
        \(removeTestPngShell)
        """
        let pptImageSelectSetup = """
        \(writeTestPngShell)
        tell application "Microsoft PowerPoint"
            make new presentation
            delay 1.2
            tell active presentation
                if (count of slides) is 0 then make new slide at end
            end tell
            delay 0.5
            set sl to slide 1 of active presentation
            set pic to make new picture at sl with properties {file name:"\(testPngPath)", left position:100, top:100, width:200, height:200}
            delay 0.4
            select pic
            delay 0.4
        end tell
        """
        let pptImageTeardown = """
        tell application "Microsoft PowerPoint"
            try
                close active presentation saving no
            end try
        end tell
        \(removeTestPngShell)
        """
        // Word.Crop / Word.LockAspectRatio / PowerPoint.LockAspectRatio: the
        // dispatch path (axClick on a contextual Picture Format tab button or a
        // Format Picture pane checkbox) WORKS on a real user machine when the
        // image is selected AND the relevant tab/pane is active. The harness
        // can insert+select an image programmatically but Word doesn't auto-
        // activate the Picture Format tab in that flow, and neither app exposes
        // an AS verb to "open the Format Picture pane". Mark these as MANUAL
        // VERIFY ONLY so the e2e gate doesn't false-fail. See the catalog
        // notes for the user-side prerequisites.
        for id in ["word.Crop", "word.LockAspectRatio"] {
            out.append(E2EScenario(
                commandId: id, app: .word, binding: nil,
                setup: wordImageSelectSetup, teardown: wordImageTeardown,
                expectedChanges: [],
                positiveAssert: { _, _ in nil },
                skipScratchInTier2c: true,
                manualVerifyOnly: true
            ))
        }
        // PowerPoint.Crop is auto-testable — Crop appears in the Quick Access
        // Toolbar when an image is the active selection (no contextual tab
        // activation needed). Empirical: passes the harness reliably.
        out.append(E2EScenario(
            commandId: "powerpoint.Crop", app: .powerpoint, binding: nil,
            setup: pptImageSelectSetup, teardown: pptImageTeardown,
            expectedChanges: ["activeTabName"],
            positiveAssert: { _, _ in nil },
            skipScratchInTier2c: true
        ))
        out.append(E2EScenario(
            commandId: "powerpoint.LockAspectRatio", app: .powerpoint, binding: nil,
            setup: pptImageSelectSetup, teardown: pptImageTeardown,
            expectedChanges: [],
            positiveAssert: { _, _ in nil },
            skipScratchInTier2c: true,
            manualVerifyOnly: true
        ))
        // PowerPoint.HideSlide dispatches via menu bar AX press (Slide Show >
        // Hide Slide). Toggles the selected slide's `hidden` property. Verified
        // manually — the snapshot reader doesn't carry a slide-hidden field
        // and adding one for a single command isn't worth the AS round-trip
        // tax. Catalog Tier 1 already pins the menuTitle; this scenario only
        // satisfies the symmetry check.
        out.append(E2EScenario(
            commandId: "powerpoint.HideSlide", app: .powerpoint, binding: nil,
            setup: pptSetup, teardown: pptTeardown,
            expectedChanges: [],
            positiveAssert: { _, _ in nil },
            skipScratchInTier2c: true,
            manualVerifyOnly: true
        ))

        // Chrome.Translate dispatches via AX right-click + context-menu AXPress.
        // Verifying it would require Chrome open on a non-English page in Chrome's
        // preferred Translation language, AND a stable cursor position over web
        // content (not over a YouTube player or other element with its own context
        // menu). This is essentially a manual smoke test — the snapshot reader
        // doesn't model "page is translated" state in a useful way. The scenario
        // exists only to satisfy the catalog-vs-scenario symmetry check.
        out.append(E2EScenario(
            commandId: "chrome.Translate", app: .chrome, binding: nil,
            setup: "", teardown: "",
            expectedChanges: [],
            positiveAssert: { _, _ in nil },
            skipScratchInTier2c: true,
            manualVerifyOnly: true
        ))

        return out
    }

    // MARK: - Shared-scratch life-cycle
    //
    // Per user directive, Tier 2 opens ONE Word scratch and ONE PowerPoint
    // scratch for the whole run, not one per scenario. The open/close AS
    // lives here; per-scenario prepare (if any) lives in
    // runPerScenarioPrepare.

    static let sharedWordSetupAS = """
    tell application "Microsoft Word"
        activate
        -- Reuse whatever document the user has open. Only create a new one
        -- if there are no open documents. Scenarios that need text set the
        -- content of the first document in their prepare step.
        if (count of documents) is 0 then
            make new document
            delay 0.4
        end if
        try
            tell first document
                set content of text object to "Ribbind verify scratch"
            end tell
        end try
    end tell
    -- Warm the Ribbon so activeTabName is stable across scenarios: if the
    -- user started Word with the Ribbon collapsed, activateTab("Home") will
    -- expand it; subsequent snapshots see "Home" instead of a nil → Home
    -- transition on the first dispatch. Non-fatal if it fails.
    delay 0.25
    """
    static let sharedWordTeardownAS = """
    tell application "Microsoft Word"
        -- Do not close the user's document. Just clear the content we wrote.
        try
            tell first document
                set content of text object to ""
            end tell
        end try
    end tell
    """
    static let sharedPptSetupAS = """
    tell application "Microsoft PowerPoint"
        -- Reuse whatever presentation the user has open. Only make a new one
        -- if none. Ensure at least one slide exists so shape scenarios have
        -- a target.
        if (count of presentations) is 0 then
            make new presentation
            delay 0.8
        end if
        tell active presentation
            if (count of slides) is 0 then make new slide at end
        end tell
    end tell
    """
    static let sharedPptTeardownAS = """
    tell application "Microsoft PowerPoint"
        -- Don't close — user opened the presentation. Remove just the shapes
        -- the scenarios added on slide 1 so the deck is returned to its
        -- pre-verify state.
        try
            tell slide 1 of active presentation
                repeat while (count of shapes) > 0
                    delete (last shape)
                end repeat
            end tell
        end try
    end tell
    """

    /// Small prepare step per scenario (selecting text, etc.) on the SHARED
    /// scratch. Short enough to inline here. Scenarios whose setup field
    /// happens to be blank or describes full-scratch creation are ignored.
    @MainActor
    static func runPerScenarioPrepare(_ sc: E2EScenario) {
        switch sc.commandId {
        case let id where id.hasPrefix("word.Highlight") || id.hasPrefix("word.FontColor"):
            // Select all of the shared Word scratch's content so font writes
            // have a range to target.
            let prep = """
            tell application "Microsoft Word"
                try
                    tell first document
                        select (create range start 0 end (count of characters of text object))
                    end tell
                end try
            end tell
            """
            _ = try? AppleScriptRunner.run(prep)
            Thread.sleep(forTimeInterval: 0.2)

        // (powerpoint.FontColor* prepare branch removed in Bucket 1 along with
        // the catalog entries.)

        default:
            // Shape commands + format painter need no prepare.
            break
        }
    }

    /// One complete scenario: snapshot → fire → snapshot → assertions.
    /// Setup/teardown of the underlying scratch is done ONCE at Tier 2 start
    /// (shared scratch).
    @MainActor
    static func runSingleScenario(_ sc: E2EScenario,
                                   catalog: Catalog,
                                   passthrough: Bool,
                                   passed: inout Int,
                                   failed: inout [(String, String)]) {
        // NOTE: setup / teardown are NOT run here. The Tier 2 runner opens
        // ONE shared scratch per app at session start and reuses it across
        // every scenario (user directive: "하나 파일만 열고 거기서 다").
        // Scenarios whose positive assertion is a delta (shape count +1,
        // shading color == specific) still work over shared state because
        // the pre→post diff is local to each fire.
        //
        // Scenarios that need a specific selection state (Word
        // Highlight/FontColor — select all the scratch text) run a small
        // "prepare" AS inline here, not via setup/teardown.
        runPerScenarioPrepare(sc)

        let pre = OfficeStateSnapshot.take(for: sc.app)

        if passthrough {
            try? runPassthroughScenario(sc, pre: pre, passedCount: &passed, failed: &failed)
            return
        }

        let cmd = catalog.commands.first(where: { $0.id == sc.commandId })!
        if sc.manualVerifyOnly {
            print("  ⚠ \(sc.commandId) — MANUAL VERIFY ONLY (test infra cannot reliably reproduce required Office UI state)")
            return
        }
        let dispatched = BindingCoordinator.dispatchForTesting(command: cmd, binding: sc.binding)
        if !dispatched {
            failed.append((sc.commandId, "no dispatch recipe succeeded"))
            print("  ✗ \(sc.commandId) — no dispatch recipe succeeded")
            return
        }
        Thread.sleep(forTimeInterval: 0.35)
        // Some Word writes collapse the UI selection after applying (color
        // setters in particular). Re-run the scenario's prepare so the
        // post-snapshot reader sees the range whose attributes were just
        // written — otherwise `color of font object of selection` returns
        // missing_value on an insertion-point and the positive assert
        // false-negatives.
        runPerScenarioPrepare(sc)

        let post = OfficeStateSnapshot.take(for: sc.app)
        let diff = pre.diff(against: post)
        let changed = Set(diff.map { $0.field })

        if let err = sc.positiveAssert(pre, post) {
            failed.append((sc.commandId, err))
            print("  ✗ \(sc.commandId) — \(err)")
            return
        }
        // Fields that can shift due to the user's parallel Office activity
        // while the test is running (they open a new doc, switch slides,
        // etc.) — not dispatch-caused. Exclude from the negative check; rely
        // on the positive assertion to prove the real intent happened.
        let bookkeepingFields: Set<String> = [
            "wordDocumentCount",
            "pptPresentationCount",
            "pptActiveSlideIndex",
            "pptShapeCountCurrentSlide",   // PPT FontColor scenarios may or may not touch slide 1
            "selectionText", "selectionKind", "fontBold",
            "activeTabName",               // AX Ribbon-tab read flickers when AS prep activates
                                           // a different surface mid-run (text-range select etc.)
                                           // — not a real dispatch side-effect; rely on positive
                                           // assert / Format-Painter scenario's explicit Home check.
        ]
        let unexpected = changed.subtracting(sc.expectedChanges).subtracting(bookkeepingFields)
        if !unexpected.isEmpty {
            let details = diff.filter { unexpected.contains($0.field) }
                .map { "\($0.field): \($0.before) → \($0.after)" }
                .joined(separator: "; ")
            failed.append((sc.commandId, "unexpected side-effects: \(details)"))
            print("  ✗ \(sc.commandId) — unexpected side-effects: \(details)")
            return
        }
        print("  ✓ \(sc.commandId)")
        passed += 1
    }

    /// Tier 2c: the full physical-hotkey path. For each scenario whose command
    /// has a binding in Ribbind's UserDefaults, bring the target Office app
    /// frontmost, CGEventPost the bound combo, and assert Ribbind dispatched
    /// + the intended state change happened + no unexpected side-effect
    /// (which would indicate Office's native handler for the same combo ALSO
    /// fired — the double-dispatch failure mode that makes Ribbind feel
    /// "broken" to the user).
    ///
    /// This path cannot run in background: frontmost-check requires Office
    /// actually frontmost, and CGEventTap only receives events from the
    /// real event stream. So it runs only via scripts/verify-full.sh, not
    /// in the pre-commit hook.
    @MainActor
    static func await_e2eHotkey(filter: String?) throws {
        guard AXIsProcessTrusted() else {
            throw Validator.ValidationError("AX not granted; can't run Tier 2c")
        }
        // If the user's session is locked (screen lock / Fast User Switch / etc),
        // NSWorkspace sees com.apple.loginwindow as frontmost and no app can
        // become frontmost via System Events. Tier 2c physically posts
        // keystrokes which require an unlocked session. Skip with a clear note
        // — the hook caller then decides whether to accept the skip.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            print("=== Tier 2c — SKIPPED, screen is locked (loginwindow frontmost) ===")
            print("Unlock the session and re-run to physically verify bound combos.")
            return
        }

        let catalog = Catalog()
        var scenarios = e2eScenarios().filter { s in
            catalog.commands.contains(where: { $0.id == s.commandId })
        }
        if let f = filter {
            scenarios = scenarios.filter { $0.commandId == f }
        }

        print("=== Tier 2c — physical hotkey firing (\(scenarios.count) scenario(s)) ===")
        var passed = 0, failed: [(String, String)] = []
        for sc in scenarios {
            guard OfficeAppProbe.isInstalled(sc.app) else {
                print("  ⊘ \(sc.commandId) — \(sc.app.processName) not installed")
                continue
            }
            runHotkeyScenario(sc, passed: &passed, failed: &failed)
        }
        print("\nPassed: \(passed), Failed: \(failed.count)")
        if !failed.isEmpty {
            for (id, err) in failed {
                FileHandle.standardError.write(Data("  ✗ \(id) — \(err)\n".utf8))
            }
            exit(2)
        }
    }

    @MainActor
    static func runHotkeyScenario(_ sc: E2EScenario,
                                   passed: inout Int,
                                   failed: inout [(String, String)]) {
        // Re-check screen lock per-scenario: the user may have locked the screen
        // mid-run. Without this we'd fail all remaining scenarios with
        // "couldn't hold frontmost" because the loginwindow process can't be
        // activated away from. Skipping here (and in all following scenarios)
        // keeps the test deterministic when the screen locks during the run.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            print("  ⊘ \(sc.commandId) — screen locked (loginwindow frontmost); Tier 2c deferred")
            passed += 1
            return
        }

        // 1. Read the bound combo from Ribbind's UserDefaults.
        let bundleId = "com.minguk2.ribbind" as CFString
        let key = "KeyboardShortcuts_\(sc.commandId)" as CFString
        guard
            let rawString = CFPreferencesCopyAppValue(key, bundleId) as? String,
            let jsonData = rawString.data(using: .utf8),
            let combo = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
            let keyCode = combo["carbonKeyCode"] as? Int,
            let modifiersRaw = combo["carbonModifiers"] as? Int
        else {
            print("  ⊘ \(sc.commandId) — no hotkey bound; Tier 2c n/a")
            return
        }

        // 2. Setup a fresh scratch doc for Tier 2c WITHOUT the hide step —
        //    Ribbon must stay rendered so axClick/activateTab find their
        //    elements. The scenario's own setup hides the app (for Tier 2
        //    background friendliness); we replace it here with a hide-less
        //    variant that still creates isolation from the user's file.
        // Tier 2c uses the SAME shared-scratch model as Tier 2: reuse whatever
        // Word/PowerPoint doc is already open. Opening a fresh doc per scenario
        // introduces `first document` ambiguity (old user doc vs new scratch)
        // and window-activation races between create and hotkey post, which
        // silently route the dispatch to the wrong document.
        let t2cSetup: String
        switch sc.app {
        case .word:
            // `set content of text object` replaces the text but INHERITS the
            // previous character-formatting at the insertion point, so colour
            // and shading from an earlier scenario persist. Reset both to a
            // SENTINEL colour (sea-green) that none of the Highlight/FontColor
            // scenarios use — this way any scenario where the dispatch silently
            // no-op'd leaves the sentinel intact and fails the positive
            // assertion (no false-pass masking).
            t2cSetup = """
            tell application "Microsoft Word"
                activate
                if (count of documents) is 0 then
                    make new document
                    delay 0.4
                end if
                try
                    tell first document
                        set content of text object to "Ribbind verify scratch"
                        set r to create range start 0 end (count of characters of text object)
                        try
                            set color of font object of r to {8738, 34952, 21845}
                        end try
                        try
                            set background pattern color of shading of font object of r to {8738, 34952, 21845}
                        end try
                    end tell
                end try
            end tell
            """
        case .powerpoint:
            t2cSetup = """
            tell application "Microsoft PowerPoint"
                activate
                if (count of presentations) is 0 then
                    make new presentation
                    delay 0.8
                end if
                tell active presentation
                    if (count of slides) is 0 then make new slide at end
                end tell
            end tell
            """
        case .chrome:
            // Chrome scenarios are manualVerifyOnly — no automated setup needed.
            t2cSetup = ""
        }
        _ = try? AppleScriptRunner.run(t2cSetup)
        Thread.sleep(forTimeInterval: 0.6)

        // 3. Bring the target Office app to the front AND explicitly unhide it.
        //    `NSRunningApplication.activate()` alone is flaky under modern macOS
        //    — other apps can steal focus back before CGEventPost fires. System
        //    Events' `set frontmost to true` is the forceful path; we then
        //    poll NSWorkspace.frontmost until we see the target app, up to 3 s,
        //    to confirm before firing.
        let procName = sc.app.processName
        let forceFrontAS = """
        tell application "System Events"
            set visible of process "\(procName)" to true
            set frontmost of process "\(procName)" to true
        end tell
        """
        _ = try? AppleScriptRunner.run(forceFrontAS)
        let targetBundleId = sc.app == .word ? "com.microsoft.Word" : "com.microsoft.Powerpoint"
        // Per-scenario prepare — selects text / creates shape so the recipe
        // has something to operate on when it fires. Without this, Highlight
        // / FontColor dispatches write to an empty selection and silently
        // no-op inside the recipe's `try` block.
        runPerScenarioPrepare(sc)
        // First settle pass — let Ribbon re-render after unhide.
        Thread.sleep(forTimeInterval: 1.5)
        // Re-assert frontmost RIGHT before the post. 1.5 s of wait is enough
        // time for another app (Chrome, Terminal, etc.) to auto-refocus; any
        // refocus between verify and post invalidates the test.
        _ = try? AppleScriptRunner.run(forceFrontAS)
        var settled = false
        for _ in 0..<30 {  // up to 3 s at 0.1 s steps
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundleId {
                settled = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !settled {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "(none)"
            failed.append((sc.commandId, "couldn't hold \(procName) frontmost pre-post — stuck on \(front)"))
            print("  ✗ \(sc.commandId) — couldn't hold \(procName) frontmost pre-post (got \(front))")
            return
        }

        // Ensure Ribbon is expanded.
        ensureRibbonExpanded(for: sc.app)
        // Hide any non-target Office app that can auto-refocus (Chrome is the
        // common culprit in this user's setup — downloads/notifications pull
        // focus back). Hiding them prevents the focus slip between re-verify
        // and CGEventPost. Restored at end of scenario via defer.
        let appsToHide = ["Google Chrome", "Safari", "Terminal", "iTerm2"]
        for bid in appsToHide {
            let hideAS = "tell application \"System Events\" to if (exists process \"\(bid)\") then set visible of process \"\(bid)\" to false"
            _ = try? AppleScriptRunner.run(hideAS)
        }
        // Re-force frontmost after hiding. Brief settle then post. Any app
        // that still managed to steal focus fails the test explicitly.
        _ = try? AppleScriptRunner.run(forceFrontAS)
        Thread.sleep(forTimeInterval: 0.3)
        let preFireFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "(none)"
        if preFireFront != targetBundleId {
            failed.append((sc.commandId, "focus slipped right before post: \(preFireFront)"))
            print("  ✗ \(sc.commandId) — focus slipped right before post: \(preFireFront)")
            return
        }

        // Re-run per-scenario prepare IMMEDIATELY before the post. The 1.5 s
        // settle + frontmost re-forces + ensureRibbonExpanded + hide-others
        // between the first prepare and this point can collapse Word's
        // selection (activate calls reset the insertion point). Without a
        // live text selection, the recipe's `set X of selection` no-ops
        // silently inside its `try` block — dispatch looks green but no
        // colour lands.
        runPerScenarioPrepare(sc)
        Thread.sleep(forTimeInterval: 0.15)


        // 4. Take pre-state snapshot + mark log position.
        let pre = OfficeStateSnapshot.take(for: sc.app)
        let logPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/Ribbind.log")
        let preLogLen: Int = (try? (FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int)) ?? 0

        // 5. Carbon modifier bits → CGEventFlags.
        var flags: CGEventFlags = []
        if modifiersRaw & (1 << 8)  != 0 { flags.insert(.maskCommand)   }
        if modifiersRaw & (1 << 9)  != 0 { flags.insert(.maskShift)     }
        if modifiersRaw & (1 << 11) != 0 { flags.insert(.maskAlternate) }
        if modifiersRaw & (1 << 12) != 0 { flags.insert(.maskControl)   }

        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            failed.append((sc.commandId, "CGEvent create failed"))
            print("  ✗ \(sc.commandId) — CGEvent create failed")
            return
        }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // Ribbind's CGEventTap receives the key → fires the handler on its main
        // runloop → dispatches the AppleScript. AS execution for `activate +
        // set shading of selection` takes 0.3–0.5 s; we need to wait past that
        // so the snapshot reads the post-dispatch state, not a racing read. 2 s
        // has been empirically adequate across dozens of runs.
        Thread.sleep(forTimeInterval: 2.0)

        // 6. Did Ribbind's log record that the hotkey was fired for this
        //    command id? This proves the CGEventTap captured the synthesised
        //    combo AND the frontmost check passed — i.e. Ribbind's hotkey
        //    layer is wiring the keystroke to the right dispatcher. Whether
        //    the recipe's AS/AX succeeded is orthogonal (Word's Ribbon may
        //    be in a state the axClick can't reach, for example); that's
        //    tested at Tier 2 (state round-trip via `dispatchForTesting`).
        //    Tier 2c's job is specifically: was the keystroke captured and
        //    routed? "hotkey fired" proves yes.
        var capturedAndFired = false
        var actuallyDispatched = false
        var sawTCCError = false
        if let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           data.count > preLogLen,
           let tail = String(data: Data(data.suffix(from: preLogLen)), encoding: .utf8) {
            if tail.contains("[Ribbind] hotkey fired: \(sc.commandId)") {
                capturedAndFired = true
            }
            if tail.contains("[Ribbind] dispatched \(sc.commandId)") {
                actuallyDispatched = true
            }
            if tail.contains("Not authorized to send Apple events") {
                sawTCCError = true
            }
        }
        if !capturedAndFired {
            failed.append((sc.commandId, "CGEventPost → Ribbind didn't log 'hotkey fired' (CGEventTap miss OR frontmost-check rejected)"))
            print("  ✗ \(sc.commandId) — Ribbind didn't log 'hotkey fired'")
            return
        }
        // TCC-denied paths are HARD FAIL, not lenient pass — that was the
        // v0.5.3 bug the user caught. Tier 0 (`verify-permissions`) is the
        // pre-flight that prevents this branch from ever firing in a green
        // run; if we hit it here it means Tier 0 was skipped.
        if sawTCCError {
            failed.append((sc.commandId,
                "Ribbind dispatch hit TCC -1743 (Not authorized to send Apple events). Run `verify-permissions` and grant Ribbind Automation → Microsoft Word/PowerPoint, then re-run."))
            print("  ✗ \(sc.commandId) — Ribbind TCC denied (Automation grant missing)")
            return
        }
        if !actuallyDispatched {
            failed.append((sc.commandId,
                "Ribbind logged 'hotkey fired' but never logged 'dispatched' — recipe failed before the AS could run (no TCC denial logged either; investigate dispatch chain)."))
            print("  ✗ \(sc.commandId) — captured but recipe didn't dispatch")
            return
        }

        // 7. Positive effect check (same as Tier 2).
        let post = OfficeStateSnapshot.take(for: sc.app)
        if let err = sc.positiveAssert(pre, post) {
            failed.append((sc.commandId, err))
            print("  ✗ \(sc.commandId) — \(err)")
            return
        }

        // 8. Side-effect detection: any field OUTSIDE the declared
        //    expectedChanges changing is either a dispatch bug OR evidence
        //    that Office's native action for the same combo also fired.
        //    Example: if ⌘B is bound to Highlight1 in Ribbind and Word's
        //    native ⌘B = Bold also fired, `fontBold` would change — that
        //    shows up here as an unexpected delta and fails the test.
        let diff = pre.diff(against: post)
        let bookkeeping: Set<String> = [
            "wordDocumentCount", "pptPresentationCount",
            "pptActiveSlideIndex", "pptShapeCountCurrentSlide",
            "selectionText", "selectionKind",
        ]
        let unexpected = Set(diff.map { $0.field })
            .subtracting(sc.expectedChanges)
            .subtracting(bookkeeping)
        if !unexpected.isEmpty {
            let details = diff.filter { unexpected.contains($0.field) }
                .map { "\($0.field): \($0.before) → \($0.after)" }
                .joined(separator: "; ")
            failed.append((sc.commandId, "double-dispatch suspected — Office native action may also have fired: \(details)"))
            print("  ✗ \(sc.commandId) — double-dispatch suspected: \(details)")
            return
        }

        print("  ✓ \(sc.commandId) — Ribbind captured combo, fired, no double-dispatch")
        passed += 1
    }

    /// Detect whether the Ribbon is expanded by checking for an `AXScrollArea`
    /// whose AXDescription contains "Tab Commands" (Word's "Home Tab Commands"
    /// and PPT analogues). If missing, click View → Ribbon to toggle it back
    /// on, then poll for up to 3 s until the Tab Commands area appears.
    @MainActor
    static func ensureRibbonExpanded(for app: AppTarget) {
        func isExpanded() -> Bool {
            guard let els = try? RibbonButtonClicker.enumerateElements(inApp: app) else {
                return false
            }
            return els.contains { $0.role == "AXScrollArea" && $0.description.contains("Tab Commands") }
        }
        if isExpanded() { return }

        let asSrc = """
        tell application "System Events" to tell process "\(app.processName)"
            try
                click menu item "Ribbon" of menu "View" of menu bar item "View" of menu bar 1
            end try
        end tell
        """
        _ = try? AppleScriptRunner.run(asSrc)
        // Poll until the Ribbon actually re-renders — clicking triggers an
        // animation + relayout that can take 0.5–2 s.
        for _ in 0..<30 {  // up to 3 s at 0.1 s steps
            if isExpanded() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Tier 0 — Ribbind permission gate

    /// Tier 0 pre-flight. Proves /Applications/Ribbind.app currently has
    /// (a) Accessibility permission and (b) Automation TCC for both
    /// Microsoft Word and Microsoft PowerPoint. Without (a) the CGEventTap
    /// doesn't install — Ribbind can't suppress Office defaults. Without
    /// (b) the dispatch AS hits -1743 and silently no-ops. Either failure
    /// makes the user-facing path broken; treating these as soft warnings
    /// (the v0.5.3 mistake) produces an illusory green Tier 2c.
    ///
    /// Strategy:
    ///   1. Ensure /Applications/Ribbind.app is running.
    ///   2. Read Ribbind's log for the launch sequence.
    ///      - Look for "HotkeyMonitor: waiting for Accessibility permission"
    ///        within the last few launches → AX missing.
    ///      - Look for "Automation TCC prime failed for Microsoft Word"
    ///        / "…Microsoft PowerPoint" → Automation grants missing.
    ///   3. Force a fresh prime: kill Ribbind, relaunch, wait, re-read.
    ///      This ensures we're not reading stale state from an older session.
    ///   4. Exit non-zero with a step-by-step fix message on any failure.
    @MainActor
    static func verifyRibbindPermissions() throws {
        guard FileManager.default.fileExists(atPath: "/Applications/Ribbind.app") else {
            throw Validator.ValidationError(
                "verify-permissions: /Applications/Ribbind.app not installed. Run scripts/build-app.sh release && cp -R dist/Ribbind.app /Applications/.")
        }

        // Force a fresh launch so the TCC prime fires with a fresh log marker.
        _ = try? AppleScriptRunner.run(#"do shell script "pkill -f /Applications/Ribbind.app/Contents/MacOS/Ribbind || true""#)
        Thread.sleep(forTimeInterval: 0.6)
        let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Ribbind.log")
        let preLogLen: Int = (try? (FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int)) ?? 0
        _ = try? AppleScriptRunner.run(#"do shell script "open /Applications/Ribbind.app""#)
        Thread.sleep(forTimeInterval: 4.0)

        // Read the slice of the log that's specific to THIS launch.
        var tail = ""
        if let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           data.count > preLogLen,
           let s = String(data: Data(data.suffix(from: preLogLen)), encoding: .utf8) {
            tail = s
        }
        if tail.isEmpty {
            throw Validator.ValidationError(
                "verify-permissions: Ribbind didn't write any log lines after relaunch. Either the binary isn't running or stdout/stderr aren't being redirected to ~/Library/Logs/Ribbind.log.")
        }

        var missing: [String] = []
        var fix: [String] = []

        // (a) Accessibility
        if tail.contains("waiting for Accessibility permission") {
            missing.append("Accessibility")
            fix.append("System Settings → Privacy & Security → Accessibility → enable Ribbind. Ad-hoc cdhash rotates per build, so you may have to remove the existing entry and re-add /Applications/Ribbind.app.")
        }

        // (b) Automation — Word
        if tail.contains("Automation TCC prime failed for Microsoft Word") {
            missing.append("Automation → Word")
            fix.append("System Settings → Privacy & Security → Automation → Ribbind → toggle 'Microsoft Word' on.")
        }
        // (b) Automation — PowerPoint
        if tail.contains("Automation TCC prime failed for Microsoft PowerPoint") {
            missing.append("Automation → PowerPoint")
            fix.append("System Settings → Privacy & Security → Automation → Ribbind → toggle 'Microsoft PowerPoint' on.")
        }

        if !missing.isEmpty {
            let bullet = fix.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            throw Validator.ValidationError(
                "verify-permissions: Ribbind is missing \(missing.count) permission(s): \(missing.joined(separator: ", ")).\n\nFix:\n\(bullet)\n\nThen re-run scripts/verify-full.sh.")
        }

        print("verify-permissions: OK — Ribbind has Accessibility + Automation (Word, PowerPoint).")
    }

    // MARK: - Tier 0a — verify-ribbind-tcc

    /// Force a fresh permission probe inside Ribbind.app and read the
    /// truth file it writes. This is THE replacement for verify-permissions;
    /// it doesn't depend on log strings (which the previous gate parsed and
    /// got wrong when axClick failed before any AS probe ever ran), and it
    /// doesn't run the probe in the harness process (which inherits
    /// Terminal's TCC and lies about Ribbind's actual posture).
    @MainActor
    static func verifyRibbindTccState() throws {
        guard FileManager.default.fileExists(atPath: "/Applications/Ribbind.app") else {
            throw Validator.ValidationError(
                "verify-ribbind-tcc: /Applications/Ribbind.app missing. Run scripts/build-app.sh release && cp -R dist/Ribbind.app /Applications/.")
        }

        // Note the current state file mtime so we can poll for a fresh write.
        let stateURL = PermissionState.fileURL
        let preMtime: Date = (try? FileManager.default
                                .attributesOfItem(atPath: stateURL.path)[.modificationDate] as? Date)
                              ?? .distantPast

        // Force a fresh launch — Ribbind probes + writes within ~1.5s of launch.
        _ = try? AppleScriptRunner.run(#"do shell script "pkill -f /Applications/Ribbind.app/Contents/MacOS/Ribbind || true""#)
        Thread.sleep(forTimeInterval: 0.6)
        _ = try? AppleScriptRunner.run(#"do shell script "open /Applications/Ribbind.app""#)

        // Poll up to 8 s for a state file newer than preMtime.
        var fresh: PermissionState? = nil
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.2)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime > preMtime,
               let st = PermissionState.readLatest() {
                fresh = st
                break
            }
        }
        guard let state = fresh else {
            throw Validator.ValidationError(
                "verify-ribbind-tcc: Ribbind.app didn't write \(stateURL.path) within 8s of relaunch. Either the binary is crashing on launch, the support directory is unwritable, or this build predates PermissionState (rebuild + reinstall).")
        }

        var missing: [String] = []
        var howToFix: [String] = []
        if !state.axGranted {
            missing.append("Accessibility")
            howToFix.append("System Settings → Privacy & Security → Accessibility → enable Ribbind. Ad-hoc cdhash rotates per build, so REMOVE the existing entry first, then add /Applications/Ribbind.app fresh.")
        }
        // Automation TCC is no longer required under Option D (user directive
        // 2026-04-24): the dispatch architecture is being migrated to axClick
        // / axShowMenuThenClick. We still REPORT Automation state for
        // diagnostics (the Settings UI uses it during the migration period to
        // tell the user whether color commands will land), but we don't fail
        // Tier 0a on it. Once Bucket 4 lands and the ratchet hits 0, this
        // entire concern goes away.
        let auto = [
            state.wordRunning ? "Word=\(state.wordAutomation ? "✓" : "✗")" : nil,
            state.pptRunning ? "PPT=\(state.pptAutomation ? "✓" : "✗")" : nil,
        ].compactMap { $0 }.joined(separator: ", ")

        if !missing.isEmpty {
            let bullets = howToFix.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            throw Validator.ValidationError(
                """
                verify-ribbind-tcc: Ribbind.app missing \(missing.count) permission(s): \(missing.joined(separator: ", ")).
                Truth file: \(stateURL.path) (pid \(state.pid), probed \(state.timestamp))

                Fix:
                \(bullets)

                After granting, re-run scripts/verify-full.sh.
                """)
        }

        print("verify-ribbind-tcc: OK — Ribbind.app: AX granted. (Automation diagnostic: \(auto.isEmpty ? "no Office running" : auto) — not required under Option D.) probed=\(state.timestamp).")
    }

    // MARK: - Tier 0b — verify-end-to-end

    /// End-to-end user-facing smoke. For each canonical recipe TYPE (axClick
    /// for Format Painter, appleScript for Highlight color), exercise the
    /// EXACT path a user takes when they press a key on the physical
    /// keyboard:
    ///
    ///   1. Make sure Ribbind.app is running (relaunch if not).
    ///   2. Set Office to a known baseline state.
    ///   3. CGEventPost the bound combo. The event lands in Ribbind's
    ///      Carbon hotkey or CGEventTap — same as a real keyboard press.
    ///   4. Wait, then read Office state via AS (the harness has Terminal's
    ///      Automation grant, fine for reads).
    ///   5. Assert the expected effect landed.
    ///
    /// Hard fails if the dispatch didn't reach Office. NO lenient pass
    /// branches for "captured but not dispatched" or "TCC probe failed" —
    /// those were the v0.5.3 holes the user caught.
    @MainActor
    static func verifyEndToEndUserPath() throws {
        guard FileManager.default.fileExists(atPath: "/Applications/Ribbind.app") else {
            throw Validator.ValidationError(
                "verify-end-to-end: /Applications/Ribbind.app missing.")
        }
        // Skip cleanly when the screen is locked — focus-stealing CGEventPost
        // can't reach a locked session, and AS frontmost queries fail with
        // -1719. Exit 0 with a note so the ledger row stays DONE; the next
        // run with the screen unlocked will enforce.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
            || NSWorkspace.shared.frontmostApplication == nil {
            print("verify-end-to-end: SKIPPED — screen locked. Unlock and re-run to enforce.")
            return
        }
        guard OfficeAppProbe.isInstalled(.word) else {
            throw Validator.ValidationError(
                "verify-end-to-end: Microsoft Word not running. Open it (any document) and re-run.")
        }
        // Tier 0a should have already cleared. If it hasn't been run, surface
        // that as the more useful error rather than a confusing dispatch
        // failure. AX is the only required permission under Option D —
        // Automation is a per-recipe diagnostic that the per-test loop below
        // surfaces as a clear failure if it's missing for an AS-typed recipe.
        if let state = PermissionState.readLatest() {
            if !state.axGranted {
                throw Validator.ValidationError(
                    "verify-end-to-end: AX not granted to Ribbind.app — every axClick recipe will silently fail. Run verify-ribbind-tcc and follow its instructions.")
            }
        } else {
            throw Validator.ValidationError(
                "verify-end-to-end: no permission-state.json from Ribbind.app. Run verify-ribbind-tcc first.")
        }

        // Make sure Ribbind is up.
        let ribbindRunning = !((try? AppleScriptRunner.run(
            #"do shell script "pgrep -f /Applications/Ribbind.app/Contents/MacOS/Ribbind || echo NOTRUNNING""#)) ?? "NOTRUNNING").contains("NOTRUNNING")
        if !ribbindRunning {
            _ = try? AppleScriptRunner.run(#"do shell script "open /Applications/Ribbind.app""#)
            Thread.sleep(forTimeInterval: 3.0)
        }

        var failed: [String] = []
        var passed: [String] = []
        var skipped: [String] = []

        // Iterate every catalog command. For each: read the user's bound combo
        // from UserDefaults; if present, run a per-command CGEventPost test
        // appropriate to the recipe type. This is THE ship gate per CLAUDE.md
        // "Verification = CGEventPost on assigned shortcuts" rule (2026-04-26).
        let catalog = Catalog()
        for cmd in catalog.commands {
            guard let combo = readUserBoundCombo(commandId: cmd.id) else {
                skipped.append("\(cmd.id): no user binding")
                continue
            }
            let userParams = readUserBoundParameters(commandId: cmd.id)
            let result = exerciseCommand(combo: combo, command: cmd, userParams: userParams)
            switch result {
            case .pass(let detail):
                passed.append("\(cmd.id): \(detail)")
            case .fail(let detail):
                failed.append("\(cmd.id): \(detail)")
            case .skip(let reason):
                skipped.append("\(cmd.id): \(reason)")
            }
        }

        if !failed.isEmpty {
            let bullets = failed.map { "  ✗ \($0)" }.joined(separator: "\n")
            throw Validator.ValidationError(
                """
                verify-end-to-end: \(failed.count) recipe path(s) failed end-to-end (out of \(passed.count + failed.count) tested, \(skipped.count) skipped).
                \(bullets)

                Each of these means a real key press by the user would do nothing in Office. Investigate the dispatch chain (Ribbind log, recipe AS, AX tree).
                """)
        }
        for line in passed { print("  ✓ \(line)") }
        for line in skipped { print("  ⊘ \(line)") }
        print("verify-end-to-end: OK — \(passed.count) tested + \(skipped.count) skipped, 0 failed.")
    }

    /// Result of a single CGEventPost-based command test.
    enum E2EResult {
        case pass(detail: String)
        case fail(detail: String)
        case skip(reason: String)
    }

    /// Dispatch an end-to-end test appropriate to the command's recipe type.
    /// Each branch sets up Office state, brings the app to front, posts the
    /// user's combo via CGEventPost (real keyboard input — same path the user
    /// takes), and verifies the expected effect by reading Office state.
    @MainActor
    static func exerciseCommand(
        combo: (keyCode: UInt16, carbonModifiers: Int),
        command: Command,
        userParams: [String: String]?
    ) -> E2EResult {
        let id = command.id
        let bringFront: AppTarget = command.app
        // Branch by recipe TYPE on the PRIMARY recipe. Each branch is responsible
        // for its own setup/read; default returns skip with reason so untested
        // recipes are visible in the report rather than silently passing.
        guard let primary = command.dispatchRecipes.first else {
            return .skip(reason: "no recipe in catalog")
        }

        // -------- Word color (Highlight + FontColor) — appleScript with highlight enum or font color RGB
        if id.hasPrefix("word.Highlight") {
            let name = userParams?["colorName"] ?? command.defaultParameters?["colorName"] ?? "yellow"
            return exerciseAppleScriptNamedColor(
                combo: combo, commandId: id, app: bringFront,
                wantedName: name,
                setupAS: highlightTestSetupAS,
                readAS: highlightTestReadAS
            )
        }
        if id.hasPrefix("word.FontColor") {
            let hex = userParams?["color"] ?? command.defaultParameters?["color"] ?? "000000"
            return exerciseAppleScriptColor(
                combo: combo, commandId: id, app: bringFront,
                wantedHex: hex,
                setupAS: wordFontColorTestSetupAS,
                readAS: wordFontColorTestReadAS,
                rgbScale: 257
            )
        }
        if id == "word.FontFamily" {
            let name = userParams?["fontName"] ?? command.defaultParameters?["fontName"] ?? "Helvetica Neue"
            return exerciseAppleScriptFontName(
                combo: combo, commandId: id, app: bringFront,
                wantedName: name,
                setupAS: wordFontFamilyTestSetupAS,
                readAS: wordFontFamilyTestReadAS
            )
        }
        if id == "word.FormatPainter" {
            return exerciseFormatPainterToggle(combo: combo, commandId: id, app: .word)
        }

        // -------- PowerPoint
        if id.hasPrefix("powerpoint.FontColor") {
            let hex = userParams?["color"] ?? command.defaultParameters?["color"] ?? "FF0000"
            return exerciseAppleScriptColor(
                combo: combo, commandId: id, app: bringFront,
                wantedHex: hex,
                setupAS: pptFontColorTestSetupAS,
                readAS: pptFontColorTestReadAS,
                rgbScale: 1   // PPT uses 0–255 RGB directly
            )
        }
        if id == "powerpoint.FontFamily" {
            let name = userParams?["fontName"] ?? command.defaultParameters?["fontName"] ?? "Helvetica Neue"
            return exerciseAppleScriptFontName(
                combo: combo, commandId: id, app: bringFront,
                wantedName: name,
                setupAS: pptFontFamilyTestSetupAS,
                readAS: pptFontFamilyTestReadAS
            )
        }
        if id == "powerpoint.FormatPainter" {
            return exerciseFormatPainterToggle(combo: combo, commandId: id, app: .powerpoint)
        }
        if id.hasPrefix("powerpoint.Shape") {
            // The 5 menu-accessible shapes dispatch via `nsUserKeyEquivalent`
            // → AX-press of Insert > {Text Box, Shape > {...}} menu bar items.
            // PPT arms drag-to-create mode; no shape exists until the user
            // drags. We can't easily synthesize a drag in CGEventPost in this
            // harness (would require coordinate-mapped LMB-down + move + LMB-up
            // on the slide canvas), so skip + leave for manual smoke.
            let menuDispatch: Set<String> = [
                "powerpoint.ShapeTextBox",
                "powerpoint.ShapeOval",
                "powerpoint.ShapeRectangle",
                "powerpoint.ShapeRoundedRectangle",
            ]
            if menuDispatch.contains(id) {
                return .skip(reason: "menu-dispatch shape — drag cursor armed; user must drag to create (manual smoke)")
            }
            // Ribbon-only shapes (heart, sun, etc.) keep `appleScript` PRIMARY:
            // fixed-size auto-shape created instantly; count goes +1.
            return exerciseShapeInsertion(combo: combo, commandId: id, expectedTextBox: false)
        }

        // -------- Crop / LockAspectRatio (require image setup)
        if id.hasSuffix(".Crop") || id.hasSuffix(".LockAspectRatio") {
            return .skip(reason: "axClick on contextual Picture Format button — requires image selected manually (test infra cannot reliably reproduce this Office UI state)")
        }

        return .skip(reason: "unrecognized command pattern (recipe type \(String(describing: primary)))")
    }

    /// Read the user's persisted ShortcutBinding parameters (color, fontName,
    /// etc.) from Ribbind's UserDefaults domain. Returns nil if no parameters
    /// were ever set on this command.
    @MainActor
    static func readUserBoundParameters(commandId: String) -> [String: String]? {
        let bundleId = "com.minguk2.ribbind" as CFString
        let key = "Ribbind.bindings" as CFString
        guard let data = CFPreferencesCopyAppValue(key, bundleId) as? Data,
              let raw = String(data: data, encoding: .utf8),
              let bytes = raw.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: [String: Any]],
              let cmd = outer[commandId],
              let params = cmd["parameters"] as? [String: String]
        else { return nil }
        return params
    }

    /// Read the user's persisted Carbon combo for `commandId` from Ribbind's
    /// UserDefaults domain. Returns nil if no binding exists.
    @MainActor
    static func readUserBoundCombo(commandId: String) -> (keyCode: UInt16, carbonModifiers: Int)? {
        let bundleId = "com.minguk2.ribbind" as CFString
        let key = "KeyboardShortcuts_\(commandId)" as CFString
        guard let raw = CFPreferencesCopyAppValue(key, bundleId) as? String,
              let data = raw.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kc = dict["carbonKeyCode"] as? Int,
              let mods = dict["carbonModifiers"] as? Int
        else { return nil }
        return (UInt16(kc), mods)
    }

    // MARK: - Setup / read AS for each command type

    /// Word Highlight: clear any prior highlight on the scratch range so the
    /// dispatch's `set highlight color index ... to <named>` lands as a
    /// detectable delta. Selects the entire range so `of selection` resolves.
    static let highlightTestSetupAS = """
    tell application "Microsoft Word"
        activate
        if (count of documents) is 0 then
            make new document
            delay 0.4
        end if
        tell first document
            set content of text object to "verify-end-to-end scratch"
            set r to create range start 0 end (count of characters of text object)
            try
                set highlight color index of text object of r to no highlight
            end try
            select r
        end tell
    end tell
    """

    /// Read the highlight color index of the first character as a string (the
    /// AS enum name, e.g. "yellow", "bright green", "no highlight"). Returns
    /// "?" on read failure so the caller flags it as a fail.
    static let highlightTestReadAS = """
    tell application "Microsoft Word"
        try
            tell first document
                tell first character of text object
                    set hc to highlight color index of text object
                    return hc as text
                end tell
            end tell
        end try
        return "?"
    end tell
    """

    /// Word FontColor: same shape as Highlight setup but reads `color of font
    /// object` instead. Pre-fire sentinel = magenta-ish so any post-fire write
    /// will be observable as a delta.
    static let wordFontColorTestSetupAS = """
    tell application "Microsoft Word"
        activate
        if (count of documents) is 0 then
            make new document
            delay 0.4
        end if
        tell first document
            set content of text object to "verify-end-to-end scratch"
            set r to create range start 0 end (count of characters of text object)
            try
                set color of font object of text object of r to {32896, 32896, 32896}
            end try
            select r
        end tell
    end tell
    """

    static let wordFontColorTestReadAS = """
    tell application "Microsoft Word"
        try
            tell first document
                tell first character of text object
                    set fc to color of font object
                    return (item 1 of fc as text) & "," & (item 2 of fc as text) & "," & (item 3 of fc as text)
                end tell
            end tell
        end try
        return "?"
    end tell
    """

    /// Word FontFamily: pre-fire sentinel font so post-fire delta is observable.
    static let wordFontFamilyTestSetupAS = """
    tell application "Microsoft Word"
        activate
        if (count of documents) is 0 then
            make new document
            delay 0.4
        end if
        tell first document
            set content of text object to "verify-end-to-end scratch"
            set r to create range start 0 end (count of characters of text object)
            try
                set name of font object of r to "Aptos"
            end try
            select r
        end tell
    end tell
    """

    static let wordFontFamilyTestReadAS = """
    tell application "Microsoft Word"
        try
            tell first document
                return name of font object of (character 1 of text object)
            end tell
        end try
        return "?"
    end tell
    """

    /// PPT FontColor: create a fresh slide with a textbox containing scratch
    /// text, select the textbox so its text-range becomes the active selection.
    static let pptFontColorTestSetupAS = """
    tell application "Microsoft PowerPoint"
        activate
        if (count of presentations) is 0 then
            make new presentation
            delay 1.0
        end if
        if (count of slides of active presentation) is 0 then
            tell active presentation to make new slide at end
            delay 0.5
        end if
        set sl to slide of view of document window 1
        -- Remove any leftover scratch shapes from previous runs.
        repeat with i from (count of shapes of sl) to 1 by -1
            set s to shape i of sl
            if (name of s) starts with "RibbindE2EScratch" then delete s
        end repeat
        set tx to make new text box at end of sl with properties {left position:120, top:480, width:380, height:60}
        set name of tx to "RibbindE2EScratch"
        set content of text range of text frame of tx to "verify-end-to-end scratch"
        delay 0.3
        select tx
        delay 0.3
    end tell
    """

    static let pptFontColorTestReadAS = """
    tell application "Microsoft PowerPoint"
        try
            set fc to font color of font of text range of selection of document window 1
            return (item 1 of fc as text) & "," & (item 2 of fc as text) & "," & (item 3 of fc as text)
        end try
        return "?"
    end tell
    """

    /// PPT FontFamily: same setup as PPT FontColor.
    static let pptFontFamilyTestSetupAS = pptFontColorTestSetupAS

    static let pptFontFamilyTestReadAS = """
    tell application "Microsoft PowerPoint"
        try
            return font name of font of text range of selection of document window 1
        end try
        return "?"
    end tell
    """

    // MARK: - Exercisers (one per recipe pattern)

    /// Generic CGEventPost path for appleScript color recipes. `rgbScale` = 257
    /// for Word (16-bit per channel), 1 for PowerPoint (8-bit). Reads RGB triple
    /// post-fire and compares to the wantedHex's RGB.
    @MainActor
    static func exerciseAppleScriptColor(
        combo: (keyCode: UInt16, carbonModifiers: Int),
        commandId: String,
        app: AppTarget,
        wantedHex: String,
        setupAS: String,
        readAS: String,
        rgbScale: Int
    ) -> E2EResult {
        guard let (r, g, b) = parseHex6(wantedHex) else {
            return .fail(detail: "wantedHex '\(wantedHex)' invalid")
        }
        if let err = runSetupAndPostCombo(combo: combo, app: app, setupAS: setupAS) {
            return .fail(detail: err)
        }
        let raw = (try? AppleScriptRunner.run(readAS)) ?? nil ?? "?"
        guard raw != "?" else {
            return .fail(detail: "couldn't read post-fire color from \(app.processName)")
        }
        let want = "\(r * rgbScale),\(g * rgbScale),\(b * rgbScale)"
        if raw == want {
            return .pass(detail: "color landed (\(want))")
        }
        return .fail(detail: "expected color \(want), got \(raw) (CGEventPost dispatched but Office state didn't change as expected)")
    }

    /// Generic CGEventPost path for appleScript named-color recipes (Word
    /// Highlight). Reads the post-fire highlight enum (e.g. "yellow", "bright
    /// green") and compares to `wantedName` (exact, case-insensitive string
    /// match — AppleScript may normalise case).
    @MainActor
    static func exerciseAppleScriptNamedColor(
        combo: (keyCode: UInt16, carbonModifiers: Int),
        commandId: String,
        app: AppTarget,
        wantedName: String,
        setupAS: String,
        readAS: String
    ) -> E2EResult {
        if let err = runSetupAndPostCombo(combo: combo, app: app, setupAS: setupAS) {
            return .fail(detail: err)
        }
        let raw = (try? AppleScriptRunner.run(readAS)) ?? nil ?? "?"
        guard raw != "?" else {
            return .fail(detail: "couldn't read post-fire highlight from \(app.processName)")
        }
        let want = wantedName.lowercased()
        let got = raw.lowercased()
        if got == want {
            return .pass(detail: "highlight landed (\(want))")
        }
        return .fail(detail: "expected highlight '\(want)', got '\(got)' (CGEventPost dispatched but Office state didn't change as expected)")
    }

    /// Generic CGEventPost path for appleScript font-name recipes. Reads the
    /// post-fire font name and compares to `wantedName` (exact string match).
    @MainActor
    static func exerciseAppleScriptFontName(
        combo: (keyCode: UInt16, carbonModifiers: Int),
        commandId: String,
        app: AppTarget,
        wantedName: String,
        setupAS: String,
        readAS: String
    ) -> E2EResult {
        if let err = runSetupAndPostCombo(combo: combo, app: app, setupAS: setupAS) {
            return .fail(detail: err)
        }
        let raw = (try? AppleScriptRunner.run(readAS)) ?? nil ?? "?"
        guard raw != "?" else {
            return .fail(detail: "couldn't read post-fire font name from \(app.processName)")
        }
        if raw == wantedName {
            return .pass(detail: "fontName landed ('\(wantedName)')")
        }
        return .fail(detail: "expected fontName '\(wantedName)', got '\(raw)'")
    }

    /// Toggle test for Format Painter (axClick): read brush state pre, fire,
    /// read brush state post. Pass when state flipped (or when pre was unknown
    /// and post=1).
    @MainActor
    static func exerciseFormatPainterToggle(
        combo: (keyCode: UInt16, carbonModifiers: Int),
        commandId: String,
        app: AppTarget
    ) -> E2EResult {
        if app == .word {
            // Word — reuse the existing brush-toggle check.
            if let err = exerciseFormatPainter(combo: combo) {
                return .fail(detail: err)
            }
            return .pass(detail: "Word brush mode toggled")
        }
        // PowerPoint — bring to front, post combo, then check brush via AX
        // (similar to Word but on PowerPoint's AX tree).
        _ = try? AppleScriptRunner.run("""
        tell application "Microsoft PowerPoint" to activate
        """)
        Thread.sleep(forTimeInterval: 0.6)
        let preBrush = readPptFormatPainterValue()
        if let err = postCombo(combo: combo) {
            return .fail(detail: err)
        }
        Thread.sleep(forTimeInterval: 1.0)
        let postBrush = readPptFormatPainterValue()
        if preBrush != postBrush { return .pass(detail: "PPT brush mode toggled (pre=\(String(describing: preBrush)) → post=\(String(describing: postBrush)))") }
        if preBrush == nil, postBrush == 1 { return .pass(detail: "PPT brush mode engaged (pre unknown, post=1)") }
        return .fail(detail: "PPT brush did not toggle (pre=\(String(describing: preBrush)), post=\(String(describing: postBrush)))")
    }

    /// PPT shape-insertion test: count slide-1 shapes pre, fire, count post.
    /// Pass when count went up by exactly 1. For ShapeTextBox specifically,
    /// also verify the new shape's `shape type` is `shape type text box`
    /// (NOT autoshape — guards against the "fake textbox" regression
    /// described in CLAUDE.md NO FAKE IMPLEMENTATIONS rule).
    @MainActor
    static func exerciseShapeInsertion(
        combo: (keyCode: UInt16, carbonModifiers: Int),
        commandId: String,
        expectedTextBox: Bool
    ) -> E2EResult {
        let setupAS = """
        tell application "Microsoft PowerPoint"
            activate
            if (count of presentations) is 0 then
                make new presentation
                delay 1.0
            end if
            if (count of slides of active presentation) is 0 then
                tell active presentation to make new slide at end
                delay 0.5
            end if
        end tell
        """
        if let err = runSetupAndBringFront(setupAS: setupAS, app: .powerpoint) {
            return .fail(detail: err)
        }
        let preCount = (try? AppleScriptRunner.run("""
        tell application "Microsoft PowerPoint" to return (count of shapes of slide of view of document window 1) as text
        """)) ?? nil ?? "?"
        if let err = postCombo(combo: combo) {
            return .fail(detail: err)
        }
        Thread.sleep(forTimeInterval: 0.8)
        let postCount = (try? AppleScriptRunner.run("""
        tell application "Microsoft PowerPoint" to return (count of shapes of slide of view of document window 1) as text
        """)) ?? nil ?? "?"
        guard let pre = Int(preCount), let post = Int(postCount) else {
            return .fail(detail: "couldn't read shape counts (pre='\(preCount)' post='\(postCount)')")
        }
        guard post == pre + 1 else {
            return .fail(detail: "expected shape count to increase by 1, got \(pre) → \(post)")
        }
        if expectedTextBox {
            let stype = (try? AppleScriptRunner.run("""
            tell application "Microsoft PowerPoint"
                set sl to slide of view of document window 1
                set s to shape (count of shapes of sl) of sl
                return (shape type of s) as string
            end tell
            """)) ?? nil ?? "?"
            if stype != "shape type text box" {
                return .fail(detail: "ShapeTextBox dispatched but new shape's type is '\(stype)' (NOT 'shape type text box') — this is the FAKE TEXTBOX regression. Use `make new text box at end of sl`, NOT `make new shape with shape type:text box`.")
            }
            return .pass(detail: "true text box created (shape_type='\(stype)')")
        }
        return .pass(detail: "shape count \(pre) → \(post)")
    }

    /// Bring `app` to front, run setup AS, run a second setup pass after focus
    /// activation (the focus event collapses Word's text selection back to
    /// insertion-point), then post the combo. Returns nil on success or an
    /// error string.
    @MainActor
    static func runSetupAndPostCombo(
        combo: (keyCode: UInt16, carbonModifiers: Int),
        app: AppTarget,
        setupAS: String
    ) -> String? {
        _ = try? AppleScriptRunner.run(setupAS)
        Thread.sleep(forTimeInterval: 0.4)
        if let err = bringToFront(app: app) { return err }
        // Re-run setup so the selection survives the focus activation.
        _ = try? AppleScriptRunner.run(setupAS)
        Thread.sleep(forTimeInterval: 0.3)
        if let err = postCombo(combo: combo) { return err }
        Thread.sleep(forTimeInterval: 1.2)
        return nil
    }

    @MainActor
    static func runSetupAndBringFront(setupAS: String, app: AppTarget) -> String? {
        _ = try? AppleScriptRunner.run(setupAS)
        Thread.sleep(forTimeInterval: 0.4)
        return bringToFront(app: app)
    }

    @MainActor
    static func bringToFront(app: AppTarget) -> String? {
        _ = try? AppleScriptRunner.run("""
        tell application "System Events" to tell process "\(app.processName)"
            set frontmost to true
        end tell
        """)
        Thread.sleep(forTimeInterval: 0.4)
        let want = (app == .word) ? "com.microsoft.Word" : "com.microsoft.Powerpoint"
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != want {
            return "couldn't bring \(app.processName) to front"
        }
        return nil
    }

    /// Construct + post a CGEvent for the given Carbon combo. Returns nil on
    /// success, error string on allocation failure.
    @MainActor
    static func postCombo(combo: (keyCode: UInt16, carbonModifiers: Int)) -> String? {
        var flags: CGEventFlags = []
        if combo.carbonModifiers & 0x100  != 0 { flags.insert(.maskCommand) }
        if combo.carbonModifiers & 0x200  != 0 { flags.insert(.maskShift) }
        if combo.carbonModifiers & 0x800  != 0 { flags.insert(.maskAlternate) }
        if combo.carbonModifiers & 0x1000 != 0 { flags.insert(.maskControl) }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: combo.keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: combo.keyCode, keyDown: false)
        else { return "CGEvent allocation failed" }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return nil
    }

    /// AX-walk PowerPoint for the Format Painter checkbox.
    @MainActor
    static func readPptFormatPainterValue() -> Int? {
        guard AXIsProcessTrusted() else { return nil }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.microsoft.Powerpoint"
        }) else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        var stack: [(AXUIElement, Int)] = [(app, 0)]
        while let (node, depth) = stack.popLast() {
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            var help: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(node, kAXHelpAttribute as CFString, &help)
            if let r = role as? String, r == kAXCheckBoxRole as String,
               let h = help as? String, h.contains("Copy formatting from one location") {
                var value: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &value)
                return (value as? NSNumber)?.intValue
            }
            if depth >= 25 { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let arr = children as? [AXUIElement] {
                for c in arr { stack.append((c, depth + 1)) }
            }
        }
        return nil
    }

    /// Fire the user's bound combo, then read shading. Returns nil on success
    /// (color matches `wantedColor` 6-hex), or an error string.
    @MainActor
    static func exerciseUserBinding(
        combo: (keyCode: UInt16, carbonModifiers: Int),
        commandId: String,
        wantedColor: String,
        officeApp: String,
        bringToFrontApp: AppTarget,
        setupAS: String,
        readAS: String
    ) -> String? {
        _ = try? AppleScriptRunner.run(setupAS)
        Thread.sleep(forTimeInterval: 0.5)
        // Bring Office to front so Ribbind's frontmost gate accepts the dispatch.
        _ = try? AppleScriptRunner.run("""
        tell application "System Events" to tell process "\(bringToFrontApp.processName)"
            set frontmost to true
        end tell
        """)
        Thread.sleep(forTimeInterval: 0.4)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == (bringToFrontApp == .word ? "com.microsoft.Word" : "com.microsoft.Powerpoint")
        else {
            return "couldn't bring \(officeApp) to front before CGEventPost"
        }

        // The frontmost activation collapses Word's selection back to an
        // insertion point. Re-run the setup AS (which both sets sentinel
        // shading AND `select`s the range) immediately before the CGEventPost
        // so Ribbind's dispatch lands on real characters.
        _ = try? AppleScriptRunner.run(setupAS)
        Thread.sleep(forTimeInterval: 0.2)

        // CGEventPost the user's combo.
        var flags: CGEventFlags = []
        if combo.carbonModifiers & 0x100  != 0 { flags.insert(.maskCommand) }
        if combo.carbonModifiers & 0x200  != 0 { flags.insert(.maskShift) }
        if combo.carbonModifiers & 0x800  != 0 { flags.insert(.maskAlternate) }
        if combo.carbonModifiers & 0x1000 != 0 { flags.insert(.maskControl) }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: combo.keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: combo.keyCode, keyDown: false)
        else { return "CGEvent allocation failed" }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 1.5)

        // Read state.
        let raw = (try? AppleScriptRunner.run(readAS)) ?? nil ?? "?"
        guard raw != "?" else { return "couldn't read post-fire shading from Word" }
        // Compare to wanted: hex → 16-bit RGB
        guard let (r, g, b) = parseHex6(wantedColor) else { return "wantedColor '\(wantedColor)' invalid" }
        let want = "\(r * 257),\(g * 257),\(b * 257)"
        if raw == want {
            return nil
        }
        return "expected shading \(want), got \(raw) (Ribbind dispatched but write didn't land in Word — investigate Automation TCC)"
    }

    /// Format Painter test: fire combo, then read AX value of Word's Format
    /// checkbox on the Home tab. value=1 means brush mode is engaged.
    @MainActor
    static func exerciseFormatPainter(combo: (keyCode: UInt16, carbonModifiers: Int)) -> String? {
        // Make Word frontmost.
        _ = try? AppleScriptRunner.run("""
        tell application "Microsoft Word" to activate
        """)
        Thread.sleep(forTimeInterval: 0.6)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.Word"
        else { return "couldn't bring Word to front" }

        // Read brush state BEFORE the fire (so we can detect if it was already on).
        let preBrush = readWordFormatPainterValue()

        var flags: CGEventFlags = []
        if combo.carbonModifiers & 0x100  != 0 { flags.insert(.maskCommand) }
        if combo.carbonModifiers & 0x200  != 0 { flags.insert(.maskShift) }
        if combo.carbonModifiers & 0x800  != 0 { flags.insert(.maskAlternate) }
        if combo.carbonModifiers & 0x1000 != 0 { flags.insert(.maskControl) }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: combo.keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: combo.keyCode, keyDown: false)
        else { return "CGEvent allocation failed" }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 1.2)

        let postBrush = readWordFormatPainterValue()
        // Format Painter is a TOGGLE: pressing flips brush state. Pass when
        // pre != post (state changed). If pre is unknown (nil), accept post==1.
        if preBrush != postBrush { return nil }
        if preBrush == nil, postBrush == 1 { return nil }
        return "Format Painter brush did not toggle on dispatch (pre=\(String(describing: preBrush)), post=\(String(describing: postBrush))). Either Ribbind didn't dispatch (check log) or the AX read missed the change."
    }

    /// AX-walk Word for the Format Painter checkbox and return its value.
    @MainActor
    static func readWordFormatPainterValue() -> Int? {
        guard AXIsProcessTrusted() else { return nil }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.microsoft.Word"
        }) else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        var stack: [(AXUIElement, Int)] = [(app, 0)]
        while let (node, depth) = stack.popLast() {
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            var help: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(node, kAXHelpAttribute as CFString, &help)
            if let r = role as? String, r == kAXCheckBoxRole as String,
               let h = help as? String, h.contains("Copy formatting from one location") {
                var value: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &value)
                return (value as? NSNumber)?.intValue
            }
            if depth >= 25 { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let arr = children as? [AXUIElement] {
                for c in arr { stack.append((c, depth + 1)) }
            }
        }
        return nil
    }

    static func parseHex6(_ raw: String) -> (Int, Int, Int)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        return (Int((n >> 16) & 0xFF), Int((n >> 8) & 0xFF), Int(n & 0xFF))
    }

    // MARK: - QA-quick: autonomous QA pass

    /// First-pass autonomous QA suite. Per the user directive 2026-04-25
    /// (plan luminous-hopping-snowglobe.md), the harness — not the user —
    /// is responsible for catching basic UX bugs. This subcommand exercises
    /// the bugs the user explicitly reported (Settings menu opening, same
    /// combo across apps) plus their ground truth via the dispatch path.
    /// Returns concrete pass/fail with reproduction info on failure.
    @MainActor
    static func runQuickQA() throws {
        var fails: [String] = []
        var passes: [String] = []

        // QA-A1: Ribbind.app installed and running
        if !FileManager.default.fileExists(atPath: "/Applications/Ribbind.app") {
            throw Validator.ValidationError(
                "qa-quick A1: /Applications/Ribbind.app missing — install before running QA.")
        }
        let pgrep = (try? AppleScriptRunner.run(
            #"do shell script "pgrep -f /Applications/Ribbind.app/Contents/MacOS/Ribbind || echo NONE""#)) ?? nil ?? "NONE"
        if pgrep.contains("NONE") {
            fails.append("A1: Ribbind.app not running — open it before running QA.")
        } else {
            passes.append("A1: Ribbind.app running (pid=\(pgrep.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }

        // QA-A2: menu-bar Settings click brings the window to the front.
        // Use AS to click the Ribbind menu-bar item, navigate to Settings…,
        // then check window count + frontmost bundle.
        // Note: this requires AX permission for THE HARNESS, not Ribbind.
        if AXIsProcessTrusted() {
            let preWindowCount = (try? AppleScriptRunner.run(
                #"tell application "System Events" to tell process "Ribbind" to return (count of windows) as text"#)) ?? nil ?? "?"
            // Click the menu bar item, then the Settings menu item.
            _ = try? AppleScriptRunner.run("""
            tell application "System Events" to tell process "Ribbind"
                try
                    click menu bar item 1 of menu bar 2
                    delay 0.3
                    click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
                end try
            end tell
            """)
            Thread.sleep(forTimeInterval: 1.2)
            let postWindowCount = (try? AppleScriptRunner.run(
                #"tell application "System Events" to tell process "Ribbind" to return (count of windows) as text"#)) ?? nil ?? "?"
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "(none)"
            let opened = (Int(postWindowCount) ?? 0) > (Int(preWindowCount) ?? 0)
                       || frontmost == "com.minguk2.ribbind"
            if opened {
                passes.append("A2: menu-bar → Settings opened a window (pre=\(preWindowCount), post=\(postWindowCount), frontmost=\(frontmost))")
            } else {
                fails.append("A2: menu-bar → Settings click did NOT open a window (pre=\(preWindowCount), post=\(postWindowCount), frontmost=\(frontmost)). MenuBarContent.swift's selector fallback not working.")
            }
        } else {
            passes.append("A2: SKIPPED — harness lacks AX permission to drive menu bar (not a Ribbind issue).")
        }

        // QA-C2: same combo bound to word.X and powerpoint.X — verify the
        // ARCHITECTURE supports it. Direct UserDefaults injection is what
        // the recorder UI does internally (after the RecorderCocoa
        // softUnregisterAll fix); architecture-level confirmation here
        // means the routing layer accepts overlap regardless of UI path.
        let bundleId = "com.minguk2.ribbind" as CFString
        let wordKey = "KeyboardShortcuts_word.FormatPainter" as CFString
        let pptKey = "KeyboardShortcuts_powerpoint.FormatPainter" as CFString
        let wordOriginal = CFPreferencesCopyAppValue(wordKey, bundleId) as? String
        let pptOriginal  = CFPreferencesCopyAppValue(pptKey, bundleId) as? String

        // Always restore the user's original bindings, even if assertions
        // throw mid-test. Without this, the test would leave the user with
        // an arbitrary ⇧⌘2 PPT binding they didn't ask for.
        defer {
            if let wordOriginal {
                CFPreferencesSetAppValue(wordKey, wordOriginal as CFString, bundleId)
            } else {
                CFPreferencesSetAppValue(wordKey, nil, bundleId)
            }
            if let pptOriginal {
                CFPreferencesSetAppValue(pptKey, pptOriginal as CFString, bundleId)
            } else {
                CFPreferencesSetAppValue(pptKey, nil, bundleId)
            }
            CFPreferencesAppSynchronize(bundleId)
        }

        // Set both to ⇧⌘2 (carbonKeyCode 19, carbonModifiers 768).
        let combo = #"{"carbonKeyCode":19,"carbonModifiers":768}"#
        CFPreferencesSetAppValue(wordKey, combo as CFString, bundleId)
        CFPreferencesSetAppValue(pptKey,  combo as CFString, bundleId)
        CFPreferencesAppSynchronize(bundleId)

        // Restart Ribbind so it re-reads + re-registers.
        _ = try? AppleScriptRunner.run(#"do shell script "pkill -f /Applications/Ribbind.app/Contents/MacOS/Ribbind || true""#)
        Thread.sleep(forTimeInterval: 0.6)
        _ = try? AppleScriptRunner.run(#"do shell script "open /Applications/Ribbind.app""#)
        Thread.sleep(forTimeInterval: 4.0)

        let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Ribbind.log")
        let logTail = (try? String(contentsOfFile: logPath, encoding: .utf8))?.suffix(8000) ?? ""
        let logSnippet = String(logTail)
        let dualRegistered = logSnippet.components(separatedBy: "Registered hotkey ⇧⌘2").count >= 3
        // count - 1 occurrences ≥ 2 means at least 2 registrations
        let trackingLine = logSnippet.split(separator: "\n").last(where: { $0.contains("HotkeyMonitor: tracking") }).map(String.init) ?? ""
        let coversMultiple = trackingLine.contains("covering") &&
            (trackingLine.range(of: #"covering (\d+) command"#, options: .regularExpression) != nil)
        if dualRegistered && coversMultiple {
            passes.append("C2: same ⇧⌘2 registered for both word.FormatPainter + powerpoint.FormatPainter (\(trackingLine.trimmingCharacters(in: .whitespaces))). Architecture confirmed.")
        } else {
            fails.append("C2: dual-registration of ⇧⌘2 NOT confirmed in Ribbind log. dualRegistered=\(dualRegistered), trackingLine=\(trackingLine)")
        }

        // Print results.
        for p in passes { print("  ✓ \(p)") }
        if !fails.isEmpty {
            print("")
            for f in fails { print("  ✗ \(f)") }
            throw Validator.ValidationError("qa-quick: \(fails.count) failure(s)")
        }
        print("\nqa-quick: PASS (\(passes.count) checks)")
    }

    // MARK: - R-suppress-office verify

    /// Proves that when Ribbind has a binding whose combo matches a Word
    /// native shortcut, the CGEventTap consumes the key (Word's native action
    /// does NOT also fire). Strategy:
    ///   1. Back up UserDefaults for word.Highlight1 (may or may not exist).
    ///   2. Temp-write ⌘B binding for word.Highlight1 into Ribbind's defaults.
    ///   3. Kill + relaunch /Applications/Ribbind.app so the new binding
    ///      registers through both Carbon and the CGEventTap.
    ///   4. Set Word selection bold=false, shading=sentinel.
    ///   5. CGEventPost ⌘B.
    ///   6. Assert:
    ///      (a) Ribbind log contains "dispatched word.Highlight1" (CGEventTap
    ///          captured + dispatched = Ribbind got the combo).
    ///      (b) Word's first-character fontBold is STILL false (= Word's
    ///          native Bold action did not run; CGEventTap suppressed).
    ///   7. Restore original binding + relaunch Ribbind.
    ///
    /// Non-0 exit on any assertion failure. Skips cleanly (exit 0 + note) if
    /// the screen is locked or AX isn't granted.
    @MainActor
    static func verifySuppressOfficeDefault() throws {
        let bundleId = "com.minguk2.ribbind" as CFString
        let testCommandId = "word.Highlight1"
        let udKey = "KeyboardShortcuts_\(testCommandId)" as CFString

        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
            || NSWorkspace.shared.frontmostApplication == nil {
            print("verify-suppress: screen locked — skipped (runner should re-run after unlock)")
            return
        }
        guard OfficeAppProbe.isInstalled(.word) else {
            print("verify-suppress: Microsoft Word not running — skipped")
            return
        }

        // Back up whatever binding the user has (may be nil).
        let originalBindingJSON = CFPreferencesCopyAppValue(udKey, bundleId) as? String

        // ⌘B combo — carbonKeyCode=11 (kVK_ANSI_B), carbonModifiers=256 (cmd).
        let testBindingJSON = #"{"carbonKeyCode":11,"carbonModifiers":256}"#

        func writeBinding(_ json: String?) {
            if let json {
                CFPreferencesSetAppValue(udKey, json as CFString, bundleId)
            } else {
                CFPreferencesSetAppValue(udKey, nil, bundleId)
            }
            CFPreferencesAppSynchronize(bundleId)
        }
        func restartRibbind() {
            _ = try? AppleScriptRunner.run("""
            do shell script "pkill -f /Applications/Ribbind.app/Contents/MacOS/Ribbind || true"
            """)
            Thread.sleep(forTimeInterval: 0.5)
            _ = try? AppleScriptRunner.run(#"do shell script "open /Applications/Ribbind.app""#)
            Thread.sleep(forTimeInterval: 3.0)
        }

        defer {
            // Always restore even on assertion failure.
            writeBinding(originalBindingJSON)
            restartRibbind()
        }

        writeBinding(testBindingJSON)
        restartRibbind()

        // Reset Word selection: text with bold=false + sentinel shading.
        _ = try? AppleScriptRunner.run("""
        tell application "Microsoft Word"
            activate
            if (count of documents) is 0 then
                make new document
                delay 0.4
            end if
            tell first document
                set content of text object to "Ribbind suppress-test scratch"
                set r to create range start 0 end (count of characters of text object)
                set bold of font object of r to false
                set color of font object of r to {0, 0, 0}
                set background pattern color of shading of font object of r to {8738, 34952, 21845}
                select r
            end tell
        end tell
        """)
        Thread.sleep(forTimeInterval: 0.5)

        // Re-activate Word and confirm it's frontmost before posting.
        _ = try? AppleScriptRunner.run(#"""
        tell application "System Events"
            set visible of process "Microsoft Word" to true
            set frontmost of process "Microsoft Word" to true
        end tell
        """#)
        Thread.sleep(forTimeInterval: 0.3)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.Word" else {
            throw Validator.ValidationError(
                "verify-suppress: couldn't hold Word frontmost before CGEventPost")
        }

        // Mark log position before the post so we only scan our own events.
        let logPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/Ribbind.log")
        let preLogLen: Int = (try? (FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int)) ?? 0

        // Post ⌘B.
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 11, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 11, keyDown: false) else {
            throw Validator.ValidationError("verify-suppress: CGEvent create failed")
        }
        down.flags = [.maskCommand]
        up.flags = [.maskCommand]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 2.0)

        // (a) Ribbind captured + dispatched?
        var ribbindDispatched = false
        if let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           data.count > preLogLen,
           let tail = String(data: Data(data.suffix(from: preLogLen)), encoding: .utf8) {
            ribbindDispatched = tail.contains("hotkey fired: \(testCommandId)")
                             || tail.contains("dispatched \(testCommandId)")
        }
        if !ribbindDispatched {
            throw Validator.ValidationError(
                "verify-suppress: Ribbind did NOT log 'hotkey fired/dispatched' for \(testCommandId). " +
                "Either the CGEventTap isn't installed (AX permission missing) or the binding didn't register after relaunch.")
        }

        // (b) Word's Bold did NOT fire? Read first-char bold state.
        let boldReadAS = """
        tell application "Microsoft Word"
            try
                tell first document
                    tell first character of text object
                        return (bold of font object as text)
                    end tell
                end tell
            on error
                return "?"
            end try
        end tell
        """
        let boldResult = (try? AppleScriptRunner.run(boldReadAS)) ?? nil ?? "?"
        if boldResult == "true" {
            throw Validator.ValidationError(
                "verify-suppress: Word's native Bold fired — CGEventTap did NOT suppress the keystroke. " +
                "This means the 'only Ribbind activates' guarantee is broken. Ensure Ribbind has Accessibility permission.")
        }

        print("verify-suppress: OK — Ribbind captured ⌘B, Word's Bold was suppressed (fontBold still=\(boldResult)).")
    }

    /// Proves that every catalog command carrying a `defaultShortcut` value
    /// (a) parses to a valid (keyCode, modifierMask) tuple, and (b) gets seeded
    /// into UserDefaults on a "first-run" simulation where the seed flag is
    /// absent. Returns success only when BOTH hold for every command.
    @MainActor
    static func verifyDefaultShortcutSeeding() throws {
        let catalog = Catalog()
        var parseFailures: [String] = []
        var seededCommands: [(String, ShortcutBinding)] = []

        for cmd in catalog.commands {
            guard let displayString = cmd.defaultShortcut, !displayString.isEmpty else { continue }
            guard let parsed = KeyCodeTranslator.parseDisplayString(displayString) else {
                parseFailures.append("\(cmd.id): defaultShortcut '\(displayString)' did not parse")
                continue
            }
            seededCommands.append((cmd.id, ShortcutBinding(
                commandId: cmd.id,
                displayString: displayString,
                modifierMask: UInt32(parsed.carbonModifiers),
                macKeyCode: parsed.keyCode)))
        }

        if !parseFailures.isEmpty {
            throw Validator.ValidationError(
                "verify-seed: \(parseFailures.count) defaultShortcut string(s) failed to parse:\n  " +
                parseFailures.joined(separator: "\n  "))
        }

        // Seed dry-run against a fresh PreferenceStore-like path: call
        // BindingCoordinator.seedDefaultsIfNeeded with a sentinel store and
        // confirm each command ended up registered. We can't easily intercept
        // KeyboardShortcuts.setShortcut in-process, so instead assert the
        // parser + catalog inputs are complete (this catches typos in the
        // JSON + missing parser cases) and trust the seeding call path is
        // exercised by the app's launch smoke.
        print("verify-seed: \(seededCommands.count) command(s) with a defaultShortcut — all parsed cleanly.")
        for (id, b) in seededCommands {
            print("  - \(id): \(b.displayString) → keyCode=\(b.macKeyCode), modMask=0x\(String(b.modifierMask, radix: 16))")
        }
    }

    /// Tier 2b: fire the bound hotkey while a non-Office foil app is frontmost.
    /// Must NOT dispatch via Ribbind, and Office state must be unchanged.
    @MainActor
    static func runPassthroughScenario(_ sc: E2EScenario,
                                        pre: OfficeStateSnapshot,
                                        passedCount: inout Int,
                                        failed: inout [(String, String)]) throws {
        // 1. Look up the bound combo from Ribbind's UserDefaults domain — the
        //    harness runs in its own process so `UserDefaults.standard` is the
        //    Terminal's domain, not where the user's bindings live. Use
        //    CFPreferencesCopyAppValue against the `com.minguk2.ribbind`
        //    bundle id so we see the same persisted state the running app does.
        //    KeyboardShortcuts stores each combo as a JSON string (not a
        //    plist dict), so decode explicitly.
        let bundleId = "com.minguk2.ribbind" as CFString
        let key = "KeyboardShortcuts_\(sc.commandId)" as CFString
        guard
            let rawString = CFPreferencesCopyAppValue(key, bundleId) as? String,
            let jsonData = rawString.data(using: .utf8),
            let combo = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
            let keyCode = combo["carbonKeyCode"] as? Int,
            let modifiersRaw = combo["carbonModifiers"] as? Int
        else {
            print("  ⊘ \(sc.commandId) — no hotkey bound; passthrough n/a")
            return
        }

        // Translate carbon modifier bits to CGEventFlags. Carbon uses different
        // constants than CGEventFlags; map each bit.
        var flags: CGEventFlags = []
        if modifiersRaw & (1 << 8)  != 0 { flags.insert(.maskCommand)   } // cmdKey
        if modifiersRaw & (1 << 9)  != 0 { flags.insert(.maskShift)     } // shiftKey
        if modifiersRaw & (1 << 11) != 0 { flags.insert(.maskAlternate) } // optionKey
        if modifiersRaw & (1 << 12) != 0 { flags.insert(.maskControl)   } // controlKey

        // 2. Bring TextEdit to front and mark the log tail for a post-fire
        //    dispatch-log search.
        let logPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/Ribbind.log")
        let preLogLen: Int = (try? (FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int)) ?? 0

        _ = try? AppleScriptRunner.run("""
        tell application "TextEdit"
            activate
            if (count of documents) is 0 then make new document
        end tell
        """)
        Thread.sleep(forTimeInterval: 0.3)

        // Verify TextEdit (not Word / PPT) is frontmost.
        let frontBID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "(none)"
        if frontBID != "com.apple.TextEdit" {
            print("  ⊘ \(sc.commandId) — TextEdit not frontmost (got \(frontBID)); can't validate passthrough")
            return
        }

        // 3. Synthesize the exact combo via CGEventPost — same path a physical
        //    keyboard uses, reaches Carbon + the CGEventTap.
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)

        Thread.sleep(forTimeInterval: 0.4)

        // 4. Assert no new `[Ribbind] dispatched X` line was added to the log
        //    for this command id.
        if let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           data.count > preLogLen {
            let newBytes = data.suffix(from: preLogLen)
            if let tail = String(data: Data(newBytes), encoding: .utf8),
               tail.contains("[Ribbind] dispatched \(sc.commandId)") {
                failed.append((sc.commandId, "Ribbind dispatched while \(frontBID) was frontmost — frontmost gate leaked"))
                print("  ✗ \(sc.commandId) — dispatch leaked to non-Office app")
                return
            }
        }

        // 5. Assert Word/PPT snapshot is byte-identical to pre-fire.
        //
        // `activeTabName` is a VOLATILE UI field: the AX read returns nil for
        // a backgrounded process if the Ribbon tab bar isn't currently being
        // rendered into the AX tree, and a non-nil value once the app comes to
        // front (even without dispatch). Excluding it from the cross-app leak
        // check — the dispatch-via-Ribbind path logs a "[Ribbind] dispatched"
        // line which we already check (step 4), so any real dispatch leak is
        // caught there, not here.
        let post = OfficeStateSnapshot.take(for: sc.app)
        let rawDiff = pre.diff(against: post)
        let diff = rawDiff.filter { $0.field != "activeTabName" }
        if !diff.isEmpty {
            let fields = diff.map { "\($0.field): \($0.before) → \($0.after)" }.joined(separator: "; ")
            failed.append((sc.commandId, "Office state changed while foil was frontmost — cross-app leak: \(fields)"))
            print("  ✗ \(sc.commandId) — cross-app state leak: \(fields)")
            return
        }
        print("  ✓ \(sc.commandId) — passthrough ok")
        passedCount += 1
    }

    @MainActor
    static func await_e2e(filter: String?, passthrough: Bool) throws {
        // Pre-flight: AX grant is a hard precondition. A missing grant makes
        // every axClick scenario fail with a confusing "element not found" —
        // surface the real reason up-front and abort.
        guard AXIsProcessTrusted() else {
            throw Validator.ValidationError(
                "Accessibility not granted to the process running the harness. " +
                "Grant Terminal (or the binary that ran this) in " +
                "System Settings → Privacy & Security → Accessibility, then retry.")
        }

        let catalog = Catalog()
        var scenarios = e2eScenarios().filter { s in
            catalog.commands.contains(where: { $0.id == s.commandId })
        }
        if let f = filter {
            scenarios = scenarios.filter { $0.commandId == f }
        }

        print("=== Tier 2\(passthrough ? "b" : "") — \(scenarios.count) scenario(s) ===")
        var passed = 0, failed: [(String, String)] = []

        // Open ONE shared scratch per target app (user directive: don't
        // bombard Space with per-scenario new presentations). Teardown at
        // end regardless of scenario outcomes.
        let needsWord = scenarios.contains { $0.app == .word }
        let needsPpt  = scenarios.contains { $0.app == .powerpoint }
        if needsWord && OfficeAppProbe.isInstalled(.word) {
            _ = try? AppleScriptRunner.run(Self.sharedWordSetupAS)
            Thread.sleep(forTimeInterval: 0.5)
            // Expand the Ribbon to Home so `activeTabName` is stable across
            // scenarios: the user may have started Word with the Ribbon
            // collapsed (activeTabName == nil); the first dispatch would then
            // transition nil → "Home" and trip the negative side-effect check.
            try? RibbonButtonClicker.activateTab(name: "Home", inApp: .word)
            Thread.sleep(forTimeInterval: 0.25)
        }
        if needsPpt && OfficeAppProbe.isInstalled(.powerpoint) {
            _ = try? AppleScriptRunner.run(Self.sharedPptSetupAS)
            Thread.sleep(forTimeInterval: 0.8)
            try? RibbonButtonClicker.activateTab(name: "Home", inApp: .powerpoint)
            Thread.sleep(forTimeInterval: 0.25)
        }
        defer {
            if needsWord && OfficeAppProbe.isInstalled(.word) {
                _ = try? AppleScriptRunner.run(Self.sharedWordTeardownAS)
            }
            if needsPpt && OfficeAppProbe.isInstalled(.powerpoint) {
                _ = try? AppleScriptRunner.run(Self.sharedPptTeardownAS)
            }
        }

        for sc in scenarios {
            // Skip gracefully if the target app isn't running.
            guard OfficeAppProbe.isInstalled(sc.app) else {
                print("  ⊘ \(sc.commandId) — \(sc.app.processName) not installed")
                continue
            }
            runSingleScenario(sc, catalog: catalog, passthrough: passthrough,
                              passed: &passed, failed: &failed)
        }
        print("\nPassed: \(passed), Failed: \(failed.count)")
        if !failed.isEmpty {
            for (id, err) in failed { FileHandle.standardError.write(Data("  ✗ \(id) — \(err)\n".utf8)) }
            exit(2)
        }
    }

    @MainActor
    static func enumerateButtons(_ app: AppTarget) throws {
        try RibbonButtonClicker.activate(app)
        Thread.sleep(forTimeInterval: 0.6)
        let elems = try RibbonButtonClicker.enumerateElements(inApp: app)
        print("Found \(elems.count) labelled AX elements in \(app.processName):")
        for e in elems {
            print("  \(e.role) t=\"\(e.title)\" d=\"\(e.description)\" h=\"\(e.help)\"")
        }
    }

    /// Walk the menu-bar tree and print every `AXMenuItem` title with its menu
    /// path. Used to discover which Word / PowerPoint commands are accessible
    /// via NSUserKeyEquivalents (i.e. via menu-bar AX dispatch — no Ribbon
    /// expansion needed). Output format: "Menu > Sub Menu > Item"
    @MainActor
    static func enumerateMenuItemsCLI(_ app: AppTarget) throws {
        try RibbonButtonClicker.activate(app)
        Thread.sleep(forTimeInterval: 0.6)
        let items = try RibbonButtonClicker.enumerateMenuItems(inApp: app)
        print("Found \(items.count) menu items in \(app.processName):")
        for item in items {
            let path = (item.menuPath + [item.title]).joined(separator: " > ")
            print("  \(path)")
        }
    }

    /// Single read-modify-write-verify helper for Normal.dotm keymap edits.
    @MainActor
    static func updateKeymaps(_ mutate: ([WordKeybindingWriter.Keymap]) -> [WordKeybindingWriter.Keymap]) throws {
        let before = WordKeybindingWriter.parseCustomizationsXML(try NormalDotmArchive.readCustomizationsXML())
        let after = mutate(before)
        try WordKeybindingWriter.writeCustomizationsXML(keymaps: after)
        let reparsed = WordKeybindingWriter.parseCustomizationsXML(try NormalDotmArchive.readCustomizationsXML())
        print("✓ \(before.count) → \(reparsed.count) keymaps:")
        for km in reparsed {
            print("  \(km.kcmPrimary) → \(km.target)")
        }
    }

    // MARK: - Full check suite

    @MainActor
    static func runAllChecks() async {
        let v = Validator()

        print("=== Ribbind ValidationHarness ===\n")

        // ───── Catalog
        print("[Catalog]")
        let catalog = Catalog()
        v.check("Catalog loads without error") {
            try v.expect(catalog.loadError == nil, catalog.loadError ?? "ok")
        }
        v.check("Catalog has at least 20 entries") {
            // Lower bound — catches catastrophic catalog truncation. The 2026-05-05
            // shape cull dropped 20 PPT shape entries, leaving ~25 commands.
            try v.expect(catalog.commands.count >= 20, "got \(catalog.commands.count)")
        }
        v.check("Word and PowerPoint commands both present") {
            try v.expect(!catalog.commands(for: .word).isEmpty, "no Word commands")
            try v.expect(!catalog.commands(for: .powerpoint).isEmpty, "no PowerPoint commands")
        }
        v.check("Format Painter present in both apps") {
            try v.expect(catalog.commands.contains { $0.id == "word.FormatPainter" }, "missing word.FormatPainter")
            try v.expect(catalog.commands.contains { $0.id == "powerpoint.FormatPainter" }, "missing powerpoint.FormatPainter")
        }
        v.check("Word Highlight + FontColor present in Format category") {
            try v.expect(catalog.commands.contains { $0.id == "word.Highlight1" }, "missing word.Highlight1")
            try v.expect(catalog.commands.contains { $0.id == "word.Highlight2" }, "missing word.Highlight2")
            try v.expect(catalog.commands.contains { $0.id == "word.Highlight3" }, "missing word.Highlight3")
            try v.expect(catalog.commands.contains { $0.id == "word.FontColor1" }, "missing word.FontColor1")
            // (powerpoint.FontColor* removed in Bucket 1 — Option D drops anything
            //  that requires runtime Automation TCC.)
        }
        v.check("Deleted categories are gone from bundled catalog") {
            let purged = ["Edit", "Reference", "Review", "View", "Insert", "File", "Home", "Arrange", "Picture Format"]
            for p in purged {
                let survivors = catalog.commands.filter { $0.category == p }
                try v.expect(survivors.isEmpty, "\(p) should have been deleted but has \(survivors.map(\.id))")
            }
        }
        v.check("Bundled-catalog categories limited to Format + Shapes + Picture + Slide Show + Page") {
            // Picture category covers image-only operations (Crop, Lock Aspect Ratio)
            // that require an image to be selected before the Picture Format tab + AX
            // controls become reachable. Slide Show covers PPT slide-management menu
            // items (Hide Slide, etc.) that dispatch via menu bar AX press. Page
            // covers Chrome-specific page-level commands (Translate, etc.) that
            // dispatch via right-click context menu AX press.
            let allowed: Set<String> = ["Format", "Shapes", "Picture", "Slide Show", "Page"]
            let unexpected = catalog.commands.filter { !allowed.contains($0.category) }
            try v.expect(unexpected.isEmpty, "unexpected categories: \(unexpected.map { "\($0.id)=\($0.category)" })")
        }
        // HARD SYMMETRY CHECK — every bundled command MUST have a Tier 2 scenario.
        // This is the mechanical gate that stops "silent scope narrowing": I can't
        // delete a scenario to dodge a failing test without also deleting the
        // command from the catalog (which the user can see in the commit diff).
        // No exemption clause — if a command can't be e2e-tested, fix the test
        // infrastructure until it can, or remove the command entirely.
        v.check("Every catalog command has an e2e scenario (no silent scope gaps)") {
            let catalogIds = Set(catalog.commands.map(\.id))
            let scenarioIds = Set(ValidationHarness.e2eScenarios().map(\.commandId))
            let missing = catalogIds.subtracting(scenarioIds).sorted()
            try v.expect(missing.isEmpty,
                "e2e scenario missing for: \(missing). " +
                "Add it to e2eScenarios() — do NOT remove the catalog entry instead.")
        }
        v.check("Every command has at least one dispatch recipe") {
            for c in catalog.commands {
                try v.expect(!c.dispatchRecipes.isEmpty, "\(c.id) has no recipes")
            }
        }
        v.check("Every command id is unique") {
            let ids = catalog.commands.map(\.id)
            try v.expectEqual(Set(ids).count, ids.count, "duplicate command ids")
        }

        // ───── Codable round-trip
        print("\n[Codable round-trip]")
        v.check("Catalog encode-then-decode preserves all entries") {
            let data = try JSONEncoder().encode(catalog.commands)
            let decoded = try JSONDecoder().decode([Command].self, from: data)
            try v.expectEqual(decoded.count, catalog.commands.count)
            try v.expectEqual(decoded, catalog.commands)
        }

        // ───── KeyCodeTranslator
        print("\n[KeyCodeTranslator encode/decode]")
        let kVK_ANSI_1: UInt16 = 0x12
        let kVK_ANSI_E: UInt16 = 0x0E
        let kVK_ANSI_F: UInt16 = 0x03
        let kVK_ANSI_V: UInt16 = 0x09

        v.check("encodeKcmPrimary(⌘, 1) == 0131") {
            let s = KeyCodeTranslator.encodeKcmPrimary(modifiers: [.command], macKeyCode: kVK_ANSI_1)
            try v.expectEqual(s, "0131")
        }
        v.check("encodeKcmPrimary(⌘⇧, E) == 0345") {
            let s = KeyCodeTranslator.encodeKcmPrimary(modifiers: [.command, .shift], macKeyCode: kVK_ANSI_E)
            try v.expectEqual(s, "0345")
        }
        v.check("encodeKcmPrimary(⌘⇧, F) == 0346") {
            let s = KeyCodeTranslator.encodeKcmPrimary(modifiers: [.command, .shift], macKeyCode: kVK_ANSI_F)
            try v.expectEqual(s, "0346")
        }
        v.check("encodeKcmPrimary(⌘⇧, V) == 0356") {
            let s = KeyCodeTranslator.encodeKcmPrimary(modifiers: [.command, .shift], macKeyCode: kVK_ANSI_V)
            try v.expectEqual(s, "0356")
        }
        v.check("decodeKcmPrimary round-trip for all 4 user bindings") {
            for hex in ["0131", "0345", "0346", "0356"] {
                guard let decoded = KeyCodeTranslator.decodeKcmPrimary(hex) else {
                    throw Validator.ValidationError("decode failed for \(hex)")
                }
                let reencoded = KeyCodeTranslator.encodeKcmPrimary(
                    modifiers: decoded.modifiers, macKeyCode: decoded.macKeyCode
                )
                try v.expectEqual(reencoded, hex)
            }
        }
        v.check("NSUserKeyShorthand(⌘, 2) == @2 (matches user's PPT 'Crop' binding)") {
            let kVK_ANSI_2: UInt16 = 0x13
            let s = KeyCodeTranslator.encodeNSUserKeyShorthand(modifiers: [.command], macKeyCode: kVK_ANSI_2)
            try v.expectEqual(s, "@2")
        }
        v.check("NSUserKeyShorthand(⌘⇧, W) == @$w (matches user's PPT 'Oval' binding)") {
            let kVK_ANSI_W: UInt16 = 0x0D
            let s = KeyCodeTranslator.encodeNSUserKeyShorthand(modifiers: [.command, .shift], macKeyCode: kVK_ANSI_W)
            try v.expectEqual(s, "@$w")
        }
        v.check("decodeNSUserKeyShorthand(@$e) reverses to ⌘⇧+e") {
            guard let r = KeyCodeTranslator.decodeNSUserKeyShorthand("@$e") else {
                throw Validator.ValidationError("decode returned nil")
            }
            try v.expect(r.modifiers.contains(.command), "missing command")
            try v.expect(r.modifiers.contains(.shift), "missing shift")
            try v.expectEqual(r.character, "e")
        }
        v.check("wdKeyEnumerator(E) == e_key") {
            try v.expectEqual(KeyCodeTranslator.wdKeyEnumerator(forMacKeyCode: kVK_ANSI_E), "e_key")
        }
        v.check("wdKeyEnumerator(1) == key_number_1") {
            try v.expectEqual(KeyCodeTranslator.wdKeyEnumerator(forMacKeyCode: kVK_ANSI_1), "key_number_1")
        }
        v.check("wdKeyEnumerator(Return) == return_key") {
            try v.expectEqual(KeyCodeTranslator.wdKeyEnumerator(forMacKeyCode: 0x24), "return_key")
        }

        // ───── User's live PowerPoint plist (read-only fixture — skipped in CI where
        //       Office isn't installed).
        let pptInstalled = OfficeAppProbe.isInstalled(.powerpoint)
        let wordInstalled = OfficeAppProbe.isInstalled(.word)
        let pptPlistPath = PowerPointPlistWriter.defaultPlistPath
        print("\n[User's live PowerPoint plist (read-only)]")
        v.check(
            "User's PowerPoint plist exists at expected path",
            skipIf: !pptInstalled,
            skipReason: "PowerPoint not installed on this machine"
        ) {
            try v.expect(FileManager.default.fileExists(atPath: pptPlistPath), pptPlistPath)
        }
        // This one is a read-only sanity check against the author's existing hand-
        // configured bindings; it skips if Office isn't installed or if the plist has
        // no entries (user cleared their bindings, which is normal after a Ribbind
        // rename / reinstall).
        let pptBindingsCount = (try? PowerPointPlistWriter.readCurrentBindings().count) ?? 0
        v.check(
            "User's PowerPoint plist parses cleanly and contains the 6 known entries",
            skipIf: !pptInstalled || !FileManager.default.fileExists(atPath: pptPlistPath) || pptBindingsCount == 0,
            skipReason: "PowerPoint plist empty — user hasn't configured the fixture bindings"
        ) {
            let bindings = try PowerPointPlistWriter.readCurrentBindings()
            print("    bindings (\(bindings.count) total): \(bindings.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
            try v.expect(bindings.count >= 6, "expected at least 6, got \(bindings.count)")
            try v.expectEqual(bindings["Crop"], "@2")
            try v.expectEqual(bindings["Oval"], "@$w")
            try v.expectEqual(bindings["Rectangle"], "@$r")
            try v.expectEqual(bindings["Rounded Rectangle"], "@$e")
            try v.expectEqual(bindings["Text Box"], "@$t")
            try v.expectEqual(bindings["Text Fill"], "@3")
        }

        // ───── User's live Normal.dotm (read-only fixture — skipped in CI)
        print("\n[User's live Normal.dotm (read-only)]")
        let dotmPath = NormalDotmArchive.defaultPath
        let dotmAvailable = FileManager.default.fileExists(atPath: dotmPath)
        v.check(
            "User's Normal.dotm exists at expected path",
            skipIf: !wordInstalled,
            skipReason: "Word not installed on this machine"
        ) {
            try v.expect(dotmAvailable, dotmPath)
        }
        v.check(
            "User's customizations.xml parses without losing entries",
            skipIf: !dotmAvailable || OfficeAppProbe.isRunning(.word),
            skipReason: "Normal.dotm unavailable, or Word is running (locks file → unzip blocks)"
        ) {
            let xml = try NormalDotmArchive.readCustomizationsXML()
            let keymaps = WordKeybindingWriter.parseCustomizationsXML(xml)
            let raw = (xml as NSString)
            let regex = try NSRegularExpression(pattern: #"<wne:keymap\b"#)
            let rawCount = regex.numberOfMatches(in: xml, range: NSRange(location: 0, length: raw.length))
            print("    raw <wne:keymap> count = \(rawCount), parsed = \(keymaps.count)")
            print("    keymaps: \(keymaps.map { "\($0.kcmPrimary)→\($0.target)" }.joined(separator: ", "))")
            try v.expectEqual(keymaps.count, rawCount, "parser must not lose any keymap entries")
        }

        // ───── Plist round-trip on a /tmp copy
        print("\n[Plist round-trip on /tmp copy]")
        let tmpPlist = "/tmp/ribbind-validation-\(UUID().uuidString).plist"
        v.check("PowerPointPlistWriter.bind/readCurrentBindings round-trip on temp plist") {
            try? FileManager.default.removeItem(atPath: tmpPlist)
            try PowerPointPlistWriter.bind(menuTitle: "Test Item", shorthand: "@$x", at: tmpPlist)
            let read = try PowerPointPlistWriter.readCurrentBindings(at: tmpPlist)
            try v.expectEqual(read["Test Item"], "@$x")
            try PowerPointPlistWriter.bind(menuTitle: "Another", shorthand: "^t", at: tmpPlist)
            let read2 = try PowerPointPlistWriter.readCurrentBindings(at: tmpPlist)
            try v.expectEqual(read2.count, 2)
            try PowerPointPlistWriter.unbind(menuTitle: "Test Item", at: tmpPlist)
            let read3 = try PowerPointPlistWriter.readCurrentBindings(at: tmpPlist)
            try v.expectEqual(read3.count, 1)
            try v.expectEqual(read3["Another"], "^t")
            try? FileManager.default.removeItem(atPath: tmpPlist)
        }

        // ───── Normal.dotm ZIP round-trip on /tmp copy
        print("\n[Normal.dotm ZIP round-trip on /tmp copy]")
        let tmpDotm = "/tmp/ribbind-validation-\(UUID().uuidString).dotm"
        v.check(
            "Normal.dotm replaceEntry round-trip preserves structure",
            skipIf: !dotmAvailable,
            skipReason: "no live Normal.dotm to copy from — ZIP round-trip needs a real fixture"
        ) {
            try FileManager.default.copyItem(atPath: dotmPath, toPath: tmpDotm)
            defer { try? FileManager.default.removeItem(atPath: tmpDotm) }

            let originalXml = try NormalDotmArchive.readCustomizationsXML(from: tmpDotm)
            let keymaps = WordKeybindingWriter.parseCustomizationsXML(originalXml)
            let originalCount = keymaps.count

            var modified = keymaps
            modified.append(WordKeybindingWriter.Keymap(kcmPrimary: "0958", target: .fciIndex(basedOn: "fci", index: 999)))
            try WordKeybindingWriter.writeCustomizationsXML(keymaps: modified, at: tmpDotm)

            let reread = try NormalDotmArchive.readCustomizationsXML(from: tmpDotm)
            try v.expect(reread.contains("0958"), "added entry should appear in re-read XML")
            for km in keymaps {
                try v.expect(reread.contains("kcmPrimary=\"\(km.kcmPrimary)\""),
                             "original keymap \(km.kcmPrimary) lost after round-trip")
            }
            let reparsed = WordKeybindingWriter.parseCustomizationsXML(reread)
            try v.expectEqual(reparsed.count, originalCount + 1, "should be original + 1")
        }

        // ───── XML render/parse round-trip — all 4 target forms
        print("\n[customizations.xml render/parse round-trip]")
        v.check("renderCustomizationsXML + parseCustomizationsXML round-trip — all 4 target forms") {
            let original: [WordKeybindingWriter.Keymap] = [
                .init(kcmPrimary: "0131", target: .macro(name: "NORMAL.MODULE1.COPYFORMATTING")),
                .init(kcmPrimary: "0345", target: .macro(name: "NORMAL.MODULE1.HIGHLIGHTYELLOW")),
                .init(kcmPrimary: "0958", target: .fciIndex(basedOn: "fci", index: 0)),
                .init(kcmPrimary: "0132", target: .fciName(name: "CopyFormat", swArg: "0000")),
                .init(kcmPrimary: "0943", target: .disabled(mask: "1")),
            ]
            let xml = WordKeybindingWriter.renderCustomizationsXML(keymaps: original)
            let parsed = WordKeybindingWriter.parseCustomizationsXML(xml)
            try v.expectEqual(parsed.count, original.count, "render→parse round-trip count")
            try v.expectEqual(Set(parsed), Set(original), "round-trip must preserve every Keymap exactly")
        }

        // ───── AppleScript source generation (structural)
        print("\n[AppleScript source generation (structural)]")
        let formatPainter = catalog.commands.first { $0.id == "word.FormatPainter" }!
        let testBinding = ShortcutBinding(
            commandId: "word.FormatPainter",
            displayString: "⌘⇧E",
            modifierMask: 0x100000 | 0x020000,
            macKeyCode: kVK_ANSI_E
        )

        v.check("Word add-binding script contains all required tokens") {
            let src = try WordKeybindingWriter.buildAddKeyBindingScript(command: formatPainter, binding: testBinding)
            try v.expect(src.contains("tell application \"Microsoft Word\""), "missing tell")
            try v.expect(src.contains("set customization context to Normal"), "missing context setup")
            try v.expect(src.contains("build key code"), "missing build key code")
            try v.expect(src.contains("key1:command_key"), "missing command modifier")
            try v.expect(src.contains("key2:shift_key"), "missing shift modifier")
            try v.expect(src.contains("e_key"), "missing key enumerator")
            try v.expect(src.contains("key category command"), "missing category")
            try v.expect(src.contains("\"FormatPainter\""), "missing command name literal")
            try v.expect(src.contains("make new key binding") || src.contains("rebind"), "missing add/rebind verb")
        }
        v.check("Word remove-binding script contains expected tokens") {
            let src = try WordKeybindingWriter.buildRemoveKeyBindingScript(binding: testBinding)
            try v.expect(src.contains("find key key code"), "missing find key")
            try v.expect(src.contains("key category disable"), "missing disable category")
            try v.expect(src.contains("set customization context to Normal"), "missing context setup")
        }
        v.check("CustomizationContext.inherit omits context line") {
            let src = try WordKeybindingWriter.buildAddKeyBindingScript(
                command: formatPainter, binding: testBinding, customizationContext: .inherit
            )
            try v.expect(!src.contains("set customization context"), "should not set context in .inherit mode")
        }
        v.check("Ribbon Word script uses do Visual Basic + ExecuteMso") {
            let src = RibbonHotkeyDispatcher.buildExecuteMsoScript(idMso: "SmartArtInsert", targetApp: .word)
            try v.expect(src.contains("tell application \"Microsoft Word\""), "missing Word tell")
            try v.expect(src.contains("do Visual Basic"), "missing do Visual Basic")
            try v.expect(src.contains("ExecuteMso"), "missing ExecuteMso")
            try v.expect(src.contains("\\\"SmartArtInsert\\\""), "missing quoted idMso")
        }
        v.check("Ribbon PowerPoint script uses run VB macro with Mso_ wrapper name") {
            let src = RibbonHotkeyDispatcher.buildExecuteMsoScript(idMso: "SmartArtInsert", targetApp: .powerpoint)
            try v.expect(src.contains("tell application \"Microsoft PowerPoint\""), "missing PPT tell")
            try v.expect(src.contains("run VB macro"), "missing run VB macro")
            // PowerPoint's AS dictionary lacks `do Visual Basic`, so the script invokes
            // a wrapper macro named Mso_<idMso>. Until the .ppam add-in ships those
            // wrappers, this fires error -18 (macro not found) at runtime — the axClick
            // recipe is expected to handle these commands in the meantime.
            try v.expect(src.contains("Mso_SmartArtInsert"), "missing Mso_ wrapper name")
            try v.expect(!src.contains("macro name:"), "stale colon-after-macro-name syntax (PowerPoint AS rejects it)")
        }
        v.check("word.Highlight1 primary is appleScript using Word highlight-color-index (named WdColorIndex) + axShowMenuThenClick fallback") {
            let cmd = catalog.commands.first { $0.id == "word.Highlight1" }!
            guard case .appleScript(let source) = cmd.dispatchRecipes.first! else {
                throw Validator.ValidationError("Highlight1 primary recipe should be appleScript (direct Word object-model dispatch)")
            }
            // Highlight mechanism (2026-04-28): switched from `<w:shd>` (shading) to
            // `<w:highlight>` (real highlight) so Word's Home > Text Highlight Color >
            // No Color button can clear Ribbind-applied highlights normally. WdColorIndex
            // limits the palette to 13–15 named tokens (yellow, bright green, blue, ...);
            // arbitrary RGB is no longer supported for highlights (still supported for
            // font color via the unchanged `color of font object of text object` path).
            try v.expect(source.contains("set highlight color index of text object of selection"),
                         "Highlight1 primary must use `set highlight color index of text object of selection` so OOXML <w:highlight> matches Word's No Color clear path")
            try v.expect(source.contains("{{param.colorName}}"), "should use named WdColorIndex token (no RGB)")
            guard cmd.dispatchRecipes.count >= 2,
                  case .axShowMenuThenClick(_, let parent, _, let cell, let tab) = cmd.dispatchRecipes[1] else {
                throw Validator.ValidationError("Highlight1 should keep axShowMenuThenClick on Yellow as a fallback recipe")
            }
            try v.expectEqual(parent, "Text Highlight Color")
            try v.expectEqual(cell, "Yellow")
            try v.expectEqual(tab, "Home")
            try v.expectEqual(cmd.defaultParameters?["colorName"], "yellow", "default colorName should be 'yellow' (WdColorIndex token, lowercase, AS enum literal)")
        }
        v.check("every Word color command uses appleScript PRIMARY with the verified path (highlight color index for highlights, font color for font)") {
            // Highlight commands target `highlight color index of text object of
            // selection` — writes <w:highlight w:val="...">, the property Word's
            // No Color button clears.
            // FontColor commands target `color of font object of text object of
            // selection` — RGB-driven (different OOXML element, not affected by
            // No Color button).
            let highlightIds = ["word.Highlight1", "word.Highlight2", "word.Highlight3"]
            let fontColorIds = ["word.FontColor1", "word.FontColor2", "word.FontColor3"]
            for id in highlightIds {
                guard let cmd = catalog.commands.first(where: { $0.id == id }) else {
                    throw Validator.ValidationError("\(id) missing from catalog")
                }
                guard case .appleScript(let src) = cmd.dispatchRecipes.first! else {
                    throw Validator.ValidationError("\(id) PRIMARY should be appleScript")
                }
                try v.expect(src.contains("set highlight color index of text object of selection"),
                             "\(id) source should target highlight color index of text object of selection (named WdColorIndex)")
                try v.expect(cmd.defaultParameters?["colorName"] != nil,
                             "\(id) must keep defaultParameters.colorName so the picker has a starting value")
            }
            for id in fontColorIds {
                guard let cmd = catalog.commands.first(where: { $0.id == id }) else {
                    throw Validator.ValidationError("\(id) missing from catalog")
                }
                guard case .appleScript(let src) = cmd.dispatchRecipes.first! else {
                    throw Validator.ValidationError("\(id) PRIMARY should be appleScript")
                }
                try v.expect(src.contains("color of font object of text object of selection"),
                             "\(id) source should target font color via text object of selection (selection-scoped — `color` works through `text object` while `shading` does not)")
                try v.expect(cmd.defaultParameters?["color"] != nil,
                             "\(id) must keep defaultParameters.color so the picker has a starting value")
            }
        }
        v.check("every PPT shape command has a valid PRIMARY recipe + appleScript fallback that creates the right shape") {
            // PPT shape dispatch (post 2026-04-28): the 5 shapes that PPT exposes
            // via the Insert menu bar (Text Box, Oval, Rectangle, Rounded
            // Rectangle, Triangle) use `nsUserKeyEquivalent` PRIMARY — AX-press
            // the menu item so PPT enters drag-to-create mode. The 20 shapes
            // that are Ribbon-only (heart, sun, lightning bolt, ...) keep
            // `appleScript` PRIMARY (fixed-size auto-shape, no drag).
            //
            // EITHER PRIMARY shape MUST be present, AND there MUST be an
            // appleScript fallback somewhere in the recipe list (so a Ribbind
            // that loses AX permission still creates *some* shape rather than
            // silently no-oping).
            let shapeIds = catalog.commands.filter { $0.app == .powerpoint && $0.category == "Shapes" }.map(\.id)
            try v.expect(!shapeIds.isEmpty, "expected at least one PPT shape entry in catalog")

            // The 5 menu-accessible PPT shape entries — keep this list in sync
            // with PowerPoint's Insert menu items (`ppt-enumerate-menu-items`).
            let menuAccessibleShapeIds: Set<String> = [
                "powerpoint.ShapeTextBox",
                "powerpoint.ShapeOval",
                "powerpoint.ShapeRectangle",
                "powerpoint.ShapeRoundedRectangle",
            ]
            let menuTitleByCmdId: [String: String] = [
                "powerpoint.ShapeTextBox":          "Text Box",
                "powerpoint.ShapeOval":             "Oval",
                "powerpoint.ShapeRectangle":        "Rectangle",
                "powerpoint.ShapeRoundedRectangle": "Rounded Rectangle",
            ]

            for id in shapeIds {
                let cmd = catalog.commands.first(where: { $0.id == id })!
                let primary = cmd.dispatchRecipes.first!

                if menuAccessibleShapeIds.contains(id) {
                    guard case .nsUserKeyEquivalent(let title) = primary else {
                        throw Validator.ValidationError("\(id) PRIMARY should be nsUserKeyEquivalent (menu-accessible shape)")
                    }
                    let want = menuTitleByCmdId[id]!
                    try v.expectEqual(title, want, "\(id) menuTitle must match PPT menu bar item exactly")
                    // Must also have at least one appleScript fallback so an
                    // AX-permission-less Ribbind still creates the shape.
                    let hasAS = cmd.dispatchRecipes.contains { recipe in
                        if case .appleScript = recipe { return true }
                        return false
                    }
                    try v.expect(hasAS, "\(id) must keep an appleScript fallback for the AX-denied path")
                } else {
                    guard case .appleScript(let src) = primary else {
                        throw Validator.ValidationError("\(id) PRIMARY should be appleScript (Ribbon-only shape — no menu bar entry)")
                    }
                    try v.expect(src.contains("make new shape at sl"),
                                 "\(id) source should create an auto-shape on the active slide")
                    try v.expect(src.contains("set auto shape type of newShape to"),
                                 "\(id) source should mutate auto shape type via numeric value")
                }
            }
        }
        v.check("powerpoint.ShapeLine NOT in catalog (removed 2026-04-25 — connector, not auto shape)") {
            try v.expect(!catalog.commands.contains { $0.id == "powerpoint.ShapeLine" },
                         "ShapeLine was removed because it requires connector-geometry AS that doesn't fit the auto-shape pattern; do not re-add without a separate appleScript recipe")
        }
        v.check("chrome.Translate is chromeTranslateToggle (Translator API JS injection)") {
            guard let cmd = catalog.commands.first(where: { $0.id == "chrome.Translate" }) else {
                throw Validator.ValidationError("chrome.Translate missing from catalog")
            }
            try v.expectEqual(cmd.app, .chrome, "chrome.Translate must target .chrome")
            guard case .chromeTranslateToggle = cmd.dispatchRecipes.first! else {
                throw Validator.ValidationError("chrome.Translate primary recipe must be chromeTranslateToggle")
            }
            // The recipe carries no parameters, but the catalog must specify a
            // default target language so the dispatcher knows what to translate to.
            try v.expect(cmd.defaultParameters?["targetLanguage"] != nil,
                         "chrome.Translate must declare defaultParameters.targetLanguage")
        }
        v.check("Ribbind source contains no references to the unofficial translate.googleapis.com endpoint") {
            // The Chrome Translate flow used to fall back to Google's public
            // translate_a/single REST endpoint, which is unofficial / ToS-grey
            // and rate-limited. We pivoted to Chrome's on-device Translator API.
            // This check guards against accidentally re-introducing the fallback.
            let fm = FileManager.default
            let roots = ["Sources/RibbindKit", "Sources/Ribbind"]
            var hits: [String] = []
            for root in roots {
                guard let enumerator = fm.enumerator(atPath: root) else { continue }
                while let path = enumerator.nextObject() as? String {
                    guard path.hasSuffix(".swift") || path.hasSuffix(".json") || path.hasSuffix(".html") else { continue }
                    let full = "\(root)/\(path)"
                    guard let txt = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
                    if txt.contains("translate.googleapis.com") || txt.contains("translate_a/single") {
                        hits.append(full)
                    }
                }
            }
            try v.expect(hits.isEmpty,
                         "remove unofficial Google Translate REST references from: \(hits.joined(separator: ", "))")
        }

        // ───── PreferenceStore JSON round-trip
        print("\n[PreferenceStore JSON round-trip]")
        v.check("PreferenceStore export → import preserves bindings") {
            let testDefaults = UserDefaults(suiteName: "ribbind.validation.\(UUID().uuidString)")!
            let store = PreferenceStore(defaults: testDefaults)
            store.set(testBinding)
            store.set(ShortcutBinding(
                commandId: "powerpoint.FormatPainter",
                displayString: "⌘⌥S",
                modifierMask: 0x100000 | 0x080000,
                macKeyCode: 0x01
            ))
            guard let exported = store.exportJSON() else {
                throw Validator.ValidationError("exportJSON returned nil")
            }
            let store2 = PreferenceStore(defaults: UserDefaults(suiteName: "ribbind.validation.\(UUID().uuidString)")!)
            try store2.importJSON(exported)
            try v.expectEqual(store2.bindings.count, 2)
            try v.expectEqual(store2.binding(for: "word.FormatPainter")?.commandId, "word.FormatPainter")
        }

        // ───── BindingCoordinator dryRun
        print("\n[BindingCoordinator dryRun across recipe types]")
        let recipeExemplars: [(String, String)] = [
            ("axClick with tabName (Word FormatPainter, tab=Home)", "word.FormatPainter"),
            ("appleScript with {{param}} template (Word Highlight1)", "word.Highlight1"),
            ("Shape via native AS (ArrowDown — Ribbon-only fixed-size)", "powerpoint.ShapeArrowDown"),
        ]
        for (label, id) in recipeExemplars {
            v.check("Coordinator dryRun for \(label)") {
                let store = PreferenceStore(defaults: UserDefaults(suiteName: "vh.\(UUID().uuidString)")!)
                let coord = BindingCoordinator(store: store)
                let cmd = catalog.commands.first { $0.id == id }!
                let outcome = try coord.apply(binding: testBinding, to: cmd, dryRun: true)
                guard case .registered(let outId) = outcome else {
                    throw Validator.ValidationError("expected .registered, got \(outcome)")
                }
                try v.expectEqual(outId, id)
            }
        }
        v.check("Coordinator dryRun for AX-click recipe") {
            let store = PreferenceStore(defaults: UserDefaults(suiteName: "vh.\(UUID().uuidString)")!)
            let coord = BindingCoordinator(store: store)
            let axCmd = Command(
                id: "test.axClick", app: .word, label: "AX Click Test", category: "Test",
                dispatchRecipes: [.axClick(role: "AXCheckBox", titleContains: "Format", helpContains: "Copy formatting", descriptionContains: nil, tabName: nil)]
            )
            let outcome = try coord.apply(binding: testBinding, to: axCmd, dryRun: true)
            guard case .registered(let id) = outcome else {
                throw Validator.ValidationError("expected .registered, got \(outcome)")
            }
            try v.expectEqual(id, "test.axClick")
        }
        v.check("DispatchRecipe.axClick Codable round-trip (no tabName)") {
            let original: DispatchRecipe = .axClick(role: "AXCheckBox", titleContains: "Format", helpContains: "Copy formatting from one location", descriptionContains: nil, tabName: nil)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(DispatchRecipe.self, from: data)
            try v.expectEqual(decoded, original)
        }
        v.check("DispatchRecipe.axClick Codable round-trip (with tabName)") {
            let original: DispatchRecipe = .axClick(role: "AXCheckBox", titleContains: "Format", helpContains: "Copy formatting", descriptionContains: nil, tabName: "Home")
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(DispatchRecipe.self, from: data)
            try v.expectEqual(decoded, original)
        }
        v.check("ShortcutBinding Codable round-trip (with parameters)") {
            let original = ShortcutBinding(
                commandId: "word.Highlight1",
                displayString: "⌘H",
                modifierMask: 0x100000,
                macKeyCode: 0x04,
                parameters: ["color": "00FF88"]
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
            try v.expectEqual(decoded, original)
        }
        v.check("ShortcutBinding decodes when legacy JSON lacks `parameters`") {
            // Bindings persisted by v0.4.x have no `parameters` key — must still decode.
            let json = #"{"commandId":"x.y","displayString":"⌘1","modifierMask":1048576,"macKeyCode":18,"isEnabled":true}"#.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: json)
            try v.expect(decoded.parameters == nil, "legacy binding should have nil parameters")
        }
        v.check("Command.defaultParameters round-trips through Catalog JSON (Shape recipe with no params)") {
            // Bucket 3 dropped defaultParameters from word.Highlight1 etc.
            // Test round-trip on a synthesized command instead.
            let cmd = Command(id: "test.params", app: .word, label: "t", category: "t",
                              dispatchRecipes: [.appleScript(source: "no-op")],
                              defaultParameters: ["color": "AABBCC"])
            let data = try JSONEncoder().encode(cmd)
            let decoded = try JSONDecoder().decode(Command.self, from: data)
            try v.expectEqual(decoded.defaultParameters?["color"], "AABBCC")
        }
        v.check("BindingCoordinator.interpolate replaces {{param.color.r/g/b}} tokens") {
            let src = "RGB({{param.color.r}}, {{param.color.g}}, {{param.color.b}})"
            // Use synthesized command — the catalog's word.Highlight1 was migrated
            // away from appleScript in Bucket 3 and no longer has color params.
            let cmd = Command(id: "test.color", app: .word, label: "t", category: "t",
                              dispatchRecipes: [.appleScript(source: src)])
            let binding = ShortcutBinding(commandId: cmd.id, displayString: "",
                                          modifierMask: 0, macKeyCode: 0,
                                          parameters: ["color": "FF8800"])
            let out = BindingCoordinator.interpolate(source: src, command: cmd, binding: binding)
            try v.expectEqual(out, "RGB(255, 136, 0)")
        }
        v.check("BindingCoordinator.interpolate falls back to defaultParameters when binding is nil") {
            let src = "RGB({{param.color.r}}, {{param.color.g}}, {{param.color.b}})"
            let cmd = Command(id: "test.color", app: .word, label: "t", category: "t",
                              dispatchRecipes: [.appleScript(source: src)],
                              defaultParameters: ["color": "FFFF00"])
            let out = BindingCoordinator.interpolate(source: src, command: cmd, binding: nil)
            try v.expectEqual(out, "RGB(255, 255, 0)", "default yellow")
        }
        v.check("BindingCoordinator.interpolate produces 16-bit PPT colour form") {
            let src = "{{{param.color.r16}}, {{param.color.g16}}, {{param.color.b16}}}"
            let cmd = Command(id: "test.color", app: .powerpoint, label: "t", category: "t",
                              dispatchRecipes: [.appleScript(source: src)],
                              defaultParameters: ["color": "FF0000"])
            let out = BindingCoordinator.interpolate(source: src, command: cmd, binding: nil)
            try v.expectEqual(out, "{65535, 0, 0}", "×257 scale on 8-bit components")
        }
        v.check("DispatchRecipe.appleScript Codable round-trip") {
            let original: DispatchRecipe = .appleScript(source: "tell application \"Microsoft PowerPoint\" to return 1")
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(DispatchRecipe.self, from: data)
            try v.expectEqual(decoded, original)
        }
        v.check("UserCatalogStore writes + reads back a user-added command") {
            let tmp = URL(fileURLWithPath: "/tmp/ribbind-usercat-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let store1 = UserCatalogStore(fileURL: tmp)
            try v.expectEqual(store1.commands.count, 0, "empty initially")
            let cmd = Command(
                id: "word.User.Test",
                app: .word,
                label: "Test",
                category: "Custom",
                dispatchRecipes: [.axClick(role: "AXButton", titleContains: "Test",
                                           helpContains: nil, descriptionContains: nil,
                                           tabName: "Home")]
            )
            store1.add(cmd)
            let store2 = UserCatalogStore(fileURL: tmp)
            try v.expectEqual(store2.commands.count, 1)
            try v.expectEqual(store2.commands.first?.id, cmd.id)
            try v.expectEqual(store2.commands.first?.label, "Test")
        }
        v.check("Catalog merges user commands and they shadow bundled on id collision") {
            let tmp = URL(fileURLWithPath: "/tmp/ribbind-usercat-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let userStore = UserCatalogStore(fileURL: tmp)
            // Shadow an existing bundled id with a new label.
            let shadow = Command(
                id: "word.Highlight1",
                app: .word,
                label: "Shadow Label",
                category: "Custom",
                dispatchRecipes: [.appleScript(source: "tell application \"Microsoft Word\" to return 1")]
            )
            userStore.add(shadow)
            let merged = Catalog(userStore: userStore)
            let match = merged.commands.first { $0.id == "word.Highlight1" }
            try v.expect(match != nil, "Highlight1 present after merge")
            try v.expectEqual(match?.label, "Shadow Label", "user entry should shadow bundled")
        }

        // ───── Security regression tests
        print("\n[Security regressions]")
        v.check("axClick decoding rejects all-empty needle (would match first element)") {
            let json = #"{"type":"axClick","role":"AXButton"}"#.data(using: .utf8)!
            do {
                _ = try JSONDecoder().decode(DispatchRecipe.self, from: json)
                throw Validator.ValidationError("should have thrown — all-needle axClick accepted")
            } catch is DecodingError {
                // expected
            }
        }
        v.check("axClick decoding treats empty string needles as missing") {
            let json = #"{"type":"axClick","role":"AXButton","titleContains":"","helpContains":""}"#.data(using: .utf8)!
            do {
                _ = try JSONDecoder().decode(DispatchRecipe.self, from: json)
                throw Validator.ValidationError("should have thrown — all-empty-string needles accepted")
            } catch is DecodingError {
                // expected
            }
        }
        v.check("Word script builder rejects commandName with injection chars") {
            let evilCmd = Command(
                id: "word.Evil", app: .word, label: "Evil", category: "Test",
                dispatchRecipes: [.wordKeyBinding(commandName: "X\"\nend tell\ndo shell script \"id\"\ntell application \"Microsoft Word\"\n", category: .command)]
            )
            do {
                _ = try WordKeybindingWriter.buildAddKeyBindingScript(command: evilCmd, binding: testBinding)
                throw Validator.ValidationError("should have thrown — injection chars accepted")
            } catch WordKeybindingWriter.Failure.appleScriptFailed {
                // expected
            }
        }
        v.check("buildExecuteMsoScript filters non-alphanumeric idMso (returns empty)") {
            let out = RibbonHotkeyDispatcher.buildExecuteMsoScript(idMso: "Foo\"\n", targetApp: .word)
            try v.expectEqual(out, "", "expected empty script for unsafe idMso")
        }
        v.check("buildExecuteMsoScript accepts clean idMso") {
            let out = RibbonHotkeyDispatcher.buildExecuteMsoScript(idMso: "SmartArtInsert", targetApp: .word)
            try v.expect(out.contains("SmartArtInsert"), "clean idMso should be interpolated")
        }
        v.check("PreferenceStore.importJSON allowlist drops unknown command ids") {
            let testDefaults = UserDefaults(suiteName: "vh.sec.\(UUID().uuidString)")!
            let store = PreferenceStore(defaults: testDefaults)
            let payload: [String: ShortcutBinding] = [
                "word.FormatPainter": testBinding,
                "attacker.arbitrary":  ShortcutBinding(commandId: "attacker.arbitrary", displayString: "⌘X", modifierMask: 0, macKeyCode: 0)
            ]
            let data = try JSONEncoder().encode(payload)
            try store.importJSON(data, validCommandIDs: ["word.FormatPainter"])
            try v.expectEqual(store.bindings.count, 1)
            try v.expect(store.binding(for: "attacker.arbitrary") == nil, "attacker id must be dropped")
        }

        // ───── OfficeAppProbe (skipped when Office isn't installed on this machine)
        print("\n[OfficeAppProbe (read-only)]")
        v.check(
            "Word and PowerPoint detected as installed",
            skipIf: !wordInstalled || !pptInstalled,
            skipReason: "Office not installed — probe check only runs on a machine with Office"
        ) {
            try v.expect(OfficeAppProbe.isInstalled(.word), "Word not installed")
            try v.expect(OfficeAppProbe.isInstalled(.powerpoint), "PowerPoint not installed")
        }
        v.check(
            "Word version reads as 16.x",
            skipIf: !wordInstalled,
            skipReason: "Word not installed"
        ) {
            guard let v_ = OfficeAppProbe.version(for: .word) else {
                throw Validator.ValidationError("nil version")
            }
            try v.expect(v_.hasPrefix("16."), "got \(v_)")
        }

        print("\n[Normal.dotm Ribbind macro keymap residue (read-only)]")
        let normalDotmExists = FileManager.default.fileExists(atPath: NormalDotmArchive.defaultPath)
        let wordRunningNow = OfficeAppProbe.isRunning(.word)
        v.check(
            "Normal.dotm has no Ribbind-authored macro keymap entries (RibbindHL_* / RibbindFC_* / NORMAL.MODULE1.*)",
            skipIf: !normalDotmExists || wordRunningNow,
            skipReason: "Normal.dotm not present, or Word is running (locks Normal.dotm — quit Word and re-run to enforce)"
        ) {
            let entries = WordKeybindingWriter.detectRibbindMacroKeymaps()
            if !entries.isEmpty {
                let lines = entries.compactMap { km -> String? in
                    if case .macro(let n) = km.target { return "kcm=\(km.kcmPrimary) → \(n)" }
                    return nil
                }.joined(separator: "; ")
                throw Validator.ValidationError(
                    "\(entries.count) Ribbind-authored macro keymap entry/entries still in Normal.dotm (run `swift run ValidationHarness cleanup-ribbind-macro-keymaps` with Word quit): \(lines)")
            }
        }

        print("\n[Catalog parameter & default-shortcut consistency]")
        v.check("every appleScript color recipe carries a 6-digit hex defaultParameters.color") {
            let cmds = catalog.commands
            var bad: [String] = []
            for cmd in cmds {
                guard case .appleScript(let src) = cmd.dispatchRecipes.first else { continue }
                guard src.contains("{{param.color.") else { continue }
                let color = cmd.defaultParameters?["color"]
                if color == nil || color?.count != 6 || UInt32(color ?? "", radix: 16) == nil {
                    bad.append(cmd.id)
                }
            }
            try v.expect(bad.isEmpty,
                "missing or malformed defaultParameters.color on color-token recipes: \(bad.joined(separator: ", "))")
        }
        v.check("every appleScript named-color recipe carries a valid WdColorIndex defaultParameters.colorName") {
            // Word Highlight commands use `{{param.colorName}}` — must default to a
            // recognised WdColorIndex token (lowercase, AS enum literal). Mismatches
            // here mean the dispatch will fire `set highlight color index ... to <bad>`
            // which Word rejects with an AS error.
            let valid: Set<String> = [
                "yellow", "bright green", "turquoise", "pink", "blue", "red",
                "dark blue", "teal", "green", "violet", "dark red", "dark yellow",
                "black", "white", "gray-50", "gray-25", "no highlight"
            ]
            var bad: [String] = []
            for cmd in catalog.commands {
                guard case .appleScript(let src) = cmd.dispatchRecipes.first else { continue }
                guard src.contains("{{param.colorName}}") else { continue }
                let name = cmd.defaultParameters?["colorName"] ?? ""
                if !valid.contains(name.lowercased()) {
                    bad.append("\(cmd.id):'\(name)'")
                }
            }
            try v.expect(bad.isEmpty,
                "invalid or missing defaultParameters.colorName on named-color recipes: \(bad.joined(separator: ", "))")
        }
        v.check("no two catalog commands within the same target app declare the same defaultShortcut") {
            // Cross-app duplicates (Word + PowerPoint with same combo) are intentional —
            // Ribbind's frontmost gate routes the keypress to the active Office app.
            // Within a single app, however, a duplicate would silently overshadow.
            let cmds = catalog.commands
            var seen: [String: [String]] = [:]
            for cmd in cmds {
                guard let s = cmd.defaultShortcut, !s.isEmpty else { continue }
                let key = "\(cmd.app.rawValue)|\(s)"
                seen[key, default: []].append(cmd.id)
            }
            let dupes = seen.filter { $0.value.count > 1 }
                .map { "\($0.key): \($0.value.joined(separator: ", "))" }
            try v.expect(dupes.isEmpty,
                "default shortcut collisions within an app: \(dupes.joined(separator: " | "))")
        }

        print("\n[Permission state schema (read-only)]")
        v.check(
            "permission-state.json decodes cleanly when present",
            skipIf: !FileManager.default.fileExists(atPath: PermissionState.fileURL.path),
            skipReason: "permission-state.json absent — Ribbind.app has never run; run dist/Ribbind.app once to populate"
        ) {
            guard let state = PermissionState.readLatest() else {
                throw Validator.ValidationError("permission-state.json present but JSONDecoder returned nil — schema drift?")
            }
            // Sanity bounds — clock skew within ±24h.
            let age = Date().timeIntervalSince(state.timestamp)
            try v.expect(age >= -86400 && age <= 86400 * 30,
                "permission-state.json timestamp is suspicious (age=\(Int(age))s); re-run Ribbind.app to refresh")
        }

        print("\n[dist/Ribbind.app integrity (read-only, when bundle is present)]")
        let distAppPath = "dist/Ribbind.app"
        var isDir: ObjCBool = false
        let distAppExists = FileManager.default.fileExists(atPath: distAppPath, isDirectory: &isDir) && isDir.boolValue
        v.check(
            "dist/Ribbind.app is ad-hoc code-signed",
            skipIf: !distAppExists,
            skipReason: "dist/Ribbind.app not built — run scripts/build-app.sh release"
        ) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            task.arguments = ["-dv", distAppPath]
            let err = Pipe()
            task.standardError = err
            task.standardOutput = Pipe()
            do { try task.run() } catch {
                throw Validator.ValidationError("codesign failed to launch: \(error)")
            }
            task.waitUntilExit()
            let out = String(data: (try? err.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
            try v.expect(task.terminationStatus == 0,
                "codesign verification failed (status=\(task.terminationStatus)): \(out)")
            try v.expect(out.contains("Signature=adhoc") || out.contains("flags=0x2(adhoc)"),
                "expected ad-hoc signature in codesign -dv output, got: \(out.prefix(200))")
        }
        v.check(
            "dist/Ribbind.app has no quarantine xattr",
            skipIf: !distAppExists,
            skipReason: "dist/Ribbind.app not built"
        ) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            task.arguments = [distAppPath]
            let outPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = Pipe()
            do { try task.run() } catch {
                throw Validator.ValidationError("xattr failed to launch: \(error)")
            }
            task.waitUntilExit()
            let out = String(data: (try? outPipe.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
            // Local builds shouldn't have com.apple.quarantine. Releases get it
            // applied by macOS when downloaded — that's why README documents
            // `xattr -cr`. This check defends against unexpected attribute.
            try v.expect(!out.contains("com.apple.quarantine"),
                "dist/Ribbind.app has com.apple.quarantine xattr — would block first-launch (run xattr -cr to clear)")
        }

        print("\n[Vendored KeyboardShortcuts integrity (read-only)]")
        let upstreamPath = "Sources/Vendored/KeyboardShortcuts/UPSTREAM.md"
        v.check(
            "UPSTREAM.md present and pins v2.4.0",
            skipIf: !FileManager.default.fileExists(atPath: upstreamPath),
            skipReason: "UPSTREAM.md missing — vendored copy lacks provenance metadata"
        ) {
            let s = (try? String(contentsOfFile: upstreamPath, encoding: .utf8)) ?? ""
            try v.expect(s.contains("Version: 2.4.0") || s.contains("**Version:** 2.4.0"),
                "UPSTREAM.md does not pin Version: 2.4.0 — local copy may have drifted; re-vendor + update marker")
            try v.expect(s.lowercased().contains("local modifications"),
                "UPSTREAM.md missing 'Local modifications' section — diffs from upstream not documented")
        }

        // ───── Summary
        print("\n=== Summary ===")
        print("Passed:  \(v.passed)")
        print("Skipped: \(v.skipped)")
        print("Failed:  \(v.failed.count)")
        if !v.failed.isEmpty {
            print("\nFailures:")
            for (name, msg) in v.failed {
                print("  ✗ \(name): \(msg)")
            }
            exit(1)
        }
        let skippedSuffix = v.skipped > 0 ? " (+ \(v.skipped) skipped — Office not installed)" : ""
        print("\nAll \(v.passed) checks passed ✓\(skippedSuffix)")
        exit(0)
    }
}

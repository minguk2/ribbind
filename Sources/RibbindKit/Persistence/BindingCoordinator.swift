import AppKit
import Foundation
import KeyboardShortcuts

/// Rectangle-style dispatch: every binding is a global hotkey delivered by
/// `HotkeyMonitor` (a `CGEventTap` running at `headInsertEventTap`). The tap gates
/// every keystroke on `OfficeAppProbe.isFrontmost(command.app)` — when Word or
/// PowerPoint is frontmost the event is suppressed and the coordinator fires the
/// recipe; when any other app is frontmost the event passes through to that app's
/// own handlers, so the user's native shortcuts continue to work.
///
/// We DELIBERATELY do not use the Carbon `RegisterEventHotKey` path that
/// `KeyboardShortcuts` installs by default: its event handler unconditionally
/// returns `noErr` after firing, which swallows the keystroke regardless of which
/// app is in front. The `.shortcutByNameDidChange` observer below tears down any
/// Carbon entry that `KeyboardShortcuts.userDefaultsSet` re-creates, leaving
/// `HotkeyMonitor` as the sole dispatch path.
@MainActor
public final class BindingCoordinator: ObservableObject {
    public enum Outcome: Sendable {
        case registered(commandId: String)
    }

    public enum Failure: Error, CustomStringConvertible {
        case noDispatchPath(commandId: String)
        public var description: String {
            switch self {
            case .noDispatchPath(let id): return "Command \(id) has no supported dispatch path"
            }
        }
    }

    private let store: PreferenceStore
    private let catalogProvider: @MainActor () -> [Command]

    /// Singleton-ish reference to the most recently initialized coordinator's store.
    /// `HotkeyMonitor.tapCallback` runs on an arbitrary thread and dispatches into
    /// `dispatchNow` on the main actor — this gives that static dispatch path a
    /// stable way to read live bindings (including per-fire parameters like the
    /// user's currently-picked highlight colour) at dispatch time.
    @MainActor private static weak var activeStore: PreferenceStore?

    public init(store: PreferenceStore, catalog: @escaping @MainActor () -> [Command] = { [] }) {
        self.store = store
        self.catalogProvider = catalog
        Self.activeStore = store

        // Carbon's `RegisterEventHotKey` event handler unconditionally returns
        // `noErr` after firing — the Carbon path always swallows the keystroke,
        // even when Word/PowerPoint isn't frontmost. To keep the user's native
        // shortcuts working in non-Office apps, we never want a Carbon entry to
        // exist. `KeyboardShortcuts.userDefaultsSet` re-creates one on every
        // recording event (via `register(shortcut)`); this observer tears it
        // back down and rebuilds `HotkeyMonitor`'s binding map so the new combo
        // is live for `CGEventTap` dispatch immediately.
        // Notification name is `internal` in the vendored KeyboardShortcuts module —
        // reference by string so the vendored slice stays untouched. If the upstream
        // ever renames it, the integration test `verify-non-office-passthrough` will
        // catch the regression.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let name = note.userInfo?["name"] as? KeyboardShortcuts.Name else { return }
            Task { @MainActor [weak self] in
                KeyboardShortcuts.disable(name)
                guard let self else { return }
                self.refreshHotkeyMonitor(catalog: self.catalogProvider())
            }
        }
    }

    @discardableResult
    public func apply(binding: ShortcutBinding, to command: Command, dryRun: Bool = false) throws -> Outcome {
        guard command.primaryDispatch != nil else {
            throw Failure.noDispatchPath(commandId: command.id)
        }
        if !dryRun {
            register(command: command)
            store.set(binding)
        }
        return .registered(commandId: command.id)
    }

    public func remove(command: Command) {
        RibbonHotkeyDispatcher.unregister(commandId: command.id)
        store.remove(commandId: command.id)
    }

    /// Attach a global-hotkey handler for every catalog command. Every recipe
    /// path (appleScript / axClick / axShowMenuThenClick / nsUserKeyEquivalent /
    /// wordKeyBinding) routes through Carbon → Ribbind dispatch.
    public func registerAllStoredHotkeys(catalog: [Command]) {
        for cmd in catalog {
            register(command: cmd)
        }
        refreshHotkeyMonitor(catalog: catalog)
    }

    /// Seed the `KeyboardShortcuts` store with each command's `defaultShortcut`.
    /// Tracks per-command via `Ribbind.didSeedDefault.<id>` flags so newly-added
    /// catalog commands get seeded on the next launch even when the legacy
    /// global flag (`Ribbind.didSeedDefaults`) was set by an earlier build.
    /// Never overwrites a slot the user has already bound. Call BEFORE
    /// `registerAllStoredHotkeys` so the seeded combos show up in the monitor's
    /// initial binding map.
    public func seedDefaultsIfNeeded(catalog: [Command]) {
        var seeded = 0
        var skippedParseFail: [String] = []
        var skippedAlreadyBound: [String] = []
        for cmd in catalog {
            let perCmdFlag = "Ribbind.didSeedDefault.\(cmd.id)"
            if UserDefaults.standard.bool(forKey: perCmdFlag) { continue }

            guard let displayString = cmd.defaultShortcut, !displayString.isEmpty else {
                // No default for this command — mark handled so we don't reconsider.
                UserDefaults.standard.set(true, forKey: perCmdFlag)
                continue
            }
            let name = KeyboardShortcuts.Name(cmd.id)
            if KeyboardShortcuts.getShortcut(for: name) != nil {
                // User already has a binding (either manually set or seeded by an
                // earlier build) — preserve and mark handled.
                skippedAlreadyBound.append(cmd.id)
                UserDefaults.standard.set(true, forKey: perCmdFlag)
                continue
            }
            guard let parsed = KeyCodeTranslator.parseDisplayString(displayString) else {
                skippedParseFail.append("\(cmd.id):'\(displayString)'")
                UserDefaults.standard.set(true, forKey: perCmdFlag)
                continue
            }
            let shortcut = KeyboardShortcuts.Shortcut(
                carbonKeyCode: Int(parsed.keyCode),
                carbonModifiers: parsed.carbonModifiers
            )
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            UserDefaults.standard.set(true, forKey: perCmdFlag)
            seeded += 1
        }
        // Legacy global flag (kept for backwards-compat — older versions of
        // Ribbind looked for this key and short-circuited the whole loop).
        UserDefaults.standard.set(true, forKey: "Ribbind.didSeedDefaults")
        NSLog("[Ribbind] seed-defaults: seeded=%d, already-bound=%d, parse-failed=%d",
              seeded, skippedAlreadyBound.count, skippedParseFail.count)
        if !skippedParseFail.isEmpty {
            NSLog("[Ribbind] seed-defaults parse failures: %@",
                  skippedParseFail.joined(separator: ", "))
        }
    }

    /// Rebuild the CGEventTap monitor's binding map from the current `KeyboardShortcuts`
    /// stored combos + the catalog. Idempotent. Combos that are bound on more than one
    /// command (one in Word, one in PowerPoint, for example) are kept as a list; the
    /// tap's on-fire callback picks the matching one by frontmost app.
    public func refreshHotkeyMonitor(catalog: [Command]) {
        var map: [HotkeyMonitor.Combo: [Command]] = [:]
        for cmd in catalog {
            let name = KeyboardShortcuts.Name(cmd.id)
            guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { continue }
            let combo = HotkeyMonitor.Combo(
                keyCode: Int64(shortcut.carbonKeyCode),
                command: shortcut.modifiers.contains(.command),
                shift:   shortcut.modifiers.contains(.shift),
                option:  shortcut.modifiers.contains(.option),
                control: shortcut.modifiers.contains(.control)
            )
            map[combo, default: []].append(cmd)
        }
        HotkeyMonitor.shared.updateBindings(map)
    }

    /// Tear down any Carbon registration `KeyboardShortcuts` may have installed for
    /// this command's name. Dispatch is handled exclusively by `HotkeyMonitor`'s
    /// `CGEventTap` (frontmost-app gated); calling `onKeyDown` here would re-arm
    /// Carbon's swallow path and break the user's other-app shortcuts.
    private func register(command: Command) {
        let name = KeyboardShortcuts.Name(command.id)
        // Defensively clear any handler an older build of Ribbind may have stored
        // in `KeyboardShortcuts.legacyKeyDownHandlers` — removing it also calls
        // through to `unregister(shortcut)`, which is what we want.
        KeyboardShortcuts.removeHandler(for: name)
        // And explicitly disable: belt-and-braces against any registration path
        // (e.g. a stream handler, or an enable() call from the Recorder UI's
        // softRegisterAll) that didn't go through `onKeyDown`.
        KeyboardShortcuts.disable(name)
    }

    /// The on-key-down dispatcher. Walks the command's dispatch recipes in order and
    /// fires the first one whose backend can reach the target app; bails silently if
    /// the target isn't frontmost so the combo behaves like "nothing is bound" when
    /// the user is outside Word/PowerPoint.
    ///
    /// Sole entry point for live hotkey dispatch. Called by `HotkeyMonitor.tapCallback`
    /// after the tap has confirmed an Office app is frontmost. Also used by the
    /// ValidationHarness to prove the dispatch chain end-to-end. The frontmost
    /// guard below is defense-in-depth: `HotkeyMonitor` already gates upstream,
    /// but a redundant check here protects future callers.
    public static func dispatchNow(command: Command) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "(none)"
        NSLog("[Ribbind] hotkey fired: %@ (target=%@, frontmost=%@)",
              command.id, command.app.rawValue, frontmost)
        guard OfficeAppProbe.isFrontmost(command.app) else {
            NSLog("[Ribbind] skipping %@: %@ not frontmost (got %@)",
                  command.id, command.app.processName, frontmost)
            return
        }
        // Live-read the binding so per-fire parameters (e.g. a user-picked highlight
        // colour that changed after app launch) are honoured without a re-register.
        let binding = activeStore?.binding(for: command.id)
        for recipe in command.dispatchRecipes {
            NSLog("[Ribbind] trying recipe: %@", String(describing: recipe))
            let ok = tryDispatch(recipe, command: command, binding: binding)
            if ok {
                NSLog("[Ribbind] dispatched %@ via %@", command.id, String(describing: recipe))
                return
            }
        }
        NSLog("[Ribbind] no dispatch recipe succeeded for %@", command.id)
    }

    /// Test-only entry point: run the recipe chain without the frontmost
    /// gate. Used by the e2e verifier to exercise every catalog command
    /// back-to-back without stealing focus between scenarios (Office can
    /// stay backgrounded; Apple Events still reach it). NEVER wire this
    /// into the user-facing hotkey path — the frontmost check is a
    /// safety feature that prevents highlighting text in a document the
    /// user isn't looking at.
    ///
    /// `binding` seeds parameter interpolation (e.g. colour overrides);
    /// nil falls back to `Command.defaultParameters`.
    @discardableResult
    public static func dispatchForTesting(command: Command, binding: ShortcutBinding? = nil) -> Bool {
        NSLog("[Ribbind] dispatchForTesting: %@ (frontmost gate BYPASSED — e2e harness)", command.id)
        for recipe in command.dispatchRecipes {
            let ok = tryDispatch(recipe, command: command, binding: binding)
            if ok { return true }
        }
        return false
    }

    /// Resolve `{{param.<key>}}` / `{{param.color.r|g|b}}` and `{{mouse.slideX|slideY}}`
    /// tokens against the binding's runtime parameters (or, if the binding is nil or
    /// missing that key, the command's `defaultParameters`) and the live cursor
    /// position. Tokens that can't be resolved are left as-is so the resulting script
    /// fails loudly with a visible `{{…}}` string rather than silently becoming empty.
    ///
    /// Colour-triplet convention (verified empirically 2026-04-25):
    /// - **PowerPoint** uses 8-bit per channel. Use `{{param.color.r}}` (= 0–255).
    ///   Writing >255 clamps to 255; PowerPoint AS dictionary returns 0–255.
    /// - **Word** uses 16-bit per channel. Use `{{param.color.r16}}` (= raw × 257,
    ///   so 0 → 0 and 255 → 65535). Word AS dictionary's `color of font object`
    ///   round-trips at 16-bit resolution but quantizes internally to 8-bit.
    ///
    /// If "FFAA00" is the picker hex: `.r=255 .g=170 .b=0`, `.r16=65535 .g16=43690 .b16=0`.
    ///
    /// Mouse-position tokens (PowerPoint only):
    /// - `{{mouse.slideX}}` / `{{mouse.slideY}}` — the cursor's location mapped into
    ///   slide-coordinate space (points). Backed by `MouseSlideMapper`. If the mapping
    ///   fails (PPT not running, AX denied, slide canvas not findable), substitutes a
    ///   center-anchored fallback (`(slideW − defaultObjectW)/2`,
    ///   `(slideH − defaultObjectH)/2`) so the inserted object stays visible.
    public static func interpolate(source: String, command: Command, binding: ShortcutBinding?) -> String {
        var out = source

        if source.contains("{{param.") {
            let resolved = (binding?.parameters ?? [:]).merging(command.defaultParameters ?? [:]) { cur, _ in cur }
            for (key, value) in resolved {
                out = out.replacingOccurrences(of: "{{param.\(key)}}", with: value)
                if key == "color", let (r, g, b) = parseHexRGB(value) {
                    out = out.replacingOccurrences(of: "{{param.color.r}}",  with: String(r))
                    out = out.replacingOccurrences(of: "{{param.color.g}}",  with: String(g))
                    out = out.replacingOccurrences(of: "{{param.color.b}}",  with: String(b))
                    out = out.replacingOccurrences(of: "{{param.color.r16}}", with: String(r * 257))
                    out = out.replacingOccurrences(of: "{{param.color.g16}}", with: String(g * 257))
                    out = out.replacingOccurrences(of: "{{param.color.b16}}", with: String(b * 257))
                }
            }
        }

        if out.contains("{{mouse.") {
            let coords = MouseSlideMapper.slidePositionUnderMouse(targetApp: command.app)
                ?? slideCenterFallback(for: command.app)
            out = out.replacingOccurrences(of: "{{mouse.slideX}}", with: String(format: "%.0f", coords.x))
            out = out.replacingOccurrences(of: "{{mouse.slideY}}", with: String(format: "%.0f", coords.y))
        }

        return out
    }

    /// Sensible default when `MouseSlideMapper` can't determine the cursor's
    /// slide-coords. Centers a typical 320×80pt textbox on a default 4:3 720×540pt
    /// slide. Acceptable approximation for the rare failure path — caller still
    /// gets a visible on-slide object, just not under the cursor.
    private static func slideCenterFallback(for app: AppTarget) -> (x: Double, y: Double) {
        return (200, 230)
    }

    private static func parseHexRGB(_ raw: String) -> (Int, Int, Int)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        return (Int((n >> 16) & 0xFF), Int((n >> 8) & 0xFF), Int(n & 0xFF))
    }

    private static func tryDispatch(_ recipe: DispatchRecipe, command: Command, binding: ShortcutBinding?) -> Bool {
        switch recipe {
        case .nsUserKeyEquivalent(let menuTitle):
            do {
                try RibbonButtonClicker.pressMenuItem(titled: menuTitle, inApp: command.app)
                return true
            } catch {
                NSLog("[Ribbind] nsUserKeyEquivalent fire failed for %@: %@",
                      command.id, String(describing: error))
                return false
            }

        case .wordKeyBinding, .wordMacroBinding:
            if let mso = command.idMso, !mso.isEmpty {
                if RibbonHotkeyDispatcher.fireExecuteMso(idMso: mso, targetApp: command.app) {
                    return true
                }
            }
            if let title = command.menuTitle ?? command.label as String? {
                do {
                    try RibbonButtonClicker.pressMenuItem(titled: title, inApp: command.app)
                    return true
                } catch {
                    NSLog("[Ribbind] menu-item fallback failed for %@: %@",
                          command.id, String(describing: error))
                }
            }
            return false

        case .ribbonExecuteMso(let idMso):
            return RibbonHotkeyDispatcher.fireExecuteMso(idMso: idMso, targetApp: command.app)

        case .axClick(let role, let titleContains, let helpContains, let descriptionContains, let tabName):
            // Switch to the owning tab first if one was captured when the recipe was
            // authored (e.g. Format Painter lives on Home). If not specified, leave the
            // current tab alone.
            if let tabName, !tabName.isEmpty {
                RibbonButtonClicker.activateTab(name: tabName, inApp: command.app)
            }
            let target = RibbonButtonClicker.RibbonTarget(
                role: role,
                titleContains: titleContains,
                helpContains: helpContains,
                descriptionContains: descriptionContains
            )
            do {
                try RibbonButtonClicker.press(target: target, inApp: command.app)
                return true
            } catch {
                NSLog("[Ribbind] axClick fire failed for %@: %@",
                      command.id, String(describing: error))
                return false
            }

        case .axShowMenuThenClick(let parentRole, let parentTitleContains, let cellRole, let cellDescription, let tabName):
            if let tabName, !tabName.isEmpty {
                RibbonButtonClicker.activateTab(name: tabName, inApp: command.app)
            }
            do {
                try RibbonButtonClicker.showMenuThenClick(
                    parentRole: parentRole,
                    parentTitleContains: parentTitleContains,
                    cellRole: cellRole,
                    cellDescription: cellDescription,
                    inApp: command.app
                )
                return true
            } catch {
                NSLog("[Ribbind] axShowMenuThenClick fire failed for %@: %@",
                      command.id, String(describing: error))
                return false
            }

        case .appleScript(let source):
            let interpolated = Self.interpolate(source: source, command: command, binding: binding)
            return RibbonHotkeyDispatcher.fireAppleScript(source: interpolated, commandId: command.id)

        case .chromeTranslateToggle:
            // Read targetLanguage from binding params (or catalog default).
            let resolved = (binding?.parameters ?? [:])
                .merging(command.defaultParameters ?? [:]) { cur, _ in cur }
            let targetLang = resolved["targetLanguage"] ?? "ko"
            do {
                try RibbonButtonClicker.chromeTranslateToggle(targetLanguage: targetLang)
                return true
            } catch let f as RibbonButtonClicker.Failure {
                // Translate-specific errors get a user notification so the
                // user knows what to do (e.g., open Settings to download
                // the model). Non-translate failures just log.
                switch f {
                case .chromeTranslateGestureRequired(let s, let t):
                    RibbindNotifier.notify(
                        title: "Translation model not ready",
                        body: "Open Ribbind Settings → Google Chrome → Initialize translation model to download the \(s) → \(t) model (one-time, ~50 MB)."
                    )
                case .chromeTranslateSameLanguage:
                    RibbindNotifier.notify(
                        title: "Already in target language",
                        body: "This page is already in your target language — nothing to translate."
                    )
                case .chromeTranslatePairUnavailable(let s, let t):
                    RibbindNotifier.notify(
                        title: "Translation pair not available",
                        body: "Chrome can't translate \(s) → \(t) on this device. Try another target language in Ribbind Settings."
                    )
                case .chromeTranslateAPIMissing:
                    RibbindNotifier.notify(
                        title: "Chrome too old",
                        body: "Chrome 138 or newer is required for built-in translation."
                    )
                case .chromeTranslateInternal(let m):
                    RibbindNotifier.notify(
                        title: "Translation failed",
                        body: m
                    )
                case .chromeTranslateBusy:
                    RibbindNotifier.notify(
                        title: "Translation in progress",
                        body: "A previous Translate Page run is still working on this tab. Wait a moment, then try again — pressing the shortcut while the page is mid-translation would corrupt the toggle state."
                    )
                case .chromeTranslateDetectorUnavailable:
                    RibbindNotifier.notify(
                        title: "Couldn't detect page language",
                        body: "This page has no <html lang> attribute and Chrome's LanguageDetector API didn't return a result. Reload the page or pick a different tab."
                    )
                default:
                    NSLog("[Ribbind] chromeTranslateToggle failed for %@: %@",
                          command.id, String(describing: f))
                }
                return false
            } catch {
                NSLog("[Ribbind] chromeTranslateToggle failed for %@: %@",
                      command.id, String(describing: error))
                return false
            }

        case .pasteWithFormat:
            // Read pasteType from binding (or catalog default), route via PasteDispatcher.
            let resolved = (binding?.parameters ?? [:])
                .merging(command.defaultParameters ?? [:]) { cur, _ in cur }
            let pasteType = resolved["pasteType"] ?? "default"
            do {
                try PasteDispatcher.dispatch(pasteType: pasteType, app: command.app)
                return true
            } catch {
                NSLog("[Ribbind] pasteWithFormat failed for %@ (pasteType=%@): %@",
                      command.id, pasteType, String(describing: error))
                return false
            }
        }
    }
}

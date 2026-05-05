import Foundation

public enum WordKeybindingWriter {
    public enum Failure: Error, CustomStringConvertible {
        case unsupportedRecipe(String)
        case keycodeNotRepresentable(UInt16)
        case appleScriptFailed(String)
        case normalDotmNotFound

        public var description: String {
            switch self {
            case .unsupportedRecipe(let r): return "Unsupported dispatch recipe: \(r)"
            case .keycodeNotRepresentable(let k): return "Mac keycode 0x\(String(k, radix: 16)) has no Windows-VK / WdKey mapping"
            case .appleScriptFailed(let m): return "AppleScript: \(m)"
            case .normalDotmNotFound: return "Normal.dotm not found"
            }
        }
    }

    /// Where Word should store key-binding changes. `Normal.dotm` is the right choice for
    /// app-wide persistent bindings; setting it on every script means `BindingCoordinator`
    /// callers don't have to remember.
    public enum CustomizationContext: Sendable {
        case normal
        case activeDocument
        case inherit
    }

    // MARK: - AppleScript source generation (primary path)

    public static func buildAddKeyBindingScript(
        command: Command,
        binding: ShortcutBinding,
        customizationContext: CustomizationContext = .normal
    ) throws -> String {
        let (commandName, category) = try targetParameters(for: command)
        try validateSafeAppleScriptToken(commandName, label: "command name")
        let args = try encodeBuildKeyCodeArgs(binding)
        let escaped = escapeForAppleScriptLiteral(commandName)
        return """
        tell application "Microsoft Word"\(contextLine(customizationContext))
            set kc to build key code \(args)
            try
                set existing to find key key code kc
                rebind existing key category \(category) command "\(escaped)"
            on error
                make new key binding at end of key bindings with properties {key code:kc, key category:\(category), command:"\(escaped)"}
            end try
        end tell
        """
    }

    public static func buildRemoveKeyBindingScript(
        binding: ShortcutBinding,
        customizationContext: CustomizationContext = .normal
    ) throws -> String {
        let args = try encodeBuildKeyCodeArgs(binding)
        return """
        tell application "Microsoft Word"\(contextLine(customizationContext))
            set kc to build key code \(args)
            try
                set existing to find key key code kc
                rebind existing key category key category disable command ""
            end try
        end tell
        """
    }

    // MARK: - Execution

    public static func apply(command: Command, binding: ShortcutBinding) throws {
        let source = try buildAddKeyBindingScript(command: command, binding: binding)
        do { try AppleScriptRunner.run(source) }
        catch let error as AppleScriptRunner.Failure {
            throw Failure.appleScriptFailed(error.description)
        }
    }

    public static func unbind(binding: ShortcutBinding) throws {
        let source = try buildRemoveKeyBindingScript(binding: binding)
        do { try AppleScriptRunner.run(source) }
        catch let error as AppleScriptRunner.Failure {
            throw Failure.appleScriptFailed(error.description)
        }
    }

    // MARK: - Introspection helpers (for validation and dev tools)

    /// Round-trip probe through Word's AppleScript surface. Returns Word's version string.
    /// Triggers the Automation TCC prompt on first use.
    public static func probeVersion() throws -> String {
        let result = try AppleScriptRunner.run(#"tell application "Microsoft Word" to get version"#)
        return result ?? ""
    }

    /// Commit Normal.dotm to disk so external readers see latest bindings. Uses the
    /// "save attached template of active document" path because direct references to
    /// `template "Normal"` fail with "object does not exist" in Word 16.108.
    public static func saveNormalTemplate() throws {
        try AppleScriptRunner.run(#"tell application "Microsoft Word" to save attached template of active document"#)
    }

    /// Return the list of key-binding display strings ("Ctrl+Shift+E" style) currently
    /// bound to the given command+category.
    public static func keysBound(toCommandName name: String, category: WordKeyCategory) throws -> [String] {
        try validateSafeAppleScriptToken(name, label: "command name")
        let escaped = escapeForAppleScriptLiteral(name)
        let script = """
        tell application "Microsoft Word"
            set bindings to get keys bound to key category \(category.appleScriptEnumerator) command "\(escaped)"
            set out to ""
            repeat with b in bindings
                set out to out & (binding key string of b) & linefeed
            end repeat
            return out
        end tell
        """
        let result = try AppleScriptRunner.run(script) ?? ""
        return result.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Fallback: direct Normal.dotm XML write

    public static func writeCustomizationsXML(
        keymaps: [Keymap],
        at dotmPath: String = NormalDotmArchive.defaultPath
    ) throws {
        let xml = renderCustomizationsXML(keymaps: keymaps)
        guard let data = xml.data(using: .utf8) else {
            throw Failure.appleScriptFailed("UTF-8 encoding failed")
        }
        try NormalDotmArchive.replaceEntry(
            NormalDotmArchive.customizationsXMLEntry, with: data, at: dotmPath
        )
    }

    // MARK: - Ribbind-authored macro keymap residue (cleanup-only)

    /// Detect every Normal.dotm keymap entry whose macro target was authored by
    /// any prior Ribbind version. Covers:
    /// - `NORMAL.RibbindMacros.*` — the wordKeymapMacro era (since-removed).
    /// - `NORMAL.MODULE1.*` — pre-Option-A "user pastes into default module" form.
    /// - Bare `RibbindHL_*`, `RibbindFC_*`, and the older `HIGHLIGHTYELLOW` /
    ///   `FONTCOLORRED` family.
    /// Read-only — caller drives the write (so Word-running detection stays in
    /// one place at the call site).
    public static func detectRibbindMacroKeymaps(
        at dotmPath: String = NormalDotmArchive.defaultPath
    ) -> [Keymap] {
        let keymaps = (try? NormalDotmArchive.readCustomizationsXML(from: dotmPath))
            .map(parseCustomizationsXML) ?? []
        return keymaps.filter { km in
            guard case .macro(let n) = km.target else { return false }
            let upper = n.uppercased()
            if upper.hasPrefix("NORMAL.MODULE1.") { return true }
            if upper.hasPrefix("NORMAL.RIBBINDMACROS.") { return true }
            if upper.hasPrefix("RIBBINDHL_") || upper.hasPrefix("RIBBINDFC_") { return true }
            let legacyBare: Set<String> = [
                "HIGHLIGHTYELLOW", "HIGHLIGHTGREEN", "HIGHLIGHTBLUE",
                "FONTCOLORBLACK", "FONTCOLORWHITE", "FONTCOLORRED",
            ]
            if legacyBare.contains(upper) { return true }
            return false
        }
    }

    /// Remove every Ribbind-authored macro keymap entry from Normal.dotm. Idempotent
    /// (returns 0 when nothing matches). Caller MUST ensure Word is not running —
    /// Word holds an exclusive lock on Normal.dotm; the unzip subprocess would
    /// block indefinitely otherwise.
    @discardableResult
    public static func removeRibbindMacroKeymaps(
        at dotmPath: String = NormalDotmArchive.defaultPath
    ) throws -> Int {
        var keymaps = (try? NormalDotmArchive.readCustomizationsXML(from: dotmPath))
            .map(parseCustomizationsXML) ?? []
        let before = keymaps.count
        let drop = Set(detectRibbindMacroKeymaps(at: dotmPath).map { $0.kcmPrimary.uppercased() })
        keymaps.removeAll { drop.contains($0.kcmPrimary.uppercased()) }
        let removed = before - keymaps.count
        if removed > 0 {
            try writeCustomizationsXML(keymaps: keymaps, at: dotmPath)
        }
        return removed
    }

    public struct Keymap: Sendable, Hashable {
        public let kcmPrimary: String
        public let target: Target

        public enum Target: Sendable, Hashable {
            /// `<wne:fci wne:fciBasedOn="fci" wne:fciIndexBasedOn="N"/>`
            case fciIndex(basedOn: String, index: Int)
            /// `<wne:fci wne:fciName="X" wne:swArg="N"/>` — used by Word Mac for built-in commands
            case fciName(name: String, swArg: String)
            /// `<wne:macro wne:macroName="X"/>` — bound to a VBA macro
            case macro(name: String)
            /// `<wne:keymap wne:mask="N" .../>` — disables the binding; no inner element.
            case disabled(mask: String)
        }

        public init(kcmPrimary: String, target: Target) {
            self.kcmPrimary = kcmPrimary
            self.target = target
        }
    }

    public static func renderCustomizationsXML(keymaps: [Keymap]) -> String {
        let entries = keymaps.map { km -> String in
            switch km.target {
            case .fciIndex(let basedOn, let index):
                let inner = "<wne:fci wne:fciBasedOn=\"\(basedOn)\" wne:fciIndexBasedOn=\"\(index)\"/>"
                return "<wne:keymap wne:kcmPrimary=\"\(km.kcmPrimary)\">\(inner)</wne:keymap>"
            case .fciName(let name, let swArg):
                let inner = "<wne:fci wne:fciName=\"\(name)\" wne:swArg=\"\(swArg)\"/>"
                return "<wne:keymap wne:kcmPrimary=\"\(km.kcmPrimary)\">\(inner)</wne:keymap>"
            case .macro(let name):
                let inner = "<wne:macro wne:macroName=\"\(name)\"/>"
                return "<wne:keymap wne:kcmPrimary=\"\(km.kcmPrimary)\">\(inner)</wne:keymap>"
            case .disabled(let mask):
                return "<wne:keymap wne:mask=\"\(mask)\" wne:kcmPrimary=\"\(km.kcmPrimary)\"/>"
            }
        }.joined()

        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
            "<wne:tcg xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" " +
            "xmlns:wne=\"http://schemas.microsoft.com/office/word/2006/wordml\"><wne:keymaps>" +
            entries +
            "</wne:keymaps></wne:tcg>"
    }

    public static func parseCustomizationsXML(_ xml: String) -> [Keymap] {
        var result: [Keymap] = []
        let nsXml = xml as NSString

        // Form 1: self-closing `<wne:keymap [attrs]/>` — the `mask="1"` disable form.
        Regex.selfClosing.enumerateMatches(in: xml, range: NSRange(location: 0, length: nsXml.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 2 else { return }
            let attrs = nsXml.substring(with: m.range(at: 1))
            guard let kcm = firstCapture(in: attrs, regex: Regex.kcmPrimary) else { return }
            let mask = firstCapture(in: attrs, regex: Regex.mask) ?? "1"
            result.append(Keymap(kcmPrimary: kcm, target: .disabled(mask: mask)))
        }

        // Form 2: `<wne:keymap [attrs]>...inner...</wne:keymap>` — `[^>/]` prevents matching a
        // self-closing tag by excluding both the terminator `>` and the slash `/`.
        Regex.contentBearing.enumerateMatches(in: xml, range: NSRange(location: 0, length: nsXml.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 3 else { return }
            let attrs = nsXml.substring(with: m.range(at: 1))
            let inner = nsXml.substring(with: m.range(at: 2))
            guard let kcm = firstCapture(in: attrs, regex: Regex.kcmPrimary) else { return }

            if let macroName = firstCapture(in: inner, regex: Regex.macroName) {
                result.append(Keymap(kcmPrimary: kcm, target: .macro(name: macroName)))
            } else if let fciName = firstCapture(in: inner, regex: Regex.fciName) {
                let swArg = firstCapture(in: inner, regex: Regex.swArg) ?? "0000"
                result.append(Keymap(kcmPrimary: kcm, target: .fciName(name: fciName, swArg: swArg)))
            } else if let basedOn = firstCapture(in: inner, regex: Regex.fciBasedOn),
                      let idxStr = firstCapture(in: inner, regex: Regex.fciIndexBasedOn),
                      let idx = Int(idxStr) {
                result.append(Keymap(kcmPrimary: kcm, target: .fciIndex(basedOn: basedOn, index: idx)))
            }
        }

        return result
    }

    // MARK: - Private helpers

    private enum Regex {
        static let selfClosing      = compile(#"<wne:keymap\b([^>]*?)/\s*>"#)
        static let contentBearing   = compile(#"<wne:keymap\b([^>/]*)>\s*(.*?)\s*</wne:keymap>"#)
        static let kcmPrimary       = compile(#"wne:kcmPrimary="([0-9A-Fa-f]+)""#)
        static let mask             = compile(#"wne:mask="([^"]+)""#)
        static let macroName        = compile(#"<wne:macro\s+wne:macroName="([^"]+)""#)
        static let fciName          = compile(#"<wne:fci\s+wne:fciName="([^"]+)""#)
        static let swArg            = compile(#"wne:swArg="([^"]+)""#)
        static let fciBasedOn       = compile(#"wne:fciBasedOn="([^"]+)""#)
        static let fciIndexBasedOn  = compile(#"wne:fciIndexBasedOn="([0-9]+)""#)

        private static func compile(_ pattern: String) -> NSRegularExpression {
            // Patterns are static literal constants; compilation should never fail.
            try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        }
    }

    private static func firstCapture(in string: String, regex: NSRegularExpression) -> String? {
        let ns = string as NSString
        guard let m = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func contextLine(_ ctx: CustomizationContext) -> String {
        switch ctx {
        case .normal:         return "\n    set customization context to Normal"
        case .activeDocument: return "\n    set customization context to active document"
        case .inherit:        return ""
        }
    }

    private static func encodeBuildKeyCodeArgs(_ binding: ShortcutBinding) throws -> String {
        let mods = KeyCodeTranslator.modifierMask(fromNSEventFlags: binding.modifierMask)
        guard let keyEnum = KeyCodeTranslator.wdKeyEnumerator(forMacKeyCode: binding.macKeyCode) else {
            throw Failure.keycodeNotRepresentable(binding.macKeyCode)
        }
        let modifierParts = buildKeyCodeModifierParams(mods: mods)
        let allParts = modifierParts + ["\(keyPositionParam(nextIndex: modifierParts.count + 1)):\(keyEnum)"]
        return allParts.joined(separator: ", ")
    }

    private static func targetParameters(for command: Command) throws -> (name: String, category: String) {
        for recipe in command.dispatchRecipes {
            switch recipe {
            case .wordKeyBinding(let name, let cat):
                return (name, cat.appleScriptEnumerator)
            case .wordMacroBinding(let name):
                return (name, WordKeyCategory.macro.appleScriptEnumerator)
            default:
                continue
            }
        }
        throw Failure.unsupportedRecipe("Command '\(command.id)' has no Word-compatible dispatch recipe")
    }

    private static func buildKeyCodeModifierParams(mods: KeyCodeTranslator.ModifierMask) -> [String] {
        var out: [String] = []
        var position = 1
        let modifierList: [(KeyCodeTranslator.ModifierMask, String)] = [
            (.command, "command_key"),
            (.shift,   "shift_key"),
            (.option,  "option_key"),
            (.control, "control_key"),
        ]
        for (mask, enumName) in modifierList {
            if mods.contains(mask) {
                out.append("\(keyPositionParam(nextIndex: position)):\(enumName)")
                position += 1
            }
        }
        return out
    }

    /// Escape a string for safe use inside an AppleScript `"..."` literal. Escapes the
    /// backslash and double-quote characters. Does NOT defend against structural
    /// injection (e.g. `commandName:"FOO"\n\nend tell\ndo shell script ..."`) — for
    /// that, callers should also use `validateSafeAppleScriptToken` to reject any token
    /// with characters outside an allow-list.
    internal static func escapeForAppleScriptLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Reject a token that contains any character that could escape the literal or
    /// inject AppleScript. Command names / macro names / idMso / category enumerators
    /// in the catalog must only contain letters, digits, `.`, `_`, and be ≤ 120 chars.
    /// This is a defense-in-depth check for catalog entries that make it past schema
    /// validation.
    internal static func validateSafeAppleScriptToken(_ s: String, label: String) throws {
        guard s.count <= 120 else {
            throw Failure.appleScriptFailed("\(label) exceeds 120 chars: \(s)")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        if s.rangeOfCharacter(from: allowed.inverted) != nil {
            throw Failure.appleScriptFailed("\(label) contains disallowed character: \(s)")
        }
    }

    private static func keyPositionParam(nextIndex: Int) -> String {
        switch nextIndex {
        case 1: return "key1"
        case 2: return "key2"
        case 3: return "key3"
        case 4: return "key4"
        default: return "key4"
        }
    }
}

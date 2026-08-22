import Foundation

public enum DispatchRecipe: Hashable, Sendable {
    case nsUserKeyEquivalent(menuTitle: String)
    case wordKeyBinding(commandName: String, category: WordKeyCategory)
    case wordMacroBinding(macroName: String)
    case ribbonExecuteMso(idMso: String)
    /// Simulate a click on a Ribbon UI element by Accessibility (AXPress).
    /// Used for modal Ribbon tools (Format Painter, SmartArt, Eyedropper …) where the
    /// UX demands the app enter a brush/dialog state that VBA/AppleScript can't produce.
    ///
    /// `tabName` (optional) ensures the named Ribbon tab is active before searching
    /// — required for buttons that live on the Home/Insert/Design tab rather than the
    /// always-visible toolbar. If `tabName` is nil the dispatcher walks whatever's
    /// currently rendered.
    case axClick(role: String, titleContains: String?, helpContains: String?, descriptionContains: String?, tabName: String?)
    /// Two-step axClick: open a Ribbon dropdown menu, then click a cell inside it.
    /// Used for color pickers (Word's Text Highlight Color / Font Color, PPT's
    /// Font Color) where the dispatch path under Option D (no Automation TCC) is
    /// "open the dropdown via AXShowMenu, then AXPress the specific color cell".
    /// Keeps the recipe accountable to a single declarative description that
    /// `check-no-automation-deps.sh` can keep clean of any `tell application
    /// "Microsoft …"` AppleEvent.
    ///
    /// `parent*` matchers locate the Ribbon menu button (e.g. "Text Highlight
    /// Color"); `cell*` matchers locate the cell inside the popped menu.
    /// `cellDescription` is matched as an EXACT string against the cell's
    /// AXDescription — required because Word's color palettes contain both
    /// "Red" and "Dark Red" (a `contains` match would hit the wrong cell
    /// depending on tree order). `tabName` activates the owning tab first if
    /// supplied. The dispatcher inserts a brief settle window after AXShowMenu
    /// so the cell tree is in place before the cell-search runs.
    case axShowMenuThenClick(
        parentRole: String,
        parentTitleContains: String,
        cellRole: String,
        cellDescription: String,
        tabName: String?
    )
    /// Run a pre-authored AppleScript snippet — the catalog supplies the full source,
    /// including the `tell application "..."` block. Used for PowerPoint commands whose
    /// effect is reachable through PowerPoint's native AS dictionary (font color,
    /// shape manipulation) since PowerPoint lacks Word's `do Visual Basic` bridge.
    /// Only bundled-catalog entries ship this recipe; user-imported bindings files carry
    /// only key-combo choices, never dispatch definitions — so arbitrary-source injection
    /// from untrusted input is not possible.
    ///
    /// The source may contain `{{param.<key>}}` tokens (or sub-component variants
    /// `{{param.color.r}}` / `.g` / `.b` for a 6-digit hex colour stored in
    /// `ShortcutBinding.parameters["color"]`), and `{{mouse.slideX}}` / `{{mouse.slideY}}`
    /// for the live cursor position mapped into PowerPoint slide-coordinate space (PPT
    /// only). The dispatcher substitutes them at fire time before handing the script
    /// to AppleScriptRunner.
    case appleScript(source: String)
    /// Runs **Chrome's own** full-page translate — identical to right-click ▸
    /// *Translate to …* — by pressing Chrome's real UI over the Accessibility API.
    /// No JavaScript, no DOM rewriting, no Chrome-side setup.
    ///
    /// Behaviour (see `ChromeTranslateDispatcher` and
    /// `research/09-chrome-native-translate-ax.md`):
    /// 1. AXPress the omnibox `AXButton` whose description is "Translate"
    /// 2. Chrome's native translate bubble opens as a separate AXWindow holding
    ///    one AXRadioButton per language
    /// 3. AXPress the radio that is NOT currently selected — that is what switches
    ///    the page between original and translated
    ///
    /// The bubble's `AXValue` is the toggle state, so Ribbind keeps no state of its
    /// own and a page the user translated by hand still toggles correctly.
    ///
    /// The target language is Chrome's own setting (Chrome ▸ Settings ▸ Languages),
    /// which is why this case carries no parameters. Fails cleanly when Chrome
    /// offers no Translate control for the page (internal pages, PDFs, or a page
    /// already in the user's language).
    case chromeNativeTranslate
    /// Word / PowerPoint paste with a specific format chosen via the
    /// per-binding `pasteType` parameter. The dispatcher (see
    /// `PasteDispatcher.dispatch`) reads `binding.parameters["pasteType"]`
    /// (falling back to `defaultParameters`) and routes to one of:
    ///   - Word AppleScript `paste special data type X` for direct paste types
    ///     (unformatted, rtf, enhanced metafile, html) — instant, no dialog
    ///   - Menu-bar `Paste` / `Paste and Match Formatting` via
    ///     `nsUserKeyEquivalent` for the universal cases — instant, no menu
    ///     animation
    ///   - PPT clipboard-swap (NSPasteboard plain-text rewrite + AS paste)
    ///     for `unformatted` since PPT's AppleScript dictionary lacks paste-
    ///     type support — instant, no dialog
    /// The recipe carries no parameters itself; the paste type lives in the
    /// binding so the user can change it via a Settings picker without
    /// re-recording the shortcut.
    case pasteWithFormat
}

extension DispatchRecipe: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, menuTitle, commandName, category, macroName, idMso
        case role, titleContains, helpContains, descriptionContains, tabName
        case source
        case parentRole, parentTitleContains, cellRole, cellDescription
    }

    private enum RecipeType: String, Codable {
        case nsUserKeyEquivalent
        case wordKeyBinding
        case wordMacroBinding
        case ribbonExecuteMso
        case axClick
        case axShowMenuThenClick
        case appleScript
        case chromeNativeTranslate
        /// Legacy spelling from the JS-injection era. Decode-only, so a
        /// user-commands.json written by an older build still loads; encoding
        /// always emits `chromeNativeTranslate`.
        case chromeTranslateToggleLegacy = "chromeTranslateToggle"
        case pasteWithFormat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(RecipeType.self, forKey: .type) {
        case .nsUserKeyEquivalent:
            self = .nsUserKeyEquivalent(menuTitle: try c.decode(String.self, forKey: .menuTitle))
        case .wordKeyBinding:
            self = .wordKeyBinding(
                commandName: try c.decode(String.self, forKey: .commandName),
                category: try c.decode(WordKeyCategory.self, forKey: .category)
            )
        case .wordMacroBinding:
            self = .wordMacroBinding(macroName: try c.decode(String.self, forKey: .macroName))
        case .ribbonExecuteMso:
            self = .ribbonExecuteMso(idMso: try c.decode(String.self, forKey: .idMso))
        case .axClick:
            let role = try c.decode(String.self, forKey: .role)
            let title = try c.decodeIfPresent(String.self, forKey: .titleContains).flatMap { $0.isEmpty ? nil : $0 }
            let help  = try c.decodeIfPresent(String.self, forKey: .helpContains ).flatMap { $0.isEmpty ? nil : $0 }
            let desc  = try c.decodeIfPresent(String.self, forKey: .descriptionContains).flatMap { $0.isEmpty ? nil : $0 }
            // Require role AND at least one non-empty needle so the matcher can never
            // end up pressing the first element in the tree (which could be destructive
            // — "Close without saving", "Delete", etc.).
            guard title != nil || help != nil || desc != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: c,
                    debugDescription: "axClick recipe must supply at least one of titleContains / helpContains / descriptionContains"
                )
            }
            let tab = try c.decodeIfPresent(String.self, forKey: .tabName).flatMap { $0.isEmpty ? nil : $0 }
            self = .axClick(role: role, titleContains: title, helpContains: help, descriptionContains: desc, tabName: tab)
        case .axShowMenuThenClick:
            self = .axShowMenuThenClick(
                parentRole: try c.decode(String.self, forKey: .parentRole),
                parentTitleContains: try c.decode(String.self, forKey: .parentTitleContains),
                cellRole: try c.decode(String.self, forKey: .cellRole),
                cellDescription: try c.decode(String.self, forKey: .cellDescription),
                tabName: try c.decodeIfPresent(String.self, forKey: .tabName)
                            .flatMap { $0.isEmpty ? nil : $0 }
            )
        case .appleScript:
            self = .appleScript(source: try c.decode(String.self, forKey: .source))
        case .chromeNativeTranslate, .chromeTranslateToggleLegacy:
            self = .chromeNativeTranslate
        case .pasteWithFormat:
            self = .pasteWithFormat
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nsUserKeyEquivalent(let menuTitle):
            try c.encode(RecipeType.nsUserKeyEquivalent, forKey: .type)
            try c.encode(menuTitle, forKey: .menuTitle)
        case .wordKeyBinding(let commandName, let category):
            try c.encode(RecipeType.wordKeyBinding, forKey: .type)
            try c.encode(commandName, forKey: .commandName)
            try c.encode(category, forKey: .category)
        case .wordMacroBinding(let macroName):
            try c.encode(RecipeType.wordMacroBinding, forKey: .type)
            try c.encode(macroName, forKey: .macroName)
        case .ribbonExecuteMso(let idMso):
            try c.encode(RecipeType.ribbonExecuteMso, forKey: .type)
            try c.encode(idMso, forKey: .idMso)
        case .axClick(let role, let titleContains, let helpContains, let descriptionContains, let tabName):
            try c.encode(RecipeType.axClick, forKey: .type)
            try c.encode(role, forKey: .role)
            try c.encodeIfPresent(titleContains, forKey: .titleContains)
            try c.encodeIfPresent(helpContains, forKey: .helpContains)
            try c.encodeIfPresent(descriptionContains, forKey: .descriptionContains)
            try c.encodeIfPresent(tabName, forKey: .tabName)
        case .axShowMenuThenClick(let parentRole, let parentTitleContains, let cellRole, let cellDescription, let tabName):
            try c.encode(RecipeType.axShowMenuThenClick, forKey: .type)
            try c.encode(parentRole, forKey: .parentRole)
            try c.encode(parentTitleContains, forKey: .parentTitleContains)
            try c.encode(cellRole, forKey: .cellRole)
            try c.encode(cellDescription, forKey: .cellDescription)
            try c.encodeIfPresent(tabName, forKey: .tabName)
        case .appleScript(let source):
            try c.encode(RecipeType.appleScript, forKey: .type)
            try c.encode(source, forKey: .source)
        case .chromeNativeTranslate:
            try c.encode(RecipeType.chromeNativeTranslate, forKey: .type)
        case .pasteWithFormat:
            try c.encode(RecipeType.pasteWithFormat, forKey: .type)
        }
    }
}

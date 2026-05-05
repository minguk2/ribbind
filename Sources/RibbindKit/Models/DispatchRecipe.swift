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
    /// Chrome-specific Translate toggle. The URL bar's translate icon (visible
    /// in Chrome 113+ when the page contains a translatable language) is NOT
    /// exposed via standard AX, so the dispatcher pixel-clicks at a computed
    /// offset from the focused window's top-right and then AX-presses the
    /// inactive language tab in the popup that opens.
    ///
    /// Behaviour:
    /// 1. Compute icon coordinate from `AXFocusedWindow` position + size
    /// 2. CGEvent left-click at that coordinate (cursor stays put via
    ///    CGAssociateMouseAndMouseCursorPosition decouple)
    /// 3. Poll AX for the popup's language-tab buttons (popup IS exposed
    ///    via AX even though the icon isn't)
    /// 4. AXPress the tab that is NOT currently active — that switches the
    ///    page between original and translated state
    ///
    /// Limitation: when Chrome hasn't detected a translatable language on
    /// the current page (icon not visible), the click misses; the popup
    /// poll times out and the dispatch fails with a clear error. Same when
    /// the page's language matches the user's Chrome translation language.
    case chromeTranslateToggle
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
        case chromeTranslateToggle
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
        case .chromeTranslateToggle:
            self = .chromeTranslateToggle
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
        case .chromeTranslateToggle:
            try c.encode(RecipeType.chromeTranslateToggle, forKey: .type)
        }
    }
}

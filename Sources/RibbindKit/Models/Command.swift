import Foundation

public enum AppTarget: String, Codable, Hashable, CaseIterable, Sendable {
    case word
    case powerpoint
    case chrome

    public var processName: String {
        switch self {
        case .word: return "Microsoft Word"
        case .powerpoint: return "Microsoft PowerPoint"
        case .chrome: return "Google Chrome"
        }
    }
}

public enum WordKeyCategory: String, Codable, Hashable, Sendable {
    case command
    case macro
    case style
    case font
    case autoText
    case symbol
    case prefix

    public var appleScriptEnumerator: String {
        switch self {
        case .command: return "key category command"
        case .macro: return "key category macro"
        case .style: return "key category style"
        case .font: return "key category font"
        case .autoText: return "key category auto text"
        case .symbol: return "key category symbol"
        case .prefix: return "key category prefix"
        }
    }
}

public struct Command: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let app: AppTarget
    public let label: String
    public let category: String
    public let idMso: String?
    public let menuTitle: String?
    public let defaultShortcut: String?
    public let dispatchRecipes: [DispatchRecipe]
    public let notes: String?
    /// Default runtime parameters seeded into `ShortcutBinding.parameters` when the
    /// user first binds this command — e.g. `["color": "FFFF00"]` for Highlight 1.
    /// `nil` means "no parameters expected". Codable-compat with pre-v0.5.0 catalogs.
    public let defaultParameters: [String: String]?

    public init(
        id: String,
        app: AppTarget,
        label: String,
        category: String,
        idMso: String? = nil,
        menuTitle: String? = nil,
        defaultShortcut: String? = nil,
        dispatchRecipes: [DispatchRecipe],
        notes: String? = nil,
        defaultParameters: [String: String]? = nil
    ) {
        self.id = id
        self.app = app
        self.label = label
        self.category = category
        self.idMso = idMso
        self.menuTitle = menuTitle
        self.defaultShortcut = defaultShortcut
        self.dispatchRecipes = dispatchRecipes
        self.notes = notes
        self.defaultParameters = defaultParameters
    }

    private enum CodingKeys: String, CodingKey {
        case id, app, label, category, idMso, menuTitle
        case defaultShortcut, dispatchRecipes, notes, defaultParameters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(String.self, forKey: .id)
        self.app             = try c.decode(AppTarget.self, forKey: .app)
        self.label           = try c.decode(String.self, forKey: .label)
        self.category        = try c.decode(String.self, forKey: .category)
        self.idMso           = try c.decodeIfPresent(String.self, forKey: .idMso)
        self.menuTitle       = try c.decodeIfPresent(String.self, forKey: .menuTitle)
        self.defaultShortcut = try c.decodeIfPresent(String.self, forKey: .defaultShortcut)
        self.dispatchRecipes = try c.decode([DispatchRecipe].self, forKey: .dispatchRecipes)
        self.notes           = try c.decodeIfPresent(String.self, forKey: .notes)
        self.defaultParameters = try c.decodeIfPresent([String: String].self, forKey: .defaultParameters)
    }

    public var primaryDispatch: DispatchRecipe? { dispatchRecipes.first }

    public var requiresAccessibility: Bool {
        dispatchRecipes.allSatisfy {
            switch $0 {
            case .ribbonExecuteMso, .axClick: return true
            default: return false
            }
        }
    }
}

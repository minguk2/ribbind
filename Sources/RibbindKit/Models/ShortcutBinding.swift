import Foundation

public struct ShortcutBinding: Codable, Hashable, Sendable {
    public let commandId: String
    public let displayString: String
    public let modifierMask: UInt32
    public let macKeyCode: UInt16
    public let isEnabled: Bool
    /// Per-binding runtime parameters that the dispatch recipe can interpolate at
    /// fire time — e.g. `["color": "00FF00"]` for a Highlight shortcut whose source
    /// template reads `{{param.color.r}}`, `{{param.color.g}}`, `{{param.color.b}}`.
    /// Optional to stay Codable-compatible with bindings persisted before v0.5.0.
    public let parameters: [String: String]?

    public init(commandId: String,
                displayString: String,
                modifierMask: UInt32,
                macKeyCode: UInt16,
                isEnabled: Bool = true,
                parameters: [String: String]? = nil) {
        self.commandId = commandId
        self.displayString = displayString
        self.modifierMask = modifierMask
        self.macKeyCode = macKeyCode
        self.isEnabled = isEnabled
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case commandId, displayString, modifierMask, macKeyCode, isEnabled, parameters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.commandId     = try c.decode(String.self, forKey: .commandId)
        self.displayString = try c.decode(String.self, forKey: .displayString)
        self.modifierMask  = try c.decode(UInt32.self, forKey: .modifierMask)
        self.macKeyCode    = try c.decode(UInt16.self, forKey: .macKeyCode)
        self.isEnabled     = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.parameters    = try c.decodeIfPresent([String: String].self, forKey: .parameters)
    }

    /// Return a copy with a single parameter set. Immutable-update style so callers
    /// can do `store.put(binding.settingParameter("color", "00FF00"))`.
    public func settingParameter(_ key: String, _ value: String) -> ShortcutBinding {
        var params = parameters ?? [:]
        params[key] = value
        return ShortcutBinding(
            commandId: commandId,
            displayString: displayString,
            modifierMask: modifierMask,
            macKeyCode: macKeyCode,
            isEnabled: isEnabled,
            parameters: params
        )
    }
}

import Foundation

/// Persistent store for the user's `ShortcutBinding`s keyed by command id.
/// Backed by UserDefaults with a single JSON-encoded `[String: ShortcutBinding]` value.
@MainActor
public final class PreferenceStore: ObservableObject {
    public static let defaultsKey = "Ribbind.bindings"

    private let defaults: UserDefaults
    @Published public private(set) var bindings: [String: ShortcutBinding] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            bindings = [:]
            return
        }
        if let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            bindings = decoded
        } else {
            bindings = [:]
        }
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func binding(for commandId: String) -> ShortcutBinding? {
        bindings[commandId]
    }

    public func set(_ binding: ShortcutBinding) {
        bindings[binding.commandId] = binding
        save()
    }

    public func remove(commandId: String) {
        bindings.removeValue(forKey: commandId)
        save()
    }

    public func removeAll() {
        bindings = [:]
        save()
    }

    /// Write a single parameter key/value on the binding for `commandId`. If no
    /// binding exists yet (user hasn't recorded a shortcut), seed one with the given
    /// parameters so UI-level color-pickers can "pre-set" a colour before the user
    /// records a combo. The seed binding has macKeyCode=0/modifierMask=0 which
    /// KeyboardShortcuts treats as "no hotkey" — nothing fires until the user
    /// actually records a combo.
    public func setParameter(commandId: String, key: String, value: String) {
        let existing = bindings[commandId]
            ?? ShortcutBinding(commandId: commandId, displayString: "",
                               modifierMask: 0, macKeyCode: 0,
                               isEnabled: true, parameters: nil)
        bindings[commandId] = existing.settingParameter(key, value)
        save()
    }

    public func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(bindings)
    }

    /// Import bindings from a JSON blob produced by `exportJSON`. If `validCommandIDs`
    /// is supplied, any keys not in that set are dropped silently — this is the primary
    /// defense against a malicious "preset pack" binding stuff to unexpected command ids.
    public func importJSON(_ data: Data, validCommandIDs: Set<String>? = nil) throws {
        var decoded = try JSONDecoder().decode([String: ShortcutBinding].self, from: data)
        if let allowlist = validCommandIDs {
            decoded = decoded.filter { allowlist.contains($0.key) }
        }
        bindings = decoded
        save()
    }
}

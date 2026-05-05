import Foundation

public enum PowerPointPlistWriter {
    public enum Failure: Error, CustomStringConvertible {
        case plistUnreadable(String)
        case plistUnwritable(String)
        case menuTitleRequired

        public var description: String {
            switch self {
            case .plistUnreadable(let p): return "Could not read plist at \(p)"
            case .plistUnwritable(let p): return "Could not write plist at \(p)"
            case .menuTitleRequired: return "menuTitle is empty"
            }
        }
    }

    public static let defaultPlistPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Containers/com.microsoft.Powerpoint/Data/Library/Preferences/com.microsoft.Powerpoint.plist"
    }()

    public static func readCurrentBindings(at path: String = defaultPlistPath) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format
        ) as? [String: Any] else {
            throw Failure.plistUnreadable(path)
        }
        return (root["NSUserKeyEquivalents"] as? [String: String]) ?? [:]
    }

    public static func updateBindings(
        at path: String = defaultPlistPath,
        mutate: (inout [String: String]) -> Void
    ) throws {
        var root: [String: Any]
        let url = URL(fileURLWithPath: path)

        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: url)
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let decoded = try PropertyListSerialization.propertyList(
                from: data, options: [], format: &format
            ) as? [String: Any] else {
                throw Failure.plistUnreadable(path)
            }
            root = decoded

            let backup = path + ".bak"
            if !FileManager.default.fileExists(atPath: backup) {
                try? FileManager.default.copyItem(atPath: path, toPath: backup)
            }
        } else {
            root = [:]
        }

        var dict = (root["NSUserKeyEquivalents"] as? [String: String]) ?? [:]
        mutate(&dict)
        if dict.isEmpty {
            root.removeValue(forKey: "NSUserKeyEquivalents")
        } else {
            root["NSUserKeyEquivalents"] = dict
        }

        let serialized = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        )
        try serialized.write(to: url, options: .atomic)
    }

    public static func bind(menuTitle: String, shorthand: String, at path: String = defaultPlistPath) throws {
        guard !menuTitle.isEmpty else { throw Failure.menuTitleRequired }
        try updateBindings(at: path) { dict in
            dict[menuTitle] = shorthand
        }
    }

    public static func unbind(menuTitle: String, at path: String = defaultPlistPath) throws {
        try updateBindings(at: path) { dict in
            dict.removeValue(forKey: menuTitle)
        }
    }

    /// Convenience: convert a `ShortcutBinding` to the NSUserKeyEquivalents shorthand
    /// expected by Cocoa.
    public static func shorthand(for binding: ShortcutBinding) -> String? {
        let mods = KeyCodeTranslator.modifierMask(fromNSEventFlags: binding.modifierMask)
        return KeyCodeTranslator.encodeNSUserKeyShorthand(modifiers: mods, macKeyCode: binding.macKeyCode)
    }
}

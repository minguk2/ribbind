import Carbon.HIToolbox
import Foundation

public enum KeyCodeTranslator {
    public static let macToWindowsVK: [UInt16: UInt8] = [
        UInt16(kVK_ANSI_A): 0x41, UInt16(kVK_ANSI_B): 0x42, UInt16(kVK_ANSI_C): 0x43,
        UInt16(kVK_ANSI_D): 0x44, UInt16(kVK_ANSI_E): 0x45, UInt16(kVK_ANSI_F): 0x46,
        UInt16(kVK_ANSI_G): 0x47, UInt16(kVK_ANSI_H): 0x48, UInt16(kVK_ANSI_I): 0x49,
        UInt16(kVK_ANSI_J): 0x4A, UInt16(kVK_ANSI_K): 0x4B, UInt16(kVK_ANSI_L): 0x4C,
        UInt16(kVK_ANSI_M): 0x4D, UInt16(kVK_ANSI_N): 0x4E, UInt16(kVK_ANSI_O): 0x4F,
        UInt16(kVK_ANSI_P): 0x50, UInt16(kVK_ANSI_Q): 0x51, UInt16(kVK_ANSI_R): 0x52,
        UInt16(kVK_ANSI_S): 0x53, UInt16(kVK_ANSI_T): 0x54, UInt16(kVK_ANSI_U): 0x55,
        UInt16(kVK_ANSI_V): 0x56, UInt16(kVK_ANSI_W): 0x57, UInt16(kVK_ANSI_X): 0x58,
        UInt16(kVK_ANSI_Y): 0x59, UInt16(kVK_ANSI_Z): 0x5A,

        UInt16(kVK_ANSI_0): 0x30, UInt16(kVK_ANSI_1): 0x31, UInt16(kVK_ANSI_2): 0x32,
        UInt16(kVK_ANSI_3): 0x33, UInt16(kVK_ANSI_4): 0x34, UInt16(kVK_ANSI_5): 0x35,
        UInt16(kVK_ANSI_6): 0x36, UInt16(kVK_ANSI_7): 0x37, UInt16(kVK_ANSI_8): 0x38,
        UInt16(kVK_ANSI_9): 0x39,

        UInt16(kVK_Return): 0x0D, UInt16(kVK_Tab): 0x09, UInt16(kVK_Space): 0x20,
        UInt16(kVK_Delete): 0x08, UInt16(kVK_Escape): 0x1B, UInt16(kVK_ForwardDelete): 0x2E,
        UInt16(kVK_Home): 0x24, UInt16(kVK_End): 0x23,
        UInt16(kVK_PageUp): 0x21, UInt16(kVK_PageDown): 0x22,
        UInt16(kVK_LeftArrow): 0x25, UInt16(kVK_UpArrow): 0x26,
        UInt16(kVK_RightArrow): 0x27, UInt16(kVK_DownArrow): 0x28,

        UInt16(kVK_F1): 0x70, UInt16(kVK_F2): 0x71, UInt16(kVK_F3): 0x72,
        UInt16(kVK_F4): 0x73, UInt16(kVK_F5): 0x74, UInt16(kVK_F6): 0x75,
        UInt16(kVK_F7): 0x76, UInt16(kVK_F8): 0x77, UInt16(kVK_F9): 0x78,
        UInt16(kVK_F10): 0x79, UInt16(kVK_F11): 0x7A, UInt16(kVK_F12): 0x7B,
    ]

    public static let macToCharacter: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_C): "c",
        UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_E): "e", UInt16(kVK_ANSI_F): "f",
        UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_I): "i",
        UInt16(kVK_ANSI_J): "j", UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l",
        UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_O): "o",
        UInt16(kVK_ANSI_P): "p", UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r",
        UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t", UInt16(kVK_ANSI_U): "u",
        UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x",
        UInt16(kVK_ANSI_Y): "y", UInt16(kVK_ANSI_Z): "z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
    ]

    public struct ModifierMask: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = ModifierMask(rawValue: 0x01)
        public static let shift   = ModifierMask(rawValue: 0x02)
        public static let option  = ModifierMask(rawValue: 0x08)
        public static let control = ModifierMask(rawValue: 0x10)
    }

    public static func encodeKcmPrimary(modifiers: ModifierMask, macKeyCode: UInt16) -> String? {
        guard let vk = macToWindowsVK[macKeyCode] else { return nil }
        let combined = UInt16(modifiers.rawValue) << 8 | UInt16(vk)
        return String(format: "%04X", combined)
    }

    public static func decodeKcmPrimary(_ hex: String) -> (modifiers: ModifierMask, macKeyCode: UInt16)? {
        guard let value = UInt16(hex, radix: 16) else { return nil }
        let mods = ModifierMask(rawValue: UInt8(value >> 8))
        let vk = UInt8(value & 0xFF)
        guard let macKey = macToWindowsVK.first(where: { $0.value == vk })?.key else { return nil }
        return (mods, macKey)
    }

    public static func encodeNSUserKeyShorthand(modifiers: ModifierMask, character: String) -> String? {
        guard !character.isEmpty else { return nil }
        var out = ""
        if modifiers.contains(.command) { out.append("@") }
        if modifiers.contains(.shift)   { out.append("$") }
        if modifiers.contains(.option)  { out.append("~") }
        if modifiers.contains(.control) { out.append("^") }
        out.append(character.lowercased())
        return out
    }

    public static func encodeNSUserKeyShorthand(modifiers: ModifierMask, macKeyCode: UInt16) -> String? {
        guard let ch = macToCharacter[macKeyCode] else { return nil }
        return encodeNSUserKeyShorthand(modifiers: modifiers, character: ch)
    }

    public static func decodeNSUserKeyShorthand(_ shorthand: String) -> (modifiers: ModifierMask, character: String)? {
        var mods = ModifierMask()
        var chars = shorthand
        while let first = chars.first, "@$~^".contains(first) {
            switch first {
            case "@": mods.insert(.command)
            case "$": mods.insert(.shift)
            case "~": mods.insert(.option)
            case "^": mods.insert(.control)
            default: break
            }
            chars.removeFirst()
        }
        guard !chars.isEmpty else { return nil }
        return (mods, chars)
    }

    public static func modifierMask(fromNSEventFlags raw: UInt32) -> ModifierMask {
        var out = ModifierMask()
        if raw & 0x100000 != 0 { out.insert(.command) }
        if raw & 0x020000 != 0 { out.insert(.shift) }
        if raw & 0x080000 != 0 { out.insert(.option) }
        if raw & 0x040000 != 0 { out.insert(.control) }
        return out
    }

    /// Carbon modifier bits (cmdKey = 0x100, shiftKey = 0x200, optionKey = 0x800,
    /// controlKey = 0x1000) — the same values KeyboardShortcuts persists in
    /// UserDefaults as `carbonModifiers`. Match these exactly so default-shortcut
    /// seeding writes a binding indistinguishable from a user-recorded one.
    public enum CarbonModifier {
        public static let cmd: Int     = 0x100
        public static let shift: Int   = 0x200
        public static let option: Int  = 0x800
        public static let control: Int = 0x1000
    }

    /// Parse a display-style shortcut string like `⌘⇧E` / `⌃⌥⇧B` / `⌘1` into
    /// a `(keyCode, carbonModifiers)` tuple suitable for writing into the
    /// `KeyboardShortcuts_<commandId>` UserDefaults entry. Returns nil for
    /// strings that reference unknown modifiers or an unmapped key name.
    ///
    /// Accepted modifier glyphs:
    ///   - ⌘ / Cmd → command
    ///   - ⇧ / Shift → shift
    ///   - ⌥ / Option / Alt → option
    ///   - ⌃ / Ctrl / Control → control
    ///
    /// Key portion: single letter/number (case-insensitive), or one of the
    /// named specials in `macToWindowsVK` (Return, Tab, Space, F1…F12).
    public static func parseDisplayString(_ raw: String) -> (keyCode: UInt16, carbonModifiers: Int)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate `+` / `-` separators between tokens ("Cmd+Shift+E").
        s = s.replacingOccurrences(of: "+", with: "")
             .replacingOccurrences(of: "-", with: "")
             .replacingOccurrences(of: " ", with: "")

        var mods = 0
        // Chomp modifier glyphs / names from the front. The loop also accepts
        // text aliases like "Cmd", "Shift" — case-insensitive.
        let aliases: [(String, Int)] = [
            ("⌘", CarbonModifier.cmd),     ("Cmd",     CarbonModifier.cmd),     ("Command", CarbonModifier.cmd),
            ("⇧", CarbonModifier.shift),   ("Shift",   CarbonModifier.shift),
            ("⌥", CarbonModifier.option),  ("Option",  CarbonModifier.option),  ("Alt",     CarbonModifier.option),
            ("⌃", CarbonModifier.control), ("Ctrl",    CarbonModifier.control), ("Control", CarbonModifier.control),
        ]
        outer: while !s.isEmpty {
            for (glyph, bit) in aliases {
                if s.lowercased().hasPrefix(glyph.lowercased()) {
                    mods |= bit
                    s.removeFirst(glyph.count)
                    continue outer
                }
            }
            break
        }
        guard !s.isEmpty else { return nil }

        // The remainder is the key — could be a single char (letter/digit) or
        // a named special.
        if s.count == 1, let ch = s.lowercased().unicodeScalars.first {
            let c = Character(ch)
            if c.isLetter {
                let letter = String(c).uppercased()
                // kVK_ANSI_A…Z constants via macToWindowsVK reverse lookup.
                if let kc = macToCharacter.first(where: { $0.value == letter.lowercased() })?.key {
                    return (kc, mods)
                }
            } else if c.isNumber {
                if let kc = macToCharacter.first(where: { $0.value == String(c) })?.key {
                    return (kc, mods)
                }
            }
        }
        let specials: [String: Int] = [
            "return": kVK_Return, "enter": kVK_Return,
            "tab": kVK_Tab, "space": kVK_Space,
            "delete": kVK_Delete, "backspace": kVK_Delete,
            "esc": kVK_Escape, "escape": kVK_Escape,
            "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
            "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        ]
        if let kc = specials[s.lowercased()] {
            return (UInt16(kc), mods)
        }
        return nil
    }

    public static func wdKeyEnumerator(forMacKeyCode macKeyCode: UInt16) -> String? {
        if let ch = macToCharacter[macKeyCode] {
            if ch.count == 1, let scalar = ch.unicodeScalars.first {
                if scalar.value >= 0x61 && scalar.value <= 0x7A {
                    return "\(ch)_key"
                }
                if scalar.value >= 0x30 && scalar.value <= 0x39 {
                    return "key_number_\(ch)"
                }
            }
        }
        switch Int(macKeyCode) {
        case kVK_Return: return "return_key"
        case kVK_Tab: return "tab_key"
        case kVK_Space: return "spacebar_key"
        case kVK_Delete: return "backspace_key"
        case kVK_Escape: return "esc_key"
        case kVK_ForwardDelete: return "delete_key"
        case kVK_Home: return "home_key"
        case kVK_End: return "end_key"
        case kVK_PageUp: return "page_up_key"
        case kVK_PageDown: return "page_down_key"
        case kVK_F1: return "F1_key"
        case kVK_F2: return "F2_key"
        case kVK_F3: return "F3_key"
        case kVK_F4: return "F4_key"
        case kVK_F5: return "F5_key"
        case kVK_F6: return "F6_key"
        case kVK_F7: return "F7_key"
        case kVK_F8: return "F8_key"
        case kVK_F9: return "F9_key"
        case kVK_F10: return "F10_key"
        case kVK_F11: return "F11_key"
        case kVK_F12: return "F12_key"
        default: return nil
        }
    }
}

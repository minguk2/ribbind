import SwiftUI
import AppKit
import KeyboardShortcuts
import RibbindKit

struct ShortcutRow: View {
    let command: Command
    @EnvironmentObject private var coordinator: BindingCoordinator
    @EnvironmentObject private var catalog: Catalog
    @EnvironmentObject private var store: PreferenceStore

    @State private var conflict: ConflictDescriptor? = nil

    /// Captured pending change so the alert callbacks can apply or revert it.
    private struct ConflictDescriptor: Identifiable {
        let id = UUID()
        let pendingShortcut: KeyboardShortcuts.Shortcut
        let conflictingCommandId: String
        let conflictingCommandLabel: String
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayLabel)
                        .font(.body)
                    if command.requiresAccessibility {
                        Image(systemName: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Ribbon-only command — requires Accessibility permission")
                    }
                }
                Text(command.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasNamedColorParam {
                NamedHighlightColorMenu(token: colorNameBinding)
            } else if hasColorParam {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 40)
                    .help("Colour this shortcut applies. Defaults from the catalog; editable per-binding and saved with your other settings.")
            }

            if hasTargetLanguageParam {
                Picker("", selection: targetLanguageBinding) {
                    ForEach(ChromeJSAutomation.supportedTargetLanguages) { lang in
                        Text(lang.displayName).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200)
                .help("Target language for Translate Page. Chrome downloads the on-device model for this pair on first use (one-time, ~50 MB) — Settings → Google Chrome guides the download.")
            }

            if hasFontParam {
                Picker("", selection: fontNameBinding) {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .help("Font family this shortcut applies. System-installed fonts only.")
            }

            KeyboardShortcuts.Recorder(for: KeyboardShortcuts.Name(command.id)) { shortcut in
                handleChange(shortcut: shortcut)
            }
            .frame(width: 200)
        }
        .padding(.vertical, 2)
        .alert("Shortcut already bound", isPresented: Binding(
            get: { conflict != nil },
            set: { if !$0 { conflict = nil } }
        ), presenting: conflict) { c in
            Button("Swap") {
                swapConflictingBindings(with: c.pendingShortcut, conflictingId: c.conflictingCommandId)
            }
            Button("Cancel", role: .cancel) {
                // Revert recorder back to whatever the store currently has
                // for this command (which may be nil if never bound).
                rollbackRecorder()
            }
        } message: { c in
            Text("\(c.pendingShortcut) is already bound to \(c.conflictingCommandLabel) in \(command.app.rawValue.capitalized). Swap (the other shortcut takes your previous combo, if any), or cancel.")
        }
    }

    /// Command label with the active parameter appended in parentheses so the
    /// user sees at a glance what each row is currently set to. Highlight rows
    /// show the named WdColorIndex; FontColor rows show the hex; chrome.Translate
    /// shows the target-language display name.
    private var displayLabel: String {
        if hasNamedColorParam {
            let token = colorNameBinding.wrappedValue
            let pretty = NamedHighlightColorMenu.options.first { $0.id == token }?.displayName
                ?? token.capitalized
            return "\(command.label) (\(pretty))"
        }
        if hasColorParam {
            let hex = (store.binding(for: command.id)?.parameters?["color"]
                       ?? command.defaultParameters?["color"]
                       ?? "").uppercased()
            return hex.isEmpty ? command.label : "\(command.label) (#\(hex))"
        }
        if hasTargetLanguageParam {
            let code = targetLanguageBinding.wrappedValue
            return "\(command.label) (\(ChromeJSAutomation.displayName(forLanguageCode: code)))"
        }
        return command.label
    }

    /// True when this command takes a colour parameter — appleScript recipes with
    /// `{{param.color.*}}` template tokens (hex RGB). The dispatcher interpolates
    /// the hex at fire time so the picker change takes effect on the next press.
    /// `{{param.colorName}}` (named WdColorIndex) is handled separately by
    /// `hasNamedColorParam`.
    private var hasColorParam: Bool {
        command.dispatchRecipes.contains { recipe in
            if case .appleScript(let src) = recipe { return src.contains("{{param.color.r") }
            return false
        }
    }

    /// True when this command takes a NAMED highlight-color parameter
    /// (`{{param.colorName}}`). Used for Word Highlight commands which write
    /// `<w:highlight w:val="...">` via `set highlight color index of text object
    /// of selection to <named>` — limited to Word's 13 WdColorIndex enum tokens
    /// but compatible with Word's Home > Text Highlight Color > No Color clear.
    private var hasNamedColorParam: Bool {
        command.dispatchRecipes.contains { recipe in
            if case .appleScript(let src) = recipe { return src.contains("{{param.colorName}}") }
            return false
        }
    }

    /// Two-way binding for the named-color parameter — same shape as `colorBinding`
    /// but keyed on `colorName` instead of `color`. Default falls back to "yellow"
    /// (the first WdColorIndex value).
    private var colorNameBinding: Binding<String> {
        Binding(
            get: {
                store.binding(for: command.id)?.parameters?["colorName"]
                    ?? command.defaultParameters?["colorName"]
                    ?? "yellow"
            },
            set: { newToken in
                store.setParameter(commandId: command.id, key: "colorName", value: newToken)
            }
        )
    }

    /// True when this command takes a target-language parameter
    /// (`{{param.targetLanguage}}` or recipe consults it). Currently used by
    /// `chrome.Translate` to let the user pick the destination language for
    /// the Chrome Translator API.
    private var hasTargetLanguageParam: Bool {
        command.dispatchRecipes.contains { recipe in
            if case .chromeTranslateToggle = recipe { return true }
            return false
        }
    }

    /// Two-way binding for the targetLanguage parameter. Default from catalog
    /// (`defaultParameters.targetLanguage`), then "ko".
    private var targetLanguageBinding: Binding<String> {
        Binding(
            get: {
                store.binding(for: command.id)?.parameters?["targetLanguage"]
                    ?? command.defaultParameters?["targetLanguage"]
                    ?? "ko"
            },
            set: { newCode in
                store.setParameter(commandId: command.id, key: "targetLanguage", value: newCode)
            }
        )
    }

    /// True when this command takes a font-family parameter (`{{param.fontName}}`).
    private var hasFontParam: Bool {
        command.dispatchRecipes.contains { recipe in
            if case .appleScript(let src) = recipe { return src.contains("{{param.fontName}}") }
            return false
        }
    }

    /// Two-way binding for the font-family parameter — same shape as `colorBinding`
    /// but for the `fontName` key. Defaults from `command.defaultParameters["fontName"]`,
    /// then the system fallback "Helvetica Neue".
    private var fontNameBinding: Binding<String> {
        Binding(
            get: {
                store.binding(for: command.id)?.parameters?["fontName"]
                    ?? command.defaultParameters?["fontName"]
                    ?? "Helvetica Neue"
            },
            set: { newName in
                store.setParameter(commandId: command.id, key: "fontName", value: newName)
            }
        )
    }

    /// Two-way binding that reads the current colour from the ShortcutBinding's
    /// parameters (or falls back to `command.defaultParameters["color"]`) and writes
    /// back via `PreferenceStore.setParameter`. Works even when the user hasn't
    /// recorded a hotkey yet — the store seeds a dormant binding (no key code) so the
    /// colour sticks until they do record one.
    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let hex = store.binding(for: command.id)?.parameters?["color"]
                    ?? command.defaultParameters?["color"]
                    ?? "FFFF00"
                return Self.color(fromHex: hex)
            },
            set: { newColor in
                let hex = Self.hex(fromColor: newColor)
                store.setParameter(commandId: command.id, key: "color", value: hex)
            }
        )
    }

    static func color(fromHex raw: String) -> Color {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return .yellow }
        let r = Double((n >> 16) & 0xFF) / 255.0
        let g = Double((n >> 8) & 0xFF) / 255.0
        let b = Double(n & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    static func hex(fromColor color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    private func handleChange(shortcut: KeyboardShortcuts.Shortcut?) {
        guard let shortcut else {
            coordinator.remove(command: command)
            coordinator.refreshHotkeyMonitor(catalog: catalog.commands)
            return
        }

        // Conflict detection — same combo already bound to another command in the
        // SAME target app. Cross-app duplicates (Word + PowerPoint with the same
        // combo) are intentional: Ribbind's frontmost gate routes to whichever
        // app is active. Within a single app, a duplicate would silently
        // overshadow whichever command Ribbind looks up first.
        let modMask = UInt32(shortcut.modifiers.rawValue)
        let kc = UInt16(shortcut.carbonKeyCode)
        if let conflicting = catalog.commands.first(where: { other in
            other.id != command.id
                && other.app == command.app
                && (store.binding(for: other.id).map { $0.modifierMask == modMask && $0.macKeyCode == kc } ?? false)
        }) {
            conflict = ConflictDescriptor(
                pendingShortcut: shortcut,
                conflictingCommandId: conflicting.id,
                conflictingCommandLabel: conflicting.label
            )
            return
        }

        applyBinding(for: shortcut)
    }

    private func applyBinding(for shortcut: KeyboardShortcuts.Shortcut) {
        // Preserve any colour-picker seed the user set BEFORE recording a combo.
        let existingParams = store.binding(for: command.id)?.parameters
        let seededParams = existingParams ?? command.defaultParameters

        let binding = ShortcutBinding(
            commandId: command.id,
            displayString: "\(shortcut)",
            modifierMask: UInt32(shortcut.modifiers.rawValue),
            macKeyCode: UInt16(shortcut.carbonKeyCode),
            parameters: seededParams
        )

        do {
            _ = try coordinator.apply(binding: binding, to: command)
            coordinator.refreshHotkeyMonitor(catalog: catalog.commands)
        } catch {
            NSLog("Failed to apply binding for \(command.id): \(error)")
        }
    }

    /// User picked Swap. Two cases:
    ///   1. Current command HAS a prior combo: hand that combo to the
    ///      conflicting command (keeping its parameters), then bind the new
    ///      combo to the current command. Both commands keep a binding.
    ///   2. Current command has NO prior combo: degenerate to remove-only
    ///      (there's nothing to swap with), then bind the new combo here.
    /// Hotkey routing is handled by `HotkeyMonitor`'s binding map, refreshed
    /// on every `.shortcutByNameDidChange` notification — `setShortcut` calls
    /// here will trigger the observer in `BindingCoordinator` automatically.
    private func swapConflictingBindings(
        with shortcut: KeyboardShortcuts.Shortcut,
        conflictingId: String
    ) {
        guard let conflicting = catalog.commands.first(where: { $0.id == conflictingId }) else {
            applyBinding(for: shortcut)
            coordinator.refreshHotkeyMonitor(catalog: catalog.commands)
            return
        }
        let priorOfCurrent = store.binding(for: command.id)
        if let prior = priorOfCurrent {
            let conflictingParams = store.binding(for: conflicting.id)?.parameters
                ?? conflicting.defaultParameters
            let swappedBinding = ShortcutBinding(
                commandId: conflicting.id,
                displayString: prior.displayString,
                modifierMask: prior.modifierMask,
                macKeyCode: prior.macKeyCode,
                parameters: conflictingParams
            )
            do {
                _ = try coordinator.apply(binding: swappedBinding, to: conflicting)
                // Mirror to KeyboardShortcuts so the conflicting command's recorder
                // shows the swapped combo immediately (without this, the recorder
                // keeps showing the old combo until next launch).
                let cocoa = NSEvent.ModifierFlags(rawValue: UInt(prior.modifierMask))
                var carbon = 0
                if cocoa.contains(.command) { carbon |= 0x100 }
                if cocoa.contains(.shift)   { carbon |= 0x200 }
                if cocoa.contains(.option)  { carbon |= 0x800 }
                if cocoa.contains(.control) { carbon |= 0x1000 }
                let s = KeyboardShortcuts.Shortcut(
                    carbonKeyCode: Int(prior.macKeyCode),
                    carbonModifiers: carbon
                )
                KeyboardShortcuts.setShortcut(s, for: KeyboardShortcuts.Name(conflicting.id))
            } catch {
                NSLog("Swap to \(conflicting.id) failed: \(error) — falling back to remove")
                coordinator.remove(command: conflicting)
            }
        } else {
            coordinator.remove(command: conflicting)
        }
        applyBinding(for: shortcut)
        coordinator.refreshHotkeyMonitor(catalog: catalog.commands)
    }

    /// User picked Cancel — Force the recorder back to whatever the store says
    /// is bound for this command, undoing the in-progress recording. Without
    /// this, the recorder keeps showing the rejected combo.
    private func rollbackRecorder() {
        let name = KeyboardShortcuts.Name(command.id)
        if let stored = store.binding(for: command.id) {
            // KeyboardShortcuts.Shortcut stores combos in Carbon flag form.
            // Translate Cocoa NSEvent.ModifierFlags → Carbon bitmask manually
            // (Carbon helpers aren't exposed in the vendored slice).
            let cocoa = NSEvent.ModifierFlags(rawValue: UInt(stored.modifierMask))
            var carbon = 0
            if cocoa.contains(.command)  { carbon |= 0x100  } // cmdKey
            if cocoa.contains(.shift)    { carbon |= 0x200  } // shiftKey
            if cocoa.contains(.option)   { carbon |= 0x800  } // optionKey
            if cocoa.contains(.control)  { carbon |= 0x1000 } // controlKey
            let s = KeyboardShortcuts.Shortcut(carbonKeyCode: Int(stored.macKeyCode), carbonModifiers: carbon)
            KeyboardShortcuts.setShortcut(s, for: name)
        } else {
            KeyboardShortcuts.setShortcut(nil, for: name)
        }
    }
}

/// Compact swatch + dropdown for picking a Word `WdColorIndex` highlight value.
/// Displayed in place of the RGB `ColorPicker` for commands whose dispatch source
/// contains `{{param.colorName}}` (Word Highlight 1/2/3). The 13 tokens are the
/// safe subset of WdColorIndex names verified to work with `set highlight color
/// index of text object of selection to <named>` AppleScript on Word Mac 16.108.
struct NamedHighlightColorMenu: View {
    @Binding var token: String

    struct Option: Identifiable {
        let id: String
        let displayName: String
        let swatch: Color
    }

    static let options: [Option] = [
        .init(id: "yellow",       displayName: "Yellow",       swatch: Color(red: 1.00, green: 1.00, blue: 0.00)),
        .init(id: "bright green", displayName: "Bright Green", swatch: Color(red: 0.00, green: 1.00, blue: 0.00)),
        .init(id: "turquoise",    displayName: "Turquoise",    swatch: Color(red: 0.00, green: 1.00, blue: 1.00)),
        .init(id: "pink",         displayName: "Pink",         swatch: Color(red: 1.00, green: 0.00, blue: 1.00)),
        .init(id: "blue",         displayName: "Blue",         swatch: Color(red: 0.00, green: 0.00, blue: 1.00)),
        .init(id: "red",          displayName: "Red",          swatch: Color(red: 1.00, green: 0.00, blue: 0.00)),
        .init(id: "dark blue",    displayName: "Dark Blue",    swatch: Color(red: 0.00, green: 0.00, blue: 0.50)),
        .init(id: "teal",         displayName: "Teal",         swatch: Color(red: 0.00, green: 0.50, blue: 0.50)),
        .init(id: "green",        displayName: "Green",        swatch: Color(red: 0.00, green: 0.50, blue: 0.00)),
        .init(id: "violet",       displayName: "Violet",       swatch: Color(red: 0.50, green: 0.00, blue: 0.50)),
        .init(id: "dark red",     displayName: "Dark Red",     swatch: Color(red: 0.50, green: 0.00, blue: 0.00)),
        .init(id: "dark yellow",  displayName: "Dark Yellow",  swatch: Color(red: 0.50, green: 0.50, blue: 0.00)),
        .init(id: "black",        displayName: "Black",        swatch: Color.black),
    ]

    var body: some View {
        Menu {
            ForEach(Self.options) { opt in
                Button {
                    token = opt.id
                } label: {
                    HStack {
                        Text(opt.displayName)
                        if opt.id == token { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            currentSwatchView
        }
        .menuStyle(.borderlessButton)
        .frame(width: 40)
        .help("Highlight color (Word's named WdColorIndex). Cleared normally by Word Home > Text Highlight Color > No Color.")
    }

    @ViewBuilder
    private var currentSwatchView: some View {
        let match = Self.options.first { $0.id == token } ?? Self.options[0]
        RoundedRectangle(cornerRadius: 3)
            .fill(match.swatch)
            .frame(width: 28, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.gray.opacity(0.4), lineWidth: 0.5)
            )
    }
}

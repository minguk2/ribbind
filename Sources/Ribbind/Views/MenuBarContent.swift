import SwiftUI
import AppKit

struct MenuBarContent: View {
    var body: some View {
        // SwiftUI's `SettingsLink` opens the Settings scene but for .accessory
        // apps the window often opens BEHIND other apps because we're never
        // activated as foreground. Explicit activate-first + open-settings
        // brings the window to the front reliably.
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            // macOS uses a private selector on NSApp to open the Settings
            // scene. The exact name has rotated between macOS versions:
            //   macOS 14+: `showSettingsWindow:`
            //   macOS 13:  `showSettingsWindow:`
            //   pre-13:    `showPreferencesWindow:`
            // Try both — first that responds wins. Without this, .accessory
            // apps see the click silently no-op when SwiftUI's SettingsLink
            // can't find a target.
            let candidates: [Selector] = [
                Selector(("showSettingsWindow:")),
                Selector(("showPreferencesWindow:")),
            ]
            for sel in candidates {
                if NSApp.sendAction(sel, to: nil, from: nil) { break }
            }
            // Belt-and-suspenders: explicitly raise any existing Settings
            // window. SwiftUI Settings windows are NSWindow with title
            // "Word" / "PowerPoint" / "General" — we just bring all visible
            // app windows forward.
            for w in NSApp.windows where w.canBecomeKey {
                w.makeKeyAndOrderFront(nil)
            }
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Ribbind") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

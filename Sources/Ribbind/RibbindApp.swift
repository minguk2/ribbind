import SwiftUI
import AppKit
import ApplicationServices
import RibbindKit

@main
struct RibbindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var catalog = Catalog()

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(catalog)
                .environmentObject(delegate.store)
                .environmentObject(delegate.coordinator)
        }

        MenuBarExtra {
            MenuBarContent()
        } label: {
            Self.menuBarLabel
        }
        .menuBarExtraStyle(.menu)
    }

    /// Loads the bundled MenuBarIcon.pdf as a template NSImage so macOS tints it to
    /// match the menu bar appearance (white on dark backgrounds, black on light).
    /// Falling back to the generic keyboard SF Symbol only if the resource is missing
    /// — shouldn't happen in a shipping build, but keeps the app usable if the asset
    /// gets stripped.
    @ViewBuilder
    private static var menuBarLabel: some View {
        if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let nsImage = NSImage(contentsOf: url) {
            let _ = nsImage.isTemplate = true
            Image(nsImage: nsImage)
        } else {
            Image(systemName: "keyboard")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = PreferenceStore()
    let catalog = Catalog()
    lazy var coordinator = BindingCoordinator(store: store, catalog: { [catalog] in catalog.commands })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        redirectLogsToFile()
        logAccessibilityStatus()
        // Re-install global hotkey handlers for every binding the user previously set.
        // KeyboardShortcuts persists the combo; the coordinator's `.shortcutByNameDidChange`
        // observer disables Carbon's `RegisterEventHotKey` swallow path on every change,
        // so dispatch lives entirely in `HotkeyMonitor` (CGEventTap, frontmost-gated).
        //
        // Seed catalog defaults FIRST, before registering, so first-run installs see
        // the suggested combos already live in the UI. Idempotent — only runs once
        // per install (`Ribbind.didSeedDefaults` UserDefaults flag), and skips any
        // slot the user already bound so existing user choices are never overwritten.
        coordinator.seedDefaultsIfNeeded(catalog: catalog.commands)
        coordinator.registerAllStoredHotkeys(catalog: catalog.commands)
        // CGEventTap priority-over-Office monitor. Accessibility permission required;
        // if not yet granted the tap fails silently and hotkeys are dead until the
        // user grants AX in System Settings — `HotkeyMonitor.scheduleRetryIfNeeded`
        // polls every 2 s and auto-starts on grant, so no relaunch is needed.
        HotkeyMonitor.shared.start()
        // Trigger the Automation TCC prompt for Word and PowerPoint if they're
        // running. Without this, AS dispatches silently fail with -1743 until the
        // user grants Automation permission — and the prompt never surfaces
        // unassisted because Ribbind is a .accessory app. Firing a harmless AS
        // here surfaces the prompt at launch time while the user is still
        // looking at Ribbind.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            Self.primeAutomationTCC()
        }
        NSLog("[Ribbind] launch complete — hotkey handlers wired. Log at %@",
              Self.logPath)
    }

    /// Probe AX + Automation TCC for both Office apps and write the result
    /// to ~/Library/Application Support/Ribbind/permission-state.json so the
    /// ValidationHarness `verify-ribbind-tcc` subcommand can read the truth
    /// without inheriting Terminal's grants. The probe itself doubles as
    /// the TCC primer — sending an AE while Ribbind is foreground (which
    /// it briefly is at launch) is the only way to surface the modal prompt
    /// for an .accessory app.
    static func primeAutomationTCC() {
        let state = PermissionState.probeAndWrite()
        NSLog("[Ribbind] permission-state probed: ax=%@ word=%@ ppt=%@ wordRun=%@ pptRun=%@",
              state.axGranted ? "yes" : "no",
              state.wordAutomation ? "yes" : "no",
              state.pptAutomation ? "yes" : "no",
              state.wordRunning ? "yes" : "no",
              state.pptRunning ? "yes" : "no")
        if !state.axGranted {
            NSLog("[Ribbind] Accessibility missing — open System Settings → Privacy & Security → Accessibility → enable Ribbind. Required for axClick recipes (Format Painter etc.).")
        }
        if state.wordRunning && !state.wordAutomation {
            NSLog("[Ribbind] Automation → Word missing — open Ribbind → Settings → General → Grant Word Automation. Required for Highlight/FontColor.")
        }
        if state.pptRunning && !state.pptAutomation {
            NSLog("[Ribbind] Automation → PowerPoint missing — open Ribbind → Settings → General → Grant PowerPoint Automation. Required for PPT FontColor.")
        }
    }

    /// Pipe stdout / stderr (where NSLog lands) to a persistent file so users and
    /// contributors can `tail -f` it regardless of whether the app was launched from
    /// Finder, the menu bar, or a terminal.
    static let logPath: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("Ribbind.log")
    }()

    /// Record AX state to the log silently. We deliberately DO NOT call the prompting
    /// variant (`AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt`):
    /// ad-hoc code-signing invalidates the TCC grant on every rebuild, so re-prompting
    /// at launch is noise. The General tab's Status section already surfaces the state
    /// and links to the relevant System Settings pane when the grant is missing.
    private func logAccessibilityStatus() {
        NSLog("[Ribbind] Accessibility trusted at launch: %@",
              AXIsProcessTrusted() ? "yes" : "no")
    }

    private func redirectLogsToFile() {
        let path = Self.logPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fp = freopen(path, "a+", stderr) else { return }
        _ = fp
        setvbuf(stderr, nil, _IOLBF, 0)  // line-buffered so `tail -f` sees fresh output
    }
}

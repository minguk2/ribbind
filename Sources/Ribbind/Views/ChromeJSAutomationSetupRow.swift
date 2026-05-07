import SwiftUI
import RibbindKit

/// Setup region at the top of the Google Chrome settings tab. Two stacked
/// rows:
///   1. AS-JS toggle status (the per-profile View > Developer setting)
///   2. Translation model status + initialize-via-user-gesture flow
///
/// Both are required for chrome.Translate to fire end-to-end. They poll Chrome
/// every few seconds so the UI converges as the user completes each step.
struct ChromeJSAutomationSetupRow: View {
    @EnvironmentObject private var store: PreferenceStore
    @EnvironmentObject private var catalog: Catalog
    // Default false — the initial probe runs asynchronously in the first
    // statusTimer fire (~2.5 s after the tab appears) so View init never
    // blocks the main thread on a synchronous Chrome NSAppleScript call.
    @State private var asJsEnabled: Bool = false
    @State private var modelStatus: ChromeJSAutomation.ModelStatus = .unknown
    @State private var downloadProgress: Int? = nil
    @State private var downloadError: String? = nil
    @State private var awaitingClick: Bool = false
    /// The language code we last polled for. When the user changes the target
    /// in the chrome.Translate row, this lags by one tick — the next status /
    /// progress poll picks up the new code from `target` and re-checks.
    @State private var lastPolledTarget: String = "ko"

    /// Live target language: read from chrome.Translate binding's
    /// `targetLanguage` parameter, falling back to the catalog default. Reactive
    /// because PreferenceStore + Catalog are ObservableObjects.
    private var target: String {
        guard let cmd = catalog.commands(for: .chrome).first(where: { $0.id == "chrome.Translate" }) else {
            return "ko"
        }
        return store.binding(for: cmd.id)?.parameters?["targetLanguage"]
            ?? cmd.defaultParameters?["targetLanguage"]
            ?? "ko"
    }

    private var targetDisplay: String {
        ChromeJSAutomation.displayName(forLanguageCode: target)
    }

    private let statusTimer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()
    private let progressTimer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            asJsRow
            if asJsEnabled {
                modelRow
            }
        }
        .onAppear {
            // Initial probe runs once when the Chrome tab first appears, async
            // so View init / layout does NOT block on AppleScript.
            DispatchQueue.global(qos: .userInitiated).async {
                let now = ChromeJSAutomation.isEnabled()
                DispatchQueue.main.async {
                    if now != asJsEnabled { asJsEnabled = now }
                }
            }
        }
    }

    // MARK: - AS-JS row

    private var asJsRow: some View {
        HStack(spacing: 12) {
            Image(systemName: asJsEnabled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(asJsEnabled ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(asJsEnabled
                     ? "Chrome JavaScript automation: enabled"
                     : "Chrome JavaScript automation: disabled")
                    .font(.body)
                    .fontWeight(.medium)
                Text(asJsEnabled
                     ? "Translate Page (⌃⌘T) can dispatch via Chrome's built-in Translator API."
                     : "Required for Translate Page. Click the button → Chrome's View menu opens → click 'Allow JavaScript from Apple Events'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !asJsEnabled {
                Button {
                    ChromeJSAutomation.openEnableMenu()
                } label: {
                    Label("Open Chrome menu", systemImage: "arrow.up.right.square")
                }
                .controlSize(.regular)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((asJsEnabled ? Color.green : Color.orange).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder((asJsEnabled ? Color.green : Color.orange).opacity(0.25), lineWidth: 1)
        )
        .onReceive(statusTimer) { _ in
            // Capture target on main; AS calls below run on background queue so
            // a slow Chrome (or a hung NSAppleScript event) doesn't freeze the
            // app's main thread (which would make the menu bar icon at the
            // top-right of the screen unresponsive).
            let currentTarget = target
            DispatchQueue.global(qos: .userInitiated).async {
                let now = ChromeJSAutomation.isEnabled()
                let avail: ChromeJSAutomation.ModelStatus? = now
                    ? ChromeJSAutomation.translatorAvailability(target: currentTarget)
                    : nil
                DispatchQueue.main.async {
                    if now != asJsEnabled { asJsEnabled = now }
                    if now {
                        if currentTarget != lastPolledTarget {
                            awaitingClick = false
                            downloadProgress = nil
                            downloadError = nil
                        }
                        lastPolledTarget = currentTarget
                        if let s = avail, s != modelStatus { modelStatus = s }
                    }
                }
            }
        }
    }

    // MARK: - Translation model row

    private var modelRow: some View {
        let (icon, color, title, subtitle) = modelDisplay()
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = downloadProgress, !modelReady {
                    ProgressView(value: Double(progress), total: 100)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if modelStatus != .available && !modelReady {
                Button {
                    initializeModel()
                } label: {
                    Label(awaitingClick ? "Waiting for click…" : "Initialize", systemImage: "arrow.down.circle")
                }
                .disabled(awaitingClick)
                .controlSize(.regular)
                .help("Bring Chrome to the front and click anywhere on the active page to start the one-time model download.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.25), lineWidth: 1))
        .onAppear {
            lastPolledTarget = target
            // Async — same reason as the timer below.
            let t = target
            DispatchQueue.global(qos: .userInitiated).async {
                let s = ChromeJSAutomation.translatorAvailability(target: t)
                DispatchQueue.main.async { modelStatus = s }
            }
        }
        .onReceive(progressTimer) { _ in
            guard awaitingClick else { return }
            let t = target
            DispatchQueue.global(qos: .userInitiated).async {
                let s = ChromeJSAutomation.readModelDownloadState(target: t)
                DispatchQueue.main.async {
                    downloadProgress = s.progress
                    downloadError = s.error
                    if s.ready {
                        awaitingClick = false
                        modelStatus = .available
                    }
                    if s.error != nil {
                        awaitingClick = false
                    }
                }
            }
        }
    }

    private var modelReady: Bool {
        modelStatus == .available
    }

    private func modelDisplay() -> (icon: String, color: Color, title: String, subtitle: String) {
        let pretty = targetDisplay
        if modelReady {
            return ("checkmark.seal.fill", .green,
                    "Translation model ready: en → \(pretty)",
                    "Translate Page (⌃⌘T) will translate every text node in place using Chrome's on-device model — no network, no rate limits.")
        }
        if let error = downloadError {
            return ("xmark.octagon.fill", .red,
                    "Translation model: download failed (en → \(pretty))",
                    error)
        }
        if awaitingClick {
            if let p = downloadProgress {
                return ("arrow.down.circle.fill", .blue,
                        "Downloading en → \(pretty)…",
                        "Chrome is downloading the model (\(p)%). Stay on the same Chrome tab until this completes.")
            }
            return ("hand.tap.fill", .blue,
                    "Click anywhere on the Chrome page",
                    "Ribbind has installed a one-shot click listener for the en → \(pretty) model. Click any visible part of Chrome's page to grant the user gesture that the Translator API requires.")
        }
        switch modelStatus {
        case .available:
            return ("checkmark.seal.fill", .green,
                    "Translation model ready: en → \(pretty)",
                    "Translate Page (⌃⌘T) is ready to use.")
        case .downloadable, .downloading:
            return ("exclamationmark.triangle.fill", .orange,
                    "Translation model not downloaded: en → \(pretty)",
                    "Click 'Initialize', then click anywhere on Chrome's active page once. Chrome will download the en → \(pretty) model (~50 MB, one-time per language pair). Change the target in the row below to download a different language.")
        case .unavailable:
            return ("xmark.octagon.fill", .red,
                    "en → \(pretty) not available",
                    "Chrome reports this language pair is unavailable on your device. Pick another target language in the Translate Page row below.")
        case .unknown:
            return ("questionmark.circle.fill", .gray,
                    "Translation model status: unknown",
                    "Chrome may not be running, or JavaScript automation is off. Make sure Chrome is open and the toggle above is green.")
        }
    }

    private func initializeModel() {
        do {
            try ChromeJSAutomation.installModelDownloadClickListener(target: target)
            awaitingClick = true
            downloadProgress = nil
            downloadError = nil
            // Also bring Chrome to the front so the user can click immediately.
            if let chrome = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
                chrome.activate()
            }
        } catch {
            downloadError = String(describing: error)
        }
    }
}

import AppKit  // for NSWorkspace

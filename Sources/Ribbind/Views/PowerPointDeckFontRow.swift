import SwiftUI
import AppKit
import RibbindKit

/// Settings card for "apply one font to a whole deck".
///
/// Not a bindable shortcut on purpose: this is a multi-second operation that brings
/// PowerPoint forward and drives its Replace Fonts dialog, which is the wrong shape
/// for a hotkey that could be hit by accident on the wrong document.
///
/// All PowerPoint work runs on a dedicated **serial** background queue — serial so
/// two runs can never interleave on one dialog, and background because a multi-second
/// AX drive on the main actor would freeze Ribbind's menu-bar icon.
struct PowerPointDeckFontRow: View {
    @State private var presentations: [PowerPointFontReplacer.Presentation] = []
    @State private var selectedPresentationID: String?
    @State private var fonts: [String] = []
    @State private var fontSearch: String = ""
    @State private var selectedFont: String = ""
    @State private var setThemeFonts = true
    @State private var includeGroups = true

    @State private var running = false
    @State private var progress: PowerPointFontReplacer.Progress?
    @State private var lastHeartbeat = Date()
    @State private var stalled = false
    @State private var result: ResultSummary?

    private static let queue = DispatchQueue(label: "com.minguk2.ribbind.deckfont", qos: .userInitiated)
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let watchdog = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    struct ResultSummary: Equatable {
        let ok: Bool
        let headline: String
        let detail: String
    }

    private var selectedPresentation: PowerPointFontReplacer.Presentation? {
        presentations.first { $0.id == selectedPresentationID } ?? presentations.first
    }

    private var filteredFonts: [String] {
        guard !fontSearch.isEmpty else { return fonts }
        return fonts.filter { $0.localizedCaseInsensitiveContains(fontSearch) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            deckPicker
            fontPicker
            Toggle("Also set the theme's heading and body fonts", isOn: $setThemeFonts)
                .disabled(running || includeGroups)
                .help("So text you type later matches too, instead of reverting to the deck's original theme font.")
            Toggle("Include text inside grouped shapes (saves, rewrites and reopens the file)", isOn: $includeGroups)
                .disabled(running)
                .help("PowerPoint's scripting can't reach inside groups. Turning this on edits the .pptx directly instead — nothing pops up, but the deck is saved, closed and reopened, so PowerPoint's undo history is lost. A timestamped backup is written next to the file.")
            actionRow
            if running { progressBlock }
            if let result { resultBlock(result) }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25)))
        )
        .onAppear { refreshPresentations(); loadFonts() }
        .onReceive(refreshTimer) { _ in if !running { refreshPresentations() } }
        .onReceive(watchdog) { _ in
            guard running else { stalled = false; return }
            stalled = Date().timeIntervalSince(lastHeartbeat) > 30
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "textformat")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replace every font in a deck").fontWeight(.medium)
                Text("Applies the font to every slide in the background. No dialog opens and PowerPoint is not brought forward. With the option below on, it rewrites the .pptx directly so nothing is missed — including text inside grouped shapes, which PowerPoint's scripting cannot reach. With it off, it writes through PowerPoint instead: undo still works, but grouped shapes are skipped and counted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deckPicker: some View {
        HStack(spacing: 8) {
            Text("Deck").frame(width: 46, alignment: .leading)
            if presentations.isEmpty {
                Text("No presentation open in PowerPoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { selectedPresentation?.id ?? "" },
                    set: { selectedPresentationID = $0 }
                )) {
                    ForEach(presentations) { deck in
                        Text(deck.isSaved ? deck.name : "\(deck.name)  (unsaved)").tag(deck.id)
                    }
                }
                .labelsHidden()
                .disabled(running)
                if let folder = selectedPresentation?.folder, !folder.isEmpty {
                    Text(folder)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
        }
    }

    private var fontPicker: some View {
        HStack(spacing: 8) {
            Text("Font").frame(width: 46, alignment: .leading)
            TextField("Search fonts…", text: $fontSearch)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .disabled(running)
            Picker("", selection: $selectedFont) {
                Text("Choose…").tag("")
                ForEach(filteredFonts, id: \.self) { family in
                    Text(family).font(.custom(family, size: 12)).tag(family)
                }
            }
            .labelsHidden()
            .frame(width: 240)
            .disabled(running || fonts.isEmpty)
            Text("\(fonts.count) fonts")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Apply to every slide") { start() }
                .buttonStyle(.borderedProminent)
                .disabled(running || selectedFont.isEmpty || selectedPresentation == nil
                          || (includeGroups && !(selectedPresentation?.isSaved ?? false)))
            Text(includeGroups && !(selectedPresentation?.isSaved ?? true)
                 ? "Save the deck first — rewriting the file needs it on disk."
                 : "Applies in the background — PowerPoint is not brought forward and no dialog opens.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .frame(maxWidth: 320)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(stalled
                 ? "PowerPoint isn't responding. You can cancel."
                 : (progress?.message ?? "Working…"))
                .font(.caption)
                .foregroundStyle(stalled ? .orange : .secondary)
        }
    }

    private func resultBlock(_ summary: ResultSummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: summary.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(summary.ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.headline).font(.caption).fontWeight(.medium)
                Text(summary.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func refreshPresentations() {
        guard OfficeAppProbe.isRunning(.powerpoint) else {
            presentations = []
            return
        }
        Self.queue.async {
            let found = (try? PowerPointFontReplacer.listOpenPresentations()) ?? []
            DispatchQueue.main.async {
                presentations = found
                if selectedPresentationID == nil { selectedPresentationID = found.first?.id }
            }
        }
    }

    /// Populate the picker from the system + Office's bundled font files.
    ///
    /// Deliberately NOT read out of PowerPoint's Replace Fonts dialog: doing that
    /// means opening that dialog on screen just to read a list, which is a window
    /// the user never asked for. This list is the same set PowerPoint's own font
    /// menu shows, and the apply step still verifies the choice against PowerPoint
    /// (the "With:" value is read back and must match exactly), so a font PowerPoint
    /// won't accept fails loudly instead of silently doing the wrong thing.
    private func loadFonts() {
        guard fonts.isEmpty else { return }
        Self.queue.async {
            let families = OfficeFontCatalog.availableFontFamilies()
            DispatchQueue.main.async { fonts = families }
        }
    }

    private func start() {
        guard let deck = selectedPresentation, !selectedFont.isEmpty else { return }
        running = true
        result = nil
        stalled = false
        lastHeartbeat = Date()
        let target = selectedFont
        let theme = setThemeFonts
        let exhaustive = includeGroups

        Self.queue.async {
            do {
                // Silent path: writes fonts through AppleScript with no PowerPoint
                // window and no focus stealing. `run(...)` (which drives
                // PowerPoint's own Replace Fonts dialog) reaches inside grouped
                // shapes too, but pops that dialog on screen, so it is not what a
                // one-click action should do.
                let onProgress: (PowerPointFontReplacer.Progress) -> Void = { update in
                    DispatchQueue.main.async {
                        progress = update
                        lastHeartbeat = Date()
                    }
                }
                // Two silent paths. The file rewrite is the only one that reaches
                // text inside grouped shapes; the AppleScript one keeps the undo
                // stack and never touches the file on disk.
                let report = exhaustive
                    ? try PowerPointFontReplacer.applyByRewritingFile(
                        target: target, presentation: deck, progress: onProgress)
                    : try PowerPointFontReplacer.applySilently(
                        target: target, presentation: deck, setThemeFonts: theme, progress: onProgress)
                DispatchQueue.main.async { finish(report) }
            } catch {
                DispatchQueue.main.async {
                    running = false
                    progress = nil
                    result = ResultSummary(
                        ok: false,
                        headline: "Couldn't finish",
                        detail: String(describing: error)
                    )
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private func finish(_ report: PowerPointFontReplacer.Report) {
        running = false
        progress = nil
        var parts: [String] = []
        if report.replaced.isEmpty {
            parts.append("Nothing needed replacing — the deck already used only \(report.target).")
        } else {
            parts.append("Replaced \(report.replaced.count) font(s): \(report.replaced.joined(separator: ", ")).")
        }
        if !report.failed.isEmpty {
            parts.append("Not replaced: \(report.failed.joined(separator: ", ")).")
        }
        if !report.themeSlots.isEmpty {
            parts.append("Theme fonts updated.")
        }
        if !report.themeFailures.isEmpty {
            parts.append("Theme fonts: \(report.themeFailures.joined(separator: ", ")).")
        }
        if let before = report.usedFontsBefore, let after = report.usedFontsAfter {
            parts.append("Fonts in use \(before) → \(after).")
        }
        if !report.replaced.isEmpty {
            parts.append("Undo with ⌘Z in PowerPoint (\(report.replaced.count)×).")
        }
        result = ResultSummary(
            ok: report.isComplete,
            headline: report.isComplete
                ? "Every slide now uses \(report.target)"
                : "Finished with exceptions",
            detail: parts.joined(separator: " ")
        )
        // Bring Ribbind back so the user reads the result instead of staring at
        // PowerPoint wondering whether anything happened.
        NSApp.activate(ignoringOtherApps: true)
    }
}

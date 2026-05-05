import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import ApplicationServices
import RibbindKit

struct GeneralView: View {
    @EnvironmentObject private var store: PreferenceStore
    @EnvironmentObject private var coordinator: BindingCoordinator
    @EnvironmentObject private var catalog: Catalog
    @AppStorage("launchOnLogin") private var launchOnLogin: Bool = false
    @State private var importError: String?
    @State private var lastImportSummary: String?
    @State private var exporter: Bool = false
    @State private var importer: Bool = false
    @State private var exportDocument: BindingsExportDocument = .empty
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()
    @State private var grantStatus: String? = nil
    private let accessibilityTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(label: "Accessibility",
                              ok: accessibilityGranted,
                              detail: "Required so Ribbind can intercept your bound key combos before Word/PowerPoint sees them, and click Format Painter / Shape buttons in the Ribbon.")

                HStack(spacing: 8) {
                    Button("Re-grant Accessibility") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                        grantStatus = "Opened System Settings → Accessibility. Remove the existing Ribbind entry, then add /Applications/Ribbind.app fresh (cdhash rotates on every rebuild)."
                    }
                    .help("Opens System Settings. AX permission must be re-granted after every rebuild because the ad-hoc cdhash changes.")
                    Button("Re-check") {
                        let st = PermissionState.probeAndWrite()
                        accessibilityGranted = st.axGranted
                        grantStatus = "Re-checked: Accessibility = \(st.axGranted ? "granted ✓" : "missing ✗")"
                    }
                    Button("Test Dispatch") {
                        Task { await runTestDispatch() }
                    }
                    .help("Fires Word's Format Painter through Ribbind's actual dispatch path and reads back the brush state — confirms the AX click chain works end-to-end without you having to press a combo.")
                }

                if let g = grantStatus {
                    Text(g).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Office detection") {
                officeRow(label: "Microsoft Word", target: .word)
                officeRow(label: "Microsoft PowerPoint", target: .powerpoint)
                Text("First time you press a color or shape shortcut, macOS will ask whether to allow Ribbind to control Word/PowerPoint. Click \"OK\" — that's the only extra setup. Subsequent presses are instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchOnLogin)
                    .onChange(of: launchOnLogin) { _, newValue in
                        applyLaunchOnLogin(newValue)
                    }
                Text("Status: \(launchAgentStatusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                HStack {
                    Button("Import shortcuts…") {
                        importer = true
                    }
                    Button("Export shortcuts…") {
                        exportDocument = BindingsExportDocument(bindings: store.bindings)
                        exporter = true
                    }
                }
                if let summary = lastImportSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if let error = importError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button(role: .destructive) {
                    store.removeAll()
                } label: {
                    Text("Restore defaults (removes all shortcuts)")
                }
            }

            Section("Support this project") {
                Text("Ribbind is free and open source. If it saves you time, consider supporting continued development.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("☕ Support on Ko-fi", destination: URL(string: "https://ko-fi.com/minguk2")!)
            }

            Section("About") {
                Text("Ribbind assigns keyboard shortcuts to Microsoft Word and PowerPoint commands — including Ribbon-only commands that macOS System Settings cannot reach.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(versionString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Project on GitHub", destination: URL(string: "https://github.com/minguk2/ribbind")!)
                }
            }
        }
        .formStyle(.grouped)
        .fileExporter(
            isPresented: $exporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Ribbind-bindings.json"
        ) { _ in }
        .fileImporter(
            isPresented: $importer,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    guard url.startAccessingSecurityScopedResource() else {
                        importError = "Permission denied"
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let data = try Data(contentsOf: url)
                    try store.importJSON(data)
                    lastImportSummary = "Imported \(store.bindings.count) bindings"
                    importError = nil
                } catch {
                    importError = "Import failed: \(error.localizedDescription)"
                }
            case .failure(let err):
                importError = "Import cancelled: \(err.localizedDescription)"
            }
        }
        .onAppear {
            launchOnLogin = (SMAppService.mainApp.status == .enabled)
            accessibilityGranted = AXIsProcessTrusted()
        }
        .onReceive(accessibilityTimer) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    /// Office presence + version row — surfaces "not installed" / "MAS variant"
    /// distinctions that the rest of the app silently swallows. This is what
    /// catches users on alternate-disk installs and Mac App Store Office where
    /// the old hardcoded /Applications path missed them.
    @ViewBuilder
    private func officeRow(label: String, target: AppTarget) -> some View {
        let installed = OfficeAppProbe.isInstalled(target)
        let version   = OfficeAppProbe.version(for: target)
        let isMAS     = installed ? OfficeAppProbe.isMacAppStoreInstall(target) : false
        let path      = OfficeAppProbe.bundlePath(for: target)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(installed ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout)
                if installed {
                    Text("Detected v\(version ?? "?")\(isMAS ? " · Mac App Store" : "") · \(path)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not detected. Bound \(label) commands will not fire until \(label) is installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return "v\(v)"
    }

    private var launchAgentStatusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not registered"
        case .notFound: return "Not found"
        case .requiresApproval: return "Requires user approval in System Settings"
        @unknown default: return "Unknown"
        }
    }

    private func applyLaunchOnLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch on login change failed: \(error)")
        }
    }

    /// Single-line permission status with a checkmark / warning glyph + caption.
    @ViewBuilder
    private func permissionRow(label: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// End-to-end smoke from inside Ribbind. Tries word.FormatPainter via
    /// the coordinator's actual dispatch path. Reports on a real key-press
    /// equivalent without requiring the user to actually press the bound
    /// combo.
    @MainActor
    private func runTestDispatch() async {
        // Don't simulate a keystroke — instead invoke the same dispatch
        // function Carbon's onKeyDown calls, which goes through the user's
        // real frontmost-gate + recipe chain.
        let catalog = Catalog()
        guard let cmd = catalog.commands.first(where: { $0.id == "word.FormatPainter" }) else {
            grantStatus = "Test dispatch skipped — word.FormatPainter not in catalog."
            return
        }
        // Bring Word to front first so the frontmost gate accepts the dispatch.
        let ws = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.microsoft.Word"
        }
        if let ws { ws.activate(options: [.activateAllWindows]) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        BindingCoordinator.dispatchNow(command: cmd)
        try? await Task.sleep(nanoseconds: 800_000_000)

        // Check Word's Format Painter button AX value.
        let value = formatPainterAxValue()
        switch value {
        case 1?: grantStatus = "✓ Test dispatch succeeded — Word's Format Painter brush is engaged. The full dispatch path works for axClick recipes."
        case 0?: grantStatus = "✗ Test dispatch fired but the brush did NOT engage. Check ~/Library/Logs/Ribbind.log for `axClick fire failed`."
        default: grantStatus = "? Couldn't read Word's Format Painter AX state — likely AX permission missing for this Ribbind build."
        }
    }

    private func formatPainterAxValue() -> Int? {
        guard AXIsProcessTrusted() else { return nil }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.microsoft.Word"
        }) else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        var stack: [(AXUIElement, Int)] = [(app, 0)]
        while let (node, depth) = stack.popLast() {
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            var help: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(node, kAXHelpAttribute as CFString, &help)
            if let r = role as? String, r == kAXCheckBoxRole as String,
               let h = help as? String, h.contains("Copy formatting from one location") {
                var v: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &v)
                return (v as? NSNumber)?.intValue
            }
            if depth >= 25 { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let arr = children as? [AXUIElement] {
                for c in arr { stack.append((c, depth + 1)) }
            }
        }
        return nil
    }
}

struct BindingsExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    static let writableContentTypes: [UTType] = [.json]

    let data: Data

    static let empty = BindingsExportDocument(bindings: [:])

    init(bindings: [String: ShortcutBinding]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.data = (try? encoder.encode(bindings)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

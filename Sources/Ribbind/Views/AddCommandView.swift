import SwiftUI
import AppKit
import ApplicationServices
import RibbindKit

/// Discovered element surfaced by the AX scanner. `tabName` is populated when the
/// element was seen while a Ribbon tab was active; nil for menu-bar items.
struct ScannedCommand: Identifiable, Hashable {
    let id = UUID()
    let role: String
    let title: String
    let help: String
    let description: String
    let tabName: String?          // nil for menu-bar items
    let menuPath: [String]        // empty for Ribbon items

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !description.isEmpty { return description }
        return "(no title)"
    }

    var subtitle: String {
        var bits: [String] = []
        if let t = tabName { bits.append("Ribbon › \(t)") }
        if !menuPath.isEmpty { bits.append("Menu › \(menuPath.joined(separator: " › "))") }
        if !help.isEmpty { bits.append(help) }
        return bits.joined(separator: "  ·  ")
    }
}

/// Sheet that walks the running Office app's UI and lets the user pick a command to
/// add as a bindable shortcut. Writes the chosen command to the shared
/// `UserCatalogStore` (persisted to `~/Library/Application Support/Ribbind/
/// user-commands.json`), whereupon `Catalog` re-merges and the new row appears in
/// `AppShortcutsView`.
struct AddCommandView: View {
    let app: AppTarget
    @EnvironmentObject private var catalog: Catalog
    @Environment(\.dismiss) private var dismiss

    @State private var isScanning = false
    @State private var scanProgress = ""
    @State private var scanned: [ScannedCommand] = []
    @State private var searchText = ""
    @State private var selection: ScannedCommand.ID?

    @State private var editLabel = ""
    @State private var editCategory = "Custom"

    /// Ribbon tabs we'll iterate during the scan. This list covers Word + PowerPoint
    /// default tabs; non-existent tab names simply no-op in `activateTab`.
    private let tabsToScan: [String]

    init(app: AppTarget) {
        self.app = app
        switch app {
        case .word:
            self.tabsToScan = ["Home", "Insert", "Design", "Layout",
                               "References", "Mailings", "Review", "View"]
        case .powerpoint:
            self.tabsToScan = ["Home", "Insert", "Design", "Transitions",
                               "Animations", "Slide Show", "Review", "View"]
        case .chrome:
            // Chrome has no Ribbon — only walk the menu bar (still useful for
            // adding bookmark / history menu items as shortcuts).
            self.tabsToScan = []
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add a command from \(app.processName)")
                    .font(.title2)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            TextField("Search discovered commands…", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(scanProgress).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HSplitView {
                // Left: discovered commands list.
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayTitle).font(.body)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(item.id)
                    }
                }
                .frame(minWidth: 360, idealWidth: 420)

                // Right: detail + commit.
                VStack(alignment: .leading, spacing: 10) {
                    if let sel = selected {
                        Text(sel.displayTitle).font(.headline)
                        Text(sel.subtitle).font(.caption).foregroundStyle(.secondary)
                        Divider()
                        LabeledContent("Label") {
                            TextField("Label shown in Ribbind", text: $editLabel)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Category") {
                            TextField("Category header", text: $editCategory)
                                .textFieldStyle(.roundedBorder)
                        }
                        Spacer(minLength: 8)
                        HStack {
                            Spacer()
                            Button("Add to Ribbind") { commit(sel) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(editLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } else {
                        Text("Pick a command on the left to capture a locator for it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 260)
            }
            .frame(minHeight: 360)
        }
        .padding(16)
        .frame(minWidth: 780, minHeight: 500)
        .onAppear { Task { await scan() } }
        .onChange(of: selection) { _, newId in
            if let item = scanned.first(where: { $0.id == newId }) {
                editLabel = item.displayTitle
                editCategory = "Custom"
            }
        }
    }

    private var selected: ScannedCommand? {
        guard let sid = selection else { return nil }
        return scanned.first { $0.id == sid }
    }

    private var filtered: [ScannedCommand] {
        guard !searchText.isEmpty else { return scanned }
        return scanned.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                || $0.help.localizedCaseInsensitiveContains(searchText)
                || $0.subtitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Scan

    @MainActor
    private func scan() async {
        isScanning = true
        scanProgress = "Activating \(app.processName)…"

        do { try RibbonButtonClicker.activate(app) } catch {
            scanProgress = "Could not activate \(app.processName) — is it running?"
            isScanning = false
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Menu-bar walk (cheap, one-shot).
        scanProgress = "Walking menu bar…"
        let menuItems = (try? RibbonButtonClicker.enumerateMenuItems(inApp: app)) ?? []
        var collected: [ScannedCommand] = menuItems.map { item in
            ScannedCommand(role: "AXMenuItem", title: item.title, help: "",
                           description: "", tabName: nil, menuPath: item.menuPath)
        }

        // Ribbon walk: for each tab, activate it, enumerate, attach tabName.
        for tab in tabsToScan {
            scanProgress = "Walking Ribbon tab › \(tab)…"
            let activated = RibbonButtonClicker.activateTab(name: tab, inApp: app)
            // Even if activateTab returns false (Ribbon collapsed, tab missing), enumerate
            // the currently-rendered Ribbon — we'll just get fewer results for that tab.
            let els = (try? RibbonButtonClicker.enumerateElements(inApp: app)) ?? []
            for e in els {
                // Ignore noise: elements with empty everything, Application / Window /
                // Standard Window roles, etc. These aren't useful dispatch targets.
                let skipRoles: Set<String> = ["AXApplication", "AXWindow", "AXGroup",
                                              "AXScrollArea", "AXScrollBar", "AXToolbar"]
                if skipRoles.contains(e.role) { continue }
                if e.title.isEmpty && e.description.isEmpty && e.help.isEmpty { continue }
                collected.append(ScannedCommand(
                    role: e.role, title: e.title, help: e.help, description: e.description,
                    tabName: activated ? tab : nil, menuPath: []
                ))
            }
        }

        // Dedupe: same (role, title, help, tabName) collapses to one entry.
        var seen = Set<String>()
        scanned = collected.filter { c in
            let key = "\(c.role)|\(c.title)|\(c.help)|\(c.tabName ?? "")"
            return seen.insert(key).inserted
        }
        .sorted { ($0.tabName ?? "") < ($1.tabName ?? "") || $0.displayTitle < $1.displayTitle }

        scanProgress = "Found \(scanned.count) command(s)."
        isScanning = false
    }

    // MARK: - Commit

    private func commit(_ item: ScannedCommand) {
        // Build a command id that's unique and predictable: app + sanitised title.
        let slug = (item.title.isEmpty ? "custom-\(UUID().uuidString.prefix(6))" :
                    item.title.filter { $0.isLetter || $0.isNumber })
        let id = "\(app.rawValue).User.\(slug)"

        // Dispatch recipe: AX click with the locator we captured. At least one of
        // title/help/description must be non-empty (axClick decoder enforces this).
        let recipe: DispatchRecipe
        if !item.menuPath.isEmpty {
            // It's a menu item — press via the existing menu-bar handler.
            // We model this via nsUserKeyEquivalent which runs pressMenuItem.
            recipe = .nsUserKeyEquivalent(menuTitle: item.title)
        } else {
            recipe = .axClick(
                role: item.role,
                titleContains: item.title.isEmpty ? nil : item.title,
                helpContains: item.help.isEmpty ? nil : item.help,
                descriptionContains: item.description.isEmpty ? nil : item.description,
                tabName: item.tabName
            )
        }

        let cmd = Command(
            id: id,
            app: app,
            label: editLabel.trimmingCharacters(in: .whitespaces),
            category: editCategory.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom" : editCategory,
            dispatchRecipes: [recipe],
            notes: "Added via Add-from-app picker on \(Date().formatted(.iso8601))"
        )
        catalog.userStore.add(cmd)
        dismiss()
    }
}

import SwiftUI
import RibbindKit

enum CommandFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unbound = "Without shortcut"
    case bound = "With shortcut"

    var id: String { rawValue }
}

/// Adaptive-grid layout: each category is rendered as a labelled block containing a
/// LazyVGrid whose column count is computed from the window width (min 320pt per
/// item). Big window → many columns in a given category; narrow window → one. This
/// replaces the v0.4.x "alternate by index across two fixed columns" scheme.
struct AppShortcutsView: View {
    let app: AppTarget
    @EnvironmentObject private var catalog: Catalog
    @EnvironmentObject private var store: PreferenceStore
    @EnvironmentObject private var coordinator: BindingCoordinator
    @State private var searchText: String = ""
    @State private var filter: CommandFilter = .all
    @State private var showingAddSheet = false

    var body: some View {
        VStack(spacing: 10) {
            if app == .chrome {
                ChromeJSAutomationSetupRow()
            }
            // Search + filter + "Add from app" controls only make sense for
            // Office apps (Word / PowerPoint) where the catalog has dozens of
            // commands and users may want to scan the Ribbon for more. The
            // Chrome tab currently ships a single command and isn't extensible
            // via Ribbon scanning, so the controls are hidden there.
            if app != .chrome {
                HStack(spacing: 10) {
                    TextField("Search commands…", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Picker("Filter", selection: $filter) {
                        ForEach(CommandFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)

                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add from \(app.processName.replacingOccurrences(of: "Microsoft ", with: ""))…",
                              systemImage: "plus.magnifyingglass")
                    }
                    .help("Scan the running Office app's Ribbon and menu bar and add one of its commands to Ribbind.")
                }
                .padding(.horizontal, 4)
            }

            Divider()

            if catalog.commands.isEmpty {
                ContentUnavailableView(
                    "No commands loaded",
                    systemImage: "questionmark.folder",
                    description: Text(catalog.loadError ?? "commands.json is empty or missing.")
                )
                .frame(maxHeight: .infinity)
            } else if groupedFiltered.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("Try clearing the search or filter.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(groupedFiltered, id: \.category) { entry in
                            categoryBlock(entry)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            }

            HStack {
                Text("\(filteredCount) of \(catalog.commands(for: app).count) commands  ·  \(boundCount) bound")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddCommandView(app: app)
                .environmentObject(catalog)
        }
    }

    /// One category = header + adaptive grid of its rows. Columns reflow freely based
    /// on window width (320pt min per row). Categories that have 1 item render as a
    /// single column; categories with 10 items render as 2–4 depending on width.
    private func categoryBlock(_ entry: (category: String, items: [Command])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.category.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 340), spacing: 18, alignment: .top)],
                alignment: .leading,
                spacing: 2
            ) {
                ForEach(entry.items) { cmd in
                    ShortcutRow(command: cmd)
                }
            }
        }
    }

    private var groupedFiltered: [(category: String, items: [Command])] {
        let source = catalog.commands(for: app)
            .filter { matchesFilter($0) && matchesSearch($0) }
        let byCat = Dictionary(grouping: source) { $0.category }
        return byCat
            .map { (category: $0.key, items: $0.value.sorted { $0.label < $1.label }) }
            .sorted { $0.category < $1.category }
    }

    private func matchesSearch(_ cmd: Command) -> Bool {
        guard !searchText.isEmpty else { return true }
        return cmd.label.localizedCaseInsensitiveContains(searchText)
            || cmd.id.localizedCaseInsensitiveContains(searchText)
            || (cmd.idMso?.localizedCaseInsensitiveContains(searchText) ?? false)
    }

    private func matchesFilter(_ cmd: Command) -> Bool {
        switch filter {
        case .all: return true
        case .bound: return store.binding(for: cmd.id) != nil
        case .unbound: return store.binding(for: cmd.id) == nil
        }
    }

    private var filteredCount: Int {
        groupedFiltered.reduce(0) { $0 + $1.items.count }
    }

    private var boundCount: Int {
        catalog.commands(for: app).reduce(0) { acc, c in
            acc + (store.binding(for: c.id) != nil ? 1 : 0)
        }
    }
}

import Foundation
import Combine

/// Union of the bundled command catalog and the user-added catalog. User entries
/// shadow bundled entries on id collision (so users can redefine behaviour without
/// losing their hotkey). Reloaded by calling `load()` or by observing the user
/// store's publisher.
@MainActor
public final class Catalog: ObservableObject {
    @Published public private(set) var commands: [Command] = []
    @Published public private(set) var loadError: String?

    public let userStore: UserCatalogStore
    private var bundledCommands: [Command] = []
    private var userCommandsObserver: AnyCancellable?

    /// Convenience initializer for callers that don't want to own the user store —
    /// spins up a default one backed by the standard Application Support file.
    public convenience init() {
        self.init(userStore: UserCatalogStore())
    }

    public init(userStore: UserCatalogStore) {
        self.userStore = userStore
        load()
        // Any time the user adds/removes via the picker, re-merge.
        userCommandsObserver = userStore.$commands
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.merge() }
            }
    }

    public func load() {
        // ResourceLookup bypasses SPM's auto-generated `Bundle.module` accessor.
        // The accessor falls back to an absolute `.build/...` path baked at
        // compile time, which exists on the builder's machine but NOT on a
        // user's Mac who downloaded the .app from GitHub Releases — that
        // mismatch crashed v0.6.1's first CI build at launch. See the
        // helper's docs for the candidate-path resolution order.
        guard let url = ResourceLookup.url(
            in: "Ribbind_RibbindKit.bundle",
            forResource: "commands",
            withExtension: "json"
        ) else {
            loadError = "commands.json not found in bundle"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            bundledCommands = try JSONDecoder().decode([Command].self, from: data)
            loadError = nil
            merge()
        } catch {
            loadError = "Failed to decode commands.json: \(error.localizedDescription)"
            bundledCommands = []
            commands = []
        }
    }

    /// Recompute the merged list from the current bundled + user sources.
    private func merge() {
        var byId: [String: Command] = [:]
        for cmd in bundledCommands { byId[cmd.id] = cmd }
        // User entries win on collision.
        for cmd in userStore.commands { byId[cmd.id] = cmd }
        commands = Array(byId.values).sorted { $0.id < $1.id }
    }

    public func commands(for app: AppTarget) -> [Command] {
        commands.filter { $0.app == app }
    }

    public func categories(for app: AppTarget) -> [String] {
        Array(Set(commands(for: app).map { $0.category })).sorted()
    }
}

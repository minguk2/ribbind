import Foundation

/// Persistent store for commands the user added via the "Add from Word/PowerPoint"
/// picker. Stored as a JSON array at `~/Library/Application Support/Ribbind/user-
/// commands.json`. Loaded on Catalog init and merged with the bundled catalog;
/// user entries shadow bundled ones on id collision.
@MainActor
public final class UserCatalogStore: ObservableObject {
    @Published public private(set) var commands: [Command] = []

    public static let storeFilename = "user-commands.json"

    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Ribbind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(storeFilename)
    }

    public func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            commands = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            commands = try JSONDecoder().decode([Command].self, from: data)
        } catch {
            NSLog("[Ribbind] UserCatalogStore.load failed — resetting empty: %@", String(describing: error))
            commands = []
        }
    }

    public func add(_ command: Command) {
        commands.removeAll { $0.id == command.id }
        commands.append(command)
        save()
    }

    public func remove(id: String) {
        commands.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(commands)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Ribbind] UserCatalogStore.save failed: %@", String(describing: error))
        }
    }
}

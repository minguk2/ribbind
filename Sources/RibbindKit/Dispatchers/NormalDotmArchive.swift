import Foundation

/// Minimal ZIP read/write helper for `Normal.dotm`. Shells out to macOS's bundled
/// `/usr/bin/unzip` and `/usr/bin/zip` — no third-party archive dep needed.
public enum NormalDotmArchive {
    public enum Failure: Error, CustomStringConvertible {
        case notFound(String)
        case unzipFailed(String)
        case zipFailed(String)
        case ioFailed(String)

        public var description: String {
            switch self {
            case .notFound(let p): return "Normal.dotm not found at \(p)"
            case .unzipFailed(let s): return "unzip failed: \(s)"
            case .zipFailed(let s): return "zip failed: \(s)"
            case .ioFailed(let s): return "IO failed: \(s)"
            }
        }
    }

    public static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Templates.localized/Normal.dotm"
    }()

    public static let customizationsXMLEntry = "word/customizations.xml"

    /// Read the contents of a single entry from the .dotm ZIP.
    public static func readEntry(_ entry: String, from dotmPath: String = defaultPath) throws -> Data {
        guard FileManager.default.fileExists(atPath: dotmPath) else {
            throw Failure.notFound(dotmPath)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", dotmPath, entry]
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { throw Failure.ioFailed(String(describing: error)) }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let msg = String(data: (try? err.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? "unknown"
            throw Failure.unzipFailed(msg)
        }
        return (try? out.fileHandleForReading.readToEnd()) ?? Data()
    }

    /// Read the `word/customizations.xml` as UTF-8 text.
    public static func readCustomizationsXML(from dotmPath: String = defaultPath) throws -> String {
        let data = try readEntry(customizationsXMLEntry, from: dotmPath)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Replace a single entry inside the ZIP. Works by unzipping to a temp dir, writing
    /// the new entry file, and zipping back with `-X -D` (no extras, no dir entries) to
    /// preserve the Office-compatible structure.
    public static func replaceEntry(_ entry: String, with data: Data, at dotmPath: String = defaultPath) throws {
        guard FileManager.default.fileExists(atPath: dotmPath) else {
            throw Failure.notFound(dotmPath)
        }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ribbind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try runProcess("/usr/bin/unzip", ["-q", dotmPath, "-d", tmpDir.path])

        let entryURL = tmpDir.appendingPathComponent(entry)
        try FileManager.default.createDirectory(
            at: entryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: entryURL, options: .atomic)

        // Make a backup on first replace-attempt.
        let backup = dotmPath + ".bak"
        if !FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: dotmPath, toPath: backup)
        }

        let newDotm = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ribbind-rewrite-\(UUID().uuidString).dotm")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tmpDir
        zip.arguments = ["-r", "-q", "-X", "-D", newDotm.path, "."]
        let zipErr = Pipe()
        zip.standardError = zipErr
        do { try zip.run() } catch { throw Failure.ioFailed(String(describing: error)) }
        zip.waitUntilExit()
        if zip.terminationStatus != 0 {
            let msg = String(data: (try? zipErr.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? "unknown"
            throw Failure.zipFailed(msg)
        }

        // Atomic swap: if the move fails partway we want the original file intact, never
        // a half-replaced file. `replaceItemAt` uses the platform's atomic rename path.
        let dotmURL = URL(fileURLWithPath: dotmPath)
        _ = try FileManager.default.replaceItemAt(dotmURL, withItemAt: newDotm)
    }

    private static func runProcess(_ path: String, _ args: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let err = Pipe()
        task.standardError = err
        do { try task.run() } catch { throw Failure.ioFailed(String(describing: error)) }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let msg = String(data: (try? err.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? "unknown"
            throw Failure.unzipFailed(msg)
        }
    }
}

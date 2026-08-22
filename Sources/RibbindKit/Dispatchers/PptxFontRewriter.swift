import Foundation

/// Rewrites every font reference inside a `.pptx` file directly.
///
/// This is the only path that is **both** silent (no PowerPoint window opens) and
/// genuinely exhaustive. PowerPoint's scripting cannot reach text inside grouped
/// shapes at all — indexing a group's children fails `-1700`/`-1728`, `group items`
/// fails `-1708`, and a bulk `every shape` set fails `-10006` (all verified against
/// PowerPoint 16.112). Its own `Format ▸ Replace Fonts…` does reach them, but only
/// as a visible dialog.
///
/// A `.pptx` is a ZIP of XML parts, and a grouped shape (`<p:grpSp>`) stores its
/// children's runs inline with their own `<a:latin typeface="…"/>` attributes. So
/// rewriting the XML covers groups, tables, notes, masters, layouts and the theme
/// in one pass, with no dependency on PowerPoint's object model.
///
/// The cost, which callers must surface: PowerPoint holds the document in memory,
/// so the file has to be saved and closed before the rewrite and reopened after.
/// That discards the undo stack.
public enum PptxFontRewriter {

    public enum Failure: Error, CustomStringConvertible {
        case notFound(String)
        case notAPptx(String)
        case unzipFailed(String)
        case zipFailed(String)
        case ioFailed(String)

        public var description: String {
            switch self {
            case .notFound(let p): return "File not found: \(p)"
            case .notAPptx(let p): return "Not a .pptx file: \(p)"
            case .unzipFailed(let s): return "Could not read the .pptx: \(s)"
            case .zipFailed(let s): return "Could not rewrite the .pptx: \(s)"
            case .ioFailed(let s): return "File error: \(s)"
            }
        }
    }

    public struct Summary: Sendable {
        public let target: String
        /// XML parts touched, e.g. "ppt/slides/slide3.xml".
        public let changedParts: [String]
        /// Total `typeface="…"` attributes rewritten.
        public let rewrittenAttributes: Int
        /// Distinct font names that were replaced.
        public let replacedFonts: [String]
        public let backupPath: String?
    }

    // MARK: - Pure transform (unit-testable, no Office, no filesystem)

    /// Attributes that name a font in DrawingML.
    /// `latin` / `ea` / `cs` cover Latin, East-Asian and complex-script runs;
    /// `sym` covers symbol runs. All four appear in run properties, list styles,
    /// table styles and the theme's font scheme.
    static let fontElements = ["a:latin", "a:ea", "a:cs", "a:sym"]

    /// Theme placeholders. A run that says `+mj-lt` inherits the theme's major
    /// (heading) font rather than naming one, so it must be LEFT ALONE — rewriting
    /// it to a literal name would strip the deck's theme inheritance. Setting the
    /// theme fonts themselves (done separately) is what makes those runs follow.
    static let themeReferencePrefix = "+"

    /// Rewrite every font-naming attribute in one XML part.
    ///
    /// Returns the new XML and how many attributes changed. Pure string work on
    /// purpose: it is the piece that decides whether the feature is correct, so it
    /// has to be testable without Office running.
    public static func rewrite(xml: String, to target: String) -> (xml: String, changed: Int, replaced: Set<String>) {
        var out = xml
        var changed = 0
        var replaced = Set<String>()
        let escapedTarget = escapeXMLAttribute(target)

        for element in fontElements {
            // Match e.g. `<a:latin typeface="Arial" pitchFamily="34" charset="0"/>`
            // and rewrite only the typeface value, preserving every other attribute.
            let pattern = "(<\(element)\\b[^>]*?\\btypeface=\")([^\"]*)(\")"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            var result = ""
            var lastEnd = out.startIndex
            let full = NSRange(out.startIndex..<out.endIndex, in: out)
            for match in regex.matches(in: out, options: [], range: full) {
                guard let whole = Range(match.range, in: out),
                      let headRange = Range(match.range(at: 1), in: out),
                      let valueRange = Range(match.range(at: 2), in: out),
                      let tailRange = Range(match.range(at: 3), in: out) else { continue }
                let value = String(out[valueRange])
                result += out[lastEnd..<whole.lowerBound]
                if value.isEmpty || value.hasPrefix(themeReferencePrefix) || value == target {
                    // Leave untouched when the run inherits rather than names a font:
                    //   - `typeface=""` means "inherit" (common on <a:ea>/<a:cs> in
                    //     Latin decks). Filling it in would force a Latin font onto
                    //     East-Asian or complex-script text that should fall back.
                    //   - `+mj-lt` / `+mn-lt` are theme references; replacing them
                    //     with a literal name would strip theme inheritance.
                    result += out[whole]
                } else {
                    if !value.isEmpty { replaced.insert(value) }
                    result += out[headRange] + escapedTarget + out[tailRange]
                    changed += 1
                }
                lastEnd = whole.upperBound
            }
            result += out[lastEnd...]
            out = result
        }
        return (out, changed, replaced)
    }

    /// Which parts of the package carry font references worth rewriting.
    public static func shouldRewrite(part: String) -> Bool {
        guard part.hasSuffix(".xml") else { return false }
        let prefixes = [
            "ppt/slides/slide",
            "ppt/slideLayouts/slideLayout",
            "ppt/slideMasters/slideMaster",
            "ppt/notesSlides/notesSlide",
            "ppt/notesMasters/notesMaster",
            "ppt/handoutMasters/handoutMaster",
            "ppt/theme/theme",
            "ppt/charts/chart",
            "ppt/diagrams/"
        ]
        return prefixes.contains { part.hasPrefix($0) }
    }

    private static func escapeXMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - File round-trip

    /// Rewrite `path` in place, after taking a backup next to it.
    ///
    /// The file must not be open in PowerPoint — PowerPoint would overwrite the
    /// result from its in-memory copy. Callers are responsible for closing it first.
    @discardableResult
    public static func rewriteFile(at path: String, to target: String, makeBackup: Bool = true) throws -> Summary {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw Failure.notFound(path) }
        guard path.lowercased().hasSuffix(".pptx") else { throw Failure.notAPptx(path) }

        var backupPath: String?
        if makeBackup {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let candidate = (path as NSString).deletingPathExtension + " (before font change \(stamp)).pptx"
            do {
                try fm.copyItem(atPath: path, toPath: candidate)
                backupPath = candidate
            } catch {
                throw Failure.ioFailed("couldn't write a backup: \(error.localizedDescription)")
            }
        }

        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ribbind-pptx-\(UUID().uuidString)")
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        try run("/usr/bin/unzip", ["-qq", path, "-d", workDir.path], failure: Failure.unzipFailed)

        var changedParts: [String] = []
        var totalChanged = 0
        var replaced = Set<String>()

        guard let walker = fm.enumerator(atPath: workDir.path) else {
            throw Failure.ioFailed("couldn't read the unpacked package")
        }
        for case let relative as String in walker {
            guard shouldRewrite(part: relative) else { continue }
            let full = workDir.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: full),
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let result = rewrite(xml: xml, to: target)
            guard result.changed > 0 else { continue }
            try? result.xml.data(using: .utf8)?.write(to: full)
            changedParts.append(relative)
            totalChanged += result.changed
            replaced.formUnion(result.replaced)
        }

        // Repack. Writing to a fresh file and swapping keeps the original intact if
        // zip fails halfway.
        let rebuilt = workDir.deletingLastPathComponent()
            .appendingPathComponent("ribbind-rebuilt-\(UUID().uuidString).pptx")
        // -D omits directory entries and -X drops extra attributes, so the repacked
        // package has the same entry set as the original (Office writes no directory
        // entries). -x excludes Finder droppings that unzip/zip would otherwise
        // smuggle into the document.
        try run("/usr/bin/zip", ["-q", "-X", "-D", "-r", rebuilt.path, ".",
                                 "-x", ".DS_Store", "-x", "__MACOSX/*"],
                cwd: workDir.path, failure: Failure.zipFailed)
        guard fm.fileExists(atPath: rebuilt.path) else {
            throw Failure.zipFailed("repacked file was not produced")
        }
        do {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: rebuilt)
        } catch {
            throw Failure.ioFailed("couldn't replace the original: \(error.localizedDescription)")
        }

        return Summary(target: target,
                       changedParts: changedParts.sorted(),
                       rewrittenAttributes: totalChanged,
                       replacedFonts: replaced.sorted(),
                       backupPath: backupPath)
    }

    private static func run(_ tool: String, _ args: [String], cwd: String? = nil,
                            failure: (String) -> Failure) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        if let cwd { task.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let err = Pipe()
        task.standardError = err
        task.standardOutput = Pipe()
        do { try task.run() } catch { throw failure("\(tool): \(error.localizedDescription)") }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw failure("\(tool) exited \(task.terminationStatus): \(message)")
        }
    }
}

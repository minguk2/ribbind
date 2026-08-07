import AppKit
import CoreText
import Foundation

public enum OfficeFontCatalog {
    public static func availableFontFamilies() -> [String] {
        let systemFamilies = NSFontManager.shared.availableFontFamilies
        let merged = Set(systemFamilies).union(bundledOfficeFontFamilies())
        return merged.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func bundledOfficeFontFamilies() -> Set<String> {
        var directories = Set<URL>()
        for bundleID in ["com.microsoft.Word", "com.microsoft.Powerpoint"] {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                directories.insert(appURL.appendingPathComponent("Contents/Resources/DFonts", isDirectory: true))
            }
        }
        directories.insert(URL(fileURLWithPath: "/Applications/Microsoft Word.app/Contents/Resources/DFonts", isDirectory: true))
        directories.insert(URL(fileURLWithPath: "/Applications/Microsoft PowerPoint.app/Contents/Resources/DFonts", isDirectory: true))

        var families = Set<String>()
        let fontExtensions: Set<String> = ["ttf", "ttc", "otf"]
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for file in files where fontExtensions.contains(file.pathExtension.lowercased()) {
                families.formUnion(fontFamilies(in: file))
            }
        }
        return families
    }

    private static func fontFamilies(in file: URL) -> Set<String> {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] else {
            let fallback = file.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? [] : [fallback]
        }

        var families = Set<String>()
        for descriptor in descriptors {
            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String {
                let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    families.insert(trimmed)
                }
            }
        }
        return families
    }
}

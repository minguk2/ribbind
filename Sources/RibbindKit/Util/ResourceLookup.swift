import Foundation

/// Replacement for SPM's auto-generated `Bundle.module` accessor.
///
/// The SPM accessor (DerivedSources/resource_bundle_accessor.swift) only
/// checks two paths:
///   1. `Bundle.main.bundleURL/<bundleName>` — works for `swift run` / `swift
///      build` outputs where the binary and resource bundles are siblings in
///      `.build/<arch>/<config>/`, but NOT for a packaged macOS .app where
///      `Bundle.main.bundleURL` is the .app root and resources live at
///      `Contents/Resources/<bundleName>`.
///   2. The absolute `.build` path baked at compile time — only exists on
///      the machine that built the binary, so a CI-built .app crashes on
///      a user's Mac with `Fatal error: could not load resource bundle`.
///
/// This helper extends the search to include `Contents/Resources/<bundleName>`
/// so the same code path works for both swift-run AND a packaged .app
/// regardless of which machine built it. We avoid `Bundle.module` entirely
/// because its static-let initializer hits `fatalError` on miss — there's
/// no way to recover gracefully.
public enum ResourceLookup {
    /// Locate a file inside an SPM-generated resource bundle.
    ///
    /// - Parameters:
    ///   - moduleBundleName: e.g. `"Ribbind_RibbindKit.bundle"` (matches the
    ///     name SPM uses; per Package.swift's `resources` declaration).
    ///   - name: resource basename (no extension).
    ///   - ext: extension without leading dot (e.g. `"json"`, `"pdf"`).
    /// - Returns: file URL if found in any candidate location, else nil.
    public static func url(
        in moduleBundleName: String,
        forResource name: String,
        withExtension ext: String
    ) -> URL? {
        let candidates: [URL] = [
            // (1) Packaged .app: build-app.sh copies SPM bundles into
            //     `Contents/Resources/`. This is the canonical macOS bundle
            //     resource location.
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent(moduleBundleName),
            // (2) `swift run` / direct binary launch from `.build/<arch>/
            //     <config>/<exe>`: the bundle is a sibling of the binary
            //     and `Bundle.main.bundleURL` is the parent directory.
            Bundle.main.bundleURL.appendingPathComponent(moduleBundleName),
        ]
        for dir in candidates {
            let candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

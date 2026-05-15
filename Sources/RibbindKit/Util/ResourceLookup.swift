import Foundation

/// Replacement for SPM's auto-generated `Bundle.module` accessor.
///
/// SPM's auto-generated accessor only checks two paths:
///   1. `Bundle.main.bundleURL/<bundleName>` — works for `swift run` / `swift
///      build` outputs where the binary and resource bundles are siblings in
///      `.build/<arch>/<config>/`, but NOT for a packaged macOS .app where
///      `Bundle.main.bundleURL` is the .app root and resources live at
///      `Contents/Resources/<bundleName>`.
///   2. The absolute `.build` path baked at compile time — only exists on
///      the machine that built the binary, so a CI-built .app crashes on
///      a user's Mac with `Fatal error: could not load resource bundle`.
///
/// **Important:** SPM-generated resource bundles come in two layouts on
/// disk depending on how the build was performed:
///   - **Flat** (Command Line Tools / `swift build` direct): all resources
///     sit at `<Bundle>/<file>`.
///   - **Nested** (Xcode universal builds via `xcbuild` on `macos-14` CI):
///     resources live at `<Bundle>/Contents/Resources/<file>` per macOS's
///     standard bundle convention.
///
/// Both layouts ship in the wild — a contributor building locally with
/// CLT produces flat bundles, the GitHub Actions release workflow produces
/// nested bundles. The fix is to delegate lookup to `Bundle(url:)`, which
/// knows about the macOS bundle convention and falls back gracefully to a
/// flat directory if `Contents/Resources/` is absent. Doing the path-append
/// ourselves (the original implementation here) only handled flat bundles
/// and silently fell through to the fallback icon / empty catalog on CI
/// builds — that bug is what made the menu bar icon revert to the keyboard
/// SF Symbol and made every Word / PowerPoint default disappear in v0.6.2.
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
        for bundleURL in candidateBundleURLs(named: moduleBundleName) {
            if let bundle = Bundle(url: bundleURL),
               let resource = bundle.url(forResource: name, withExtension: ext) {
                return resource
            }
        }
        return nil
    }

    /// Locate the resource bundle itself (used by KeyboardShortcuts'
    /// `String.localized` to pass a Bundle directly to NSLocalizedString).
    public static func bundle(named moduleBundleName: String) -> Bundle? {
        for bundleURL in candidateBundleURLs(named: moduleBundleName) {
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }
        return nil
    }

    private static func candidateBundleURLs(named moduleBundleName: String) -> [URL] {
        [
            // (1) Packaged .app: `scripts/build-app.sh` copies SPM resource
            //     bundles into `Contents/Resources/`. Standard macOS layout.
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent(moduleBundleName),
            // (2) `swift run` / direct binary in `.build/<arch>/<config>/`:
            //     the resource bundle is a sibling of the binary, and
            //     `Bundle.main.bundleURL` is that directory.
            Bundle.main.bundleURL.appendingPathComponent(moduleBundleName),
        ]
    }
}

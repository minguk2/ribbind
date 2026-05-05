import AppKit
import Foundation

public enum OfficeAppProbe {
    public static func bundleID(for app: AppTarget) -> String {
        switch app {
        case .word: return "com.microsoft.Word"
        case .powerpoint: return "com.microsoft.Powerpoint"
        case .chrome: return "com.google.Chrome"
        }
    }

    /// Conventional install path. Used as the fallback when LaunchServices can't
    /// resolve the bundle (e.g., LS database stale right after install). Most
    /// users have Office under `/Applications`; both standard installer and Mac
    /// App Store installer drop the bundle there.
    public static func conventionalBundlePath(for app: AppTarget) -> String {
        switch app {
        case .word: return "/Applications/Microsoft Word.app"
        case .powerpoint: return "/Applications/Microsoft PowerPoint.app"
        case .chrome: return "/Applications/Google Chrome.app"
        }
    }

    /// LaunchServices-resolved bundle path, used by every other helper. Falls
    /// back to `conventionalBundlePath` if LS can't find the bundle (which would
    /// also mean the app isn't actually installed for the current user). MAS
    /// installs, alternate-disk installs, and TestFlight builds all resolve
    /// through this path; the original /Applications hard-code missed those.
    public static func bundlePath(for app: AppTarget) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(for: app)) {
            return url.path
        }
        return conventionalBundlePath(for: app)
    }

    public static func isInstalled(_ app: AppTarget) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(for: app)) != nil {
            return true
        }
        // Defense-in-depth: if LS database is stale, fall back to conventional path
        // existence check so a fresh install isn't reported as missing.
        return FileManager.default.fileExists(atPath: conventionalBundlePath(for: app))
    }

    /// True iff the Mac App Store version is installed (vs. the standalone
    /// installer or M365 subscription installer). MAS variants live under a
    /// path that contains `_MASReceipt` or are signed by Apple (team `UBF8T346G9`
    /// for the standard installer, Apple for the MAS sandbox). We approximate
    /// by reading the bundle's Info.plist for a MAS marker — exact, no Process.
    public static func isMacAppStoreInstall(_ app: AppTarget) -> Bool {
        let path = bundlePath(for: app)
        // MAS-installed apps carry `_MASReceipt/receipt` in their Contents dir.
        let masReceiptPath = "\(path)/Contents/_MASReceipt/receipt"
        return FileManager.default.fileExists(atPath: masReceiptPath)
    }

    /// Returns true if `version(for:)` reports a build whose major.minor meets
    /// the requested floor. Used by the UI to warn users on Office < 16.x or
    /// older 16.x builds where the AX tree shape diverges. Returns false when
    /// the version can't be parsed (defensive).
    public static func versionMeets(_ app: AppTarget, atLeast major: Int, _ minor: Int = 0) -> Bool {
        guard let v = version(for: app) else { return false }
        let parts = v.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 1 else { return false }
        if parts[0] != major { return parts[0] > major }
        if parts.count >= 2 { return parts[1] >= minor }
        return minor == 0
    }

    /// True when `app` is the foremost application (its window has key focus). The
    /// app-targeted hotkeys only fire when the target app is frontmost so users can
    /// reuse the same combos in Finder / Xcode / etc. without side effects.
    public static func isFrontmost(_ app: AppTarget) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID(for: app)
    }

    public static func isRunning(_ app: AppTarget) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", app.processName]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return !data.isEmpty
    }

    public static func version(for app: AppTarget) -> String? {
        let infoPlist = bundlePath(for: app) + "/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: infoPlist) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    public static func buildVersion(for app: AppTarget) -> String? {
        let infoPlist = bundlePath(for: app) + "/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: infoPlist) else { return nil }
        return dict["CFBundleVersion"] as? String
    }

    @discardableResult
    public static func quit(_ app: AppTarget, timeout: TimeInterval = 10) async -> Bool {
        let source = "tell application \"\(app.processName)\" to quit"
        _ = try? AppleScriptRunner.run(source)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning(app) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !isRunning(app)
    }

    public static func relaunch(_ app: AppTarget) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-ga", app.processName]
        try? task.run()
    }
}

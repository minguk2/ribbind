import Foundation
import ApplicationServices

/// Truth-table snapshot of every TCC permission Ribbind needs at runtime,
/// written by Ribbind.app on launch (and on demand from the in-app "Test
/// Dispatch" button) and read by ValidationHarness `verify-ribbind-tcc`.
///
/// File-based broadcast — JSON at the path returned by `fileURL` — so the
/// harness can confirm Ribbind.app's actual permission posture without
/// inheriting Terminal's own TCC grants. The v0.5.x verification gap
/// stemmed from running probes inside the harness process; this struct
/// is how we close it.
public struct PermissionState: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let pid: Int
    /// Result of `AXIsProcessTrusted()` from inside Ribbind.app. False means
    /// the CGEventTap did not install — Office's native shortcut for the
    /// same combo is not suppressed and axClick recipes fail.
    public let axGranted: Bool
    /// Result of a live `tell application "Microsoft Word" to count
    /// documents` AppleEvent fired from Ribbind.app. False means
    /// appleScript-typed recipes targeting Word fail at -1743.
    public let wordAutomation: Bool
    /// Same, for `tell application "Microsoft PowerPoint" to count
    /// presentations`.
    public let pptAutomation: Bool
    /// True iff Word was running at probe time. We can't probe Automation
    /// for an app that isn't running (the AS would launch it, polluting
    /// the user's Space) — when this is false, `wordAutomation` is the
    /// best-effort cached value from the last-known-running probe.
    public let wordRunning: Bool
    public let pptRunning: Bool

    public init(timestamp: Date, pid: Int, axGranted: Bool,
                wordAutomation: Bool, pptAutomation: Bool,
                wordRunning: Bool, pptRunning: Bool) {
        self.timestamp = timestamp
        self.pid = pid
        self.axGranted = axGranted
        self.wordAutomation = wordAutomation
        self.pptAutomation = pptAutomation
        self.wordRunning = wordRunning
        self.pptRunning = pptRunning
    }

    /// `~/Library/Application Support/Ribbind/permission-state.json`.
    /// Both writer (Ribbind.app) and reader (ValidationHarness) compute this
    /// the same way so they agree without any IPC.
    public static var fileURL: URL {
        let supportDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Ribbind")
        try? FileManager.default.createDirectory(atPath: supportDir,
                                                  withIntermediateDirectories: true)
        return URL(fileURLWithPath: (supportDir as NSString)
            .appendingPathComponent("permission-state.json"))
    }

    /// Probe + write. Called from Ribbind.app — runs the AS prime, captures
    /// success/failure per app, and atomically writes the JSON. Safe to call
    /// from a background queue.
    @discardableResult
    public static func probeAndWrite() -> PermissionState {
        let wordRunning = OfficeAppProbe.isInstalled(.word)
        let pptRunning  = OfficeAppProbe.isInstalled(.powerpoint)

        // Use `count` on a top-level collection — round-trips an Apple Event
        // to the target app, fails with -1743 on Automation denial, never
        // launches the target if it's already running.
        func probe(_ appName: String, collection: String) -> Bool {
            let src = "tell application \"\(appName)\" to count \(collection)"
            return (try? AppleScriptRunner.run(src)) != nil
        }
        let wordOK = wordRunning ? probe("Microsoft Word", collection: "documents") : false
        let pptOK  = pptRunning  ? probe("Microsoft PowerPoint", collection: "presentations") : false

        let state = PermissionState(
            timestamp: Date(),
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            axGranted: AXIsProcessTrusted(),
            wordAutomation: wordOK,
            pptAutomation: pptOK,
            wordRunning: wordRunning,
            pptRunning: pptRunning
        )

        // Atomic write: encode → temp → rename. Reader never sees a partial
        // file. JSONEncoder is deterministic on this struct so repeat writes
        // don't churn the file's mtime spuriously.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? enc.encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return state
    }

    /// Read the most-recently-written state. Returns nil if Ribbind.app
    /// hasn't written yet (file absent) or the file is corrupt.
    public static func readLatest() -> PermissionState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PermissionState.self, from: data)
    }
}

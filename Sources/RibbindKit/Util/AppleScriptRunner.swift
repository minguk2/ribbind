import Foundation

public enum AppleScriptRunner {
    public enum Failure: Error, CustomStringConvertible {
        case compilationFailed(String)
        case executionFailed(code: Int, message: String)
        /// A value could not be rendered as an AppleScript string literal.
        case unsafeLiteral(String)

        public var description: String {
            switch self {
            case .compilationFailed(let m): return "AppleScript compilation failed: \(m)"
            case .executionFailed(let code, let m): return "AppleScript execution failed (\(code)): \(m)"
            case .unsafeLiteral(let m): return "unsafe AppleScript literal: \(m)"
            }
        }
    }

    @discardableResult
    public static func run(_ source: String) throws -> String? {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw Failure.compilationFailed("NSAppleScript(source:) returned nil")
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown"
            throw Failure.executionFailed(code: code, message: message)
        }
        return result.stringValue
    }

    /// Render `value` as an AppleScript string literal, **including the surrounding
    /// quotes**, escaping backslash and double-quote.
    ///
    /// Everything user- or Office-supplied that lands inside a `"…"` in generated
    /// AppleScript must go through this. A font family or file name containing a
    /// `"` would otherwise close the literal early and the rest of the name would
    /// be parsed as code.
    ///
    /// Control characters (including CR/LF) are rejected rather than escaped:
    /// AppleScript literals cannot carry them, and no legitimate font family or
    /// path needs one, so their presence means the input is not what we think.
    public static func literal(_ value: String) throws -> String {
        if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw Failure.unsafeLiteral("control character in \(value.debugDescription)")
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Run `source` on a dedicated worker thread, giving up after `timeout`.
    ///
    /// HONEST CAVEAT: NSAppleScript cannot be cancelled. On timeout this returns
    /// control to the caller, but the worker thread stays blocked until the Apple
    /// Event finally resolves (or Office is killed). That is acceptable here — the
    /// caller is already off the main thread, so the menu-bar UI stays live — but
    /// it is a leaked thread, and it is logged loudly so a chronically-hanging
    /// Office is visible in Console rather than silently piling up.
    ///
    /// Deliberately NOT implemented by shelling out to `/usr/bin/osascript` (which
    /// would be killable): that changes the Apple Event's TCC responsible process
    /// relative to every other AppleScript path in this app, which is how you get
    /// a mystery -1743 that reproduces nowhere else.
    public static func runBounded(_ source: String, timeout: TimeInterval) throws -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        // Class box: the worker writes these after the caller may have walked away.
        final class Box: @unchecked Sendable {
            var value: String?
            var error: Error?
        }
        let box = Box()
        let thread = Thread {
            do { box.value = try run(source) } catch { box.error = error }
            semaphore.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            NSLog("[Ribbind] AppleScript exceeded %.1fs and was abandoned (worker thread still blocked): %@",
                  timeout, String(source.prefix(120)))
            throw Failure.executionFailed(code: -1712, message: "timed out after \(Int(timeout))s")
        }
        if let error = box.error { throw error }
        return box.value
    }

    /// Compile-only: confirms AppleScript source is syntactically valid without executing.
    /// Use in validation — does not trigger Automation TCC prompts.
    public static func compile(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw Failure.compilationFailed("NSAppleScript(source:) returned nil")
        }
        if !script.compileAndReturnError(&errorInfo) {
            let code = (errorInfo?[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = (errorInfo?[NSAppleScript.errorMessage] as? String) ?? "unknown"
            throw Failure.executionFailed(code: code, message: message)
        }
    }
}

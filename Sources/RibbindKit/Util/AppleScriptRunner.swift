import Foundation

public enum AppleScriptRunner {
    public enum Failure: Error, CustomStringConvertible {
        case compilationFailed(String)
        case executionFailed(code: Int, message: String)

        public var description: String {
            switch self {
            case .compilationFailed(let m): return "AppleScript compilation failed: \(m)"
            case .executionFailed(let code, let m): return "AppleScript execution failed (\(code)): \(m)"
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

import AppKit
import Foundation

struct EditorWindow: Identifiable, Equatable {
    let editorId: String
    let processName: String
    let title: String

    var id: String { "\(processName)::\(title)" }
}

enum WindowControllerError: Error, LocalizedError {
    case osascriptFailed(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .osascriptFailed(let message): return "AppleScript failed: \(message)"
        case .openFailed(let message): return "open failed: \(message)"
        }
    }
}

/// Wraps AppleScript-driven window discovery/focus and `open -a` launching.
/// Uses `Process` + `osascript` (not NSAppleScript) so the exact script
/// strings ported from the Raycast extension's windows.ts can be reused.
enum WindowController {
    /// Lists all open windows for every known editor via System Events.
    /// Editors that are not running are silently skipped.
    static func listEditorWindows() async -> [EditorWindow] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: listEditorWindowsSync())
            }
        }
    }

    private static func listEditorWindowsSync() -> [EditorWindow] {
        var results: [EditorWindow] = []

        for editor in EditorRegistry.editors {
            let processName = escapeForAppleScript(editor.processName)
            let script = """
            set outLines to {}
            tell application "System Events"
              if exists process "\(processName)" then
                tell process "\(processName)"
                  repeat with w in windows
                    try
                      set end of outLines to (name of w)
                    end try
                  end repeat
                end tell
              end if
            end tell
            set AppleScript's text item delimiters to linefeed
            return outLines as text
            """

            guard let output = try? runAppleScript(script) else {
                // process not running, no accessibility permission, or AppleScript error: skip
                continue
            }

            let titles = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            for title in titles {
                results.append(EditorWindow(editorId: editor.id, processName: editor.processName, title: title))
            }
        }

        return results
    }

    /// Returns windows whose title appears to belong to the given project,
    /// matched against the project directory's basename.
    ///
    /// Editor window titles typically look like "file — folder" or just
    /// "folder" (VSCode/Cursor use an em dash or hyphen as separator on macOS).
    static func matchWindowsForProject(_ windows: [EditorWindow], basename: String) -> [EditorWindow] {
        windows.filter { titleMatchesProject($0.title, basename: basename) }
    }

    private static func titleMatchesProject(_ title: String, basename: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "\\s+[—-]\\s+") else {
            return title == basename
        }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        let parts = regex
            .stringByReplacingMatches(in: title, range: range, withTemplate: "\u{0}")
            .split(separator: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.contains(basename) { return true }
        return title == basename
    }

    /// Brings the given window to the front using AXRaise.
    static func focusWindow(processName: String, title: String) async throws {
        let escapedProcess = escapeForAppleScript(processName)
        let escapedTitle = escapeForAppleScript(title)
        let script = """
        tell application "System Events"
          tell process "\(escapedProcess)"
            set frontmost to true
            perform action "AXRaise" of (first window whose name is "\(escapedTitle)")
          end tell
        end tell
        """
        _ = try runAppleScript(script)
    }

    /// Opens (or brings to front) an editor app on the given path.
    static func openInEditor(appName: String, path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName, path]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw WindowControllerError.openFailed(message)
        }
    }

    /// Checks (and, on first call, prompts for) the Accessibility permission
    /// required for System Events to enumerate/raise windows.
    @discardableResult
    static func checkAccessibilityPermission(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options: [NSString: Bool] = [key: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func runAppleScript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw WindowControllerError.osascriptFailed(message)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: outData, encoding: .utf8) ?? ""
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

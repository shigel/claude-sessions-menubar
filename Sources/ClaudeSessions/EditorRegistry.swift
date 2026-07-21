import Foundation

/// Registry of editors this app knows how to focus/open.
/// Add one entry here to support another editor (e.g. Windsurf).
struct EditorDef: Identifiable, Equatable {
    let id: String
    let name: String
    /// App name as used by `open -a "<appName>"` and Spotlight.
    let appName: String
    /// Process name as seen by System Events (ps/AppleScript).
    let processName: String
}

enum EditorRegistry {
    static let editors: [EditorDef] = [
        EditorDef(id: "vscode", name: "Visual Studio Code", appName: "Visual Studio Code", processName: "Code"),
        EditorDef(id: "cursor", name: "Cursor", appName: "Cursor", processName: "Cursor"),
    ]

    static func editor(withId id: String) -> EditorDef? {
        editors.first { $0.id == id }
    }
}

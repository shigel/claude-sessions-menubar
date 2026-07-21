import Foundation

/// Remembers, per project path, which editor was last used to open it.
/// Mirrors store.ts (Raycast LocalStorage) using UserDefaults instead.
enum PreferenceStore {
    private static let lastEditorKeyPrefix = "lastEditor."
    private static let defaultEditorKey = "defaultEditor"

    /// Returns the editor id to use for a project: the per-project editor
    /// last used for it, falling back to the global default editor
    /// preference, falling back to the first registered editor.
    static func preferredEditorId(forProjectPath path: String) -> String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: lastEditorKeyPrefix + path),
           EditorRegistry.editor(withId: stored) != nil {
            return stored
        }
        if let globalDefault = defaults.string(forKey: defaultEditorKey),
           EditorRegistry.editor(withId: globalDefault) != nil {
            return globalDefault
        }
        return EditorRegistry.editors[0].id
    }

    static func setPreferredEditorId(_ editorId: String, forProjectPath path: String) {
        UserDefaults.standard.set(editorId, forKey: lastEditorKeyPrefix + path)
    }

    static func setDefaultEditorId(_ editorId: String) {
        UserDefaults.standard.set(editorId, forKey: defaultEditorKey)
    }

    static func defaultEditorId() -> String? {
        UserDefaults.standard.string(forKey: defaultEditorKey)
    }
}

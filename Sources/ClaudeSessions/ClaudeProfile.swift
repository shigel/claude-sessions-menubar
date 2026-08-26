import Foundation

/// One Claude Code configuration directory. Claude Code supports pointing
/// its whole config/session tree at an alternate location via the
/// `CLAUDE_CONFIG_DIR` environment variable, and a user running several of
/// those side by side (a work profile, a plugin-free "vanilla" profile for
/// experiments, …) ends up with several sibling `~/.claude*` directories,
/// each with its own independent `projects/` tree.
///
/// A profile's `label` is display-only. It is never used to group sessions,
/// identify rows, or key the scanner's cache — those all stay keyed by the
/// session's `cwd` and absolute file URL respectively, exactly as they were
/// before profiles existed.
struct ClaudeProfile: Equatable {
    /// Symlink-resolved profile root, e.g. `/Users/x/.claude-vanilla`.
    /// Canonicalized at discovery time so the same path can be used both for
    /// walking and for cache keys; discovering a resolved path but then
    /// walking an unresolved one would produce cache misses on every scan.
    let root: URL
    /// nil for the default `~/.claude`; otherwise the badge text
    /// (`.claude-vanilla` -> "vanilla"). Display-only.
    let label: String?

    var projectsDir: URL { root.appendingPathComponent("projects") }

    /// Finds every Claude Code config directory in `home`. `home` is a
    /// parameter rather than being read inline so this stays a pure
    /// function that can be pointed at a fixture directory.
    static func discover(in home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ClaudeProfile] {
        let fm = FileManager.default

        // NOTE: no `.skipsHiddenFiles` here, unlike every other directory
        // walk in this app (see SessionScanner). Every profile directory is
        // a dotfile — `.claude`, `.claude-vanilla` — so passing that option
        // out of habit would silently match zero profiles and leave the app
        // showing nothing at all. The inner walks in SessionScanner keep
        // `.skipsHiddenFiles` because there the hidden entries genuinely are
        // noise.
        guard let entries = try? fm.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else {
            return []
        }

        var byResolvedPath: [String: ClaudeProfile] = [:]

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(".claude") else { continue }

            // Two guards, deliberately. The first rejects the `.claude.json`
            // family (config/state files that share the prefix but aren't
            // directories). The second requires an actual `projects/`
            // subtree, so an unrelated tool that someday claims a
            // `~/.claude-something` directory doesn't get walked as if it
            // were a profile.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let resolved = entry.resolvingSymlinksInPath()
            var projectsIsDir: ObjCBool = false
            let projectsPath = resolved.appendingPathComponent("projects").path
            guard fm.fileExists(atPath: projectsPath, isDirectory: &projectsIsDir), projectsIsDir.boolValue else {
                continue
            }

            // Dedupe on the resolved path so a symlink pointing at another
            // profile doesn't get scanned (and counted) twice.
            let profile = ClaudeProfile(root: resolved, label: label(forDirectoryName: name))
            byResolvedPath[resolved.path] = profile
        }

        // Deterministic order: the default profile first, then the rest
        // alphabetically. Keeps scan order (and therefore any debug output)
        // stable across runs.
        return byResolvedPath.values.sorted { lhs, rhs in
            switch (lhs.label, rhs.label) {
            case (nil, nil): return lhs.root.path < rhs.root.path
            case (nil, _): return true
            case (_, nil): return false
            case (let a?, let b?): return a < b
            }
        }
    }

    /// Derives the badge text from a profile directory name by stripping the
    /// shared `.claude` prefix and one separator character. Returns nil for
    /// the default `.claude`, which is shown without a badge (matching how
    /// the UI leaves the ordinary `entrypoint == "cli"` case unlabeled).
    ///
    /// `.claude` -> nil, `.claude-automagi` -> "automagi", `.claude_foo` -> "foo".
    ///
    /// An environment with no default profile at all (only `.claude-foo`)
    /// needs no special case: nothing produces a nil label, so every session
    /// simply carries a badge.
    static func label(forDirectoryName name: String) -> String? {
        guard name.hasPrefix(".claude") else { return nil }
        var remainder = Substring(name.dropFirst(".claude".count))
        if let first = remainder.first, first == "-" || first == "_" || first == "." {
            remainder = remainder.dropFirst()
        }
        return remainder.isEmpty ? nil : String(remainder)
    }
}

import Foundation

/// A Claude Code project session, derived from ~/.claude/projects/*/*.jsonl logs.
struct ProjectSession: Identifiable, Equatable {
    /// Absolute project path, taken verbatim from the jsonl `cwd` field.
    let path: String
    /// Most recent mtime across all jsonl files that resolved to this cwd.
    let lastActive: Date
    /// Whether the directory still exists on disk.
    let exists: Bool

    var id: String { path }

    var basename: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let last = trimmed.split(separator: "/").last {
            return String(last)
        }
        return path
    }
}

/// Scans ~/.claude/projects/<encoded-dir>/*.jsonl, extracts the `cwd` field
/// from each session log, dedupes by cwd (keeping the newest mtime), and
/// returns the list sorted by most recent activity first.
///
/// The <encoded-dir> directory name is NOT decoded back into a path: the
/// `/` -> `-` encoding is lossy (collides with existing hyphens/underscores),
/// so the only reliable source of the real path is the `cwd` field inside
/// the log lines themselves.
enum SessionScanner {
    private static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    static func scan() async -> [ProjectSession] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanSync())
            }
        }
    }

    private static func scanSync() -> [ProjectSession] {
        let fm = FileManager.default
        let root = projectsDir
        guard fm.fileExists(atPath: root.path) else { return [] }

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var byCwd: [String: Date] = [:]

        for dirURL in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for fileURL in files where fileURL.pathExtension == "jsonl" {
                guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                      let mtime = attrs[.modificationDate] as? Date else {
                    continue
                }
                guard let cwd = extractCwd(from: fileURL) else { continue }

                if let prev = byCwd[cwd] {
                    if mtime > prev {
                        byCwd[cwd] = mtime
                    }
                } else {
                    byCwd[cwd] = mtime
                }
            }
        }

        return byCwd.map { cwd, lastActive in
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue
            return ProjectSession(path: cwd, lastActive: lastActive, exists: exists)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    /// Reads a jsonl file line by line (without loading the whole file) and
    /// returns the `cwd` field of the first line that has one. Meta lines at
    /// the start of the log commonly lack `cwd`, so this does not assume the
    /// first line has it.
    private static func extractCwd(from fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let chunkSize = 8192
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                // EOF: process whatever remains in buffer as a final line.
                if let cwd = cwdFromLine(buffer) { return cwd }
                return nil
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if let cwd = cwdFromLine(lineData) {
                    return cwd
                }
            }
        }
    }

    private static func cwdFromLine(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
            return cwd
        }
        return nil
    }
}

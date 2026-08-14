import Foundation

/// A project directory that has one or more Claude Code sessions logged
/// under it, derived from ~/.claude/projects/*/*.jsonl.
struct ProjectSession: Identifiable, Equatable {
    /// Absolute project path, taken verbatim from the jsonl `cwd` field.
    let path: String
    /// Most recent mtime across all jsonl files that resolved to this cwd.
    /// Equal to `sessions.first?.lastActive` since `sessions` is sorted
    /// most-recent-first.
    let lastActive: Date
    /// Whether the directory still exists on disk.
    let exists: Bool
    /// All sessions filed under this cwd, sorted by `lastActive` descending.
    /// Guaranteed non-empty — a cwd with zero sessions never produces a
    /// `ProjectSession` in the first place.
    let sessions: [ClaudeSession]

    var id: String { path }

    var basename: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let last = trimmed.split(separator: "/").last {
            return String(last)
        }
        return path
    }

    /// Only projects with 2+ sessions get a disclosure control in the UI —
    /// a lone session has nothing to disambiguate, so showing an always-empty
    /// chevron next to it would just be visual noise.
    var isExpandable: Bool { sessions.count > 1 }
}

/// Scans ~/.claude/projects/<encoded-dir>/*.jsonl, extracts the `cwd` field
/// from each session log, groups sessions by cwd into one `ProjectSession`
/// per project (every session survives as a child, none are discarded), and
/// returns the list sorted by most recent activity first.
///
/// The <encoded-dir> directory name is NOT decoded back into a path: the
/// `/` -> `-` encoding is lossy (collides with existing hyphens/underscores),
/// so the only reliable source of the real path is the `cwd` field inside
/// the log lines themselves.
enum SessionScanner {
    /// Byte budgets for the two-window read strategy. Sized from a survey
    /// of the real dataset (363 session files):
    /// - `headBytes`: `cwd` was found within 4,478 bytes in every sampled
    ///   file, so 8KB leaves comfortable margin at negligible cost.
    /// - `tailBytes`: sweeping the tail window size showed title-material
    ///   coverage (aiTitle/lastPrompt/customTitle) saturates at 64KB —
    ///   doubling to 128KB found zero additional matches. `ai-title` lines
    ///   are appended on every turn, so they're reliably present near the
    ///   end of the file; hunting for the *first* ai-title occurrence near
    ///   the head would cost far more (median offset 56KB, max 2.6MB) for
    ///   no benefit, since first and last ai-title values were verified to
    ///   agree in every sampled file.
    /// - `tailEscalatedBytes`: a single, bounded retry for the rare file
    ///   (~70/363) whose 64KB tail contains no complete line at all — e.g.
    ///   a single tool_result line larger than the window. This must stay
    ///   a ONE-TIME escalation, never a fallback to reading the whole file:
    ///   files run up to 40MB, and full reads of the dataset would total
    ///   ~656MB per scan.
    private enum Window {
        static let headBytes = 8 * 1024
        static let tailBytes = 64 * 1024
        static let tailEscalatedBytes = 256 * 1024
    }

    /// Exposed (not `private`) so `ProjectsWatcher` can watch the same root
    /// this scanner reads from without duplicating the path construction.
    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    /// A jsonl file discovered on disk, before its content is parsed.
    private struct FileEntry {
        let url: URL
        let mtime: Date
        let size: Int
    }

    /// Per-file cache, keyed by mtime AND size so an append within the same
    /// second (mtime alone wouldn't change) doesn't serve stale content.
    /// The popover calls `refresh()` — and therefore `scanSync()` — every
    /// time it opens, so without this cache every open would re-read and
    /// re-parse the two windows of all ~360 session files even though the
    /// overwhelming majority haven't changed since the last open.
    private struct CacheEntry {
        let mtime: Date
        let size: Int
        let session: ClaudeSession
    }

    private static var cache: [URL: CacheEntry] = [:]
    private static let cacheLock = NSLock()

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

        var fileEntries: [FileEntry] = []
        for dirURL in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Non-recursive: only *.jsonl directly inside <projDir> are real
            // sessions. <projDir>/<sessionId>/subagents/** holds sub-agent
            // transcripts, not sessions, and contentsOfDirectory here never
            // descends into them.
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
                let size = (attrs[.size] as? Int) ?? 0
                fileEntries.append(FileEntry(url: fileURL, mtime: mtime, size: size))
            }
        }

        // Parse files concurrently, writing each result to its own fixed
        // index — safe without additional synchronization because no two
        // iterations ever touch the same index. `buildSession(for:)` is the
        // only per-file work (window reads + fallback chain), and it's the
        // expensive part this scanner budgeted for; cache lookups inside it
        // are the one piece of shared mutable state, guarded by `cacheLock`.
        var results = [ClaudeSession?](repeating: nil, count: fileEntries.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: fileEntries.count) { index in
                buffer[index] = buildSession(for: fileEntries[index])
            }
        }
        pruneCache(keeping: fileEntries.map(\.url))

        // Group every session (one per jsonl file) by its cwd first, then
        // fold each group into a single ProjectSession. This replaces the
        // old byCwd-max-mtime dedup: instead of keeping only the newest
        // session per cwd and discarding the rest, every session survives
        // and becomes a child row the UI can expand into.
        var sessionsByCwd: [String: [ClaudeSession]] = [:]
        for session in results.compactMap({ $0 }) {
            sessionsByCwd[session.cwd, default: []].append(session)
        }

        return sessionsByCwd.map { cwd, sessions in
            let sorted = sessions.sorted { $0.lastActive > $1.lastActive }
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue
            // sorted is non-empty here: a cwd only gets an entry in
            // sessionsByCwd when at least one session was appended to it.
            return ProjectSession(path: cwd, lastActive: sorted[0].lastActive, exists: exists, sessions: sorted)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    /// Builds one `ClaudeSession` from a file, serving a cached result when
    /// the file's mtime+size haven't changed since the last scan. Returns
    /// nil when `cwd` couldn't be resolved (mirrors the pre-multi-session
    /// behavior of skipping files with no discoverable cwd).
    private static func buildSession(for entry: FileEntry) -> ClaudeSession? {
        if let cached = cachedSession(for: entry) {
            return cached
        }

        let headLines = readHeadWindow(entry.url, bytes: Window.headBytes)
        guard let cwd = extractCwd(from: headLines) else { return nil }

        // The jsonl basename equals the sessionId field for every session
        // observed on disk, so deriving it from the filename avoids
        // re-parsing the file to find sessionId.
        let sessionId = entry.url.deletingPathExtension().lastPathComponent
        let metadata = sessionMetadata(from: headLines)
        let (title, titleSource) = resolveTitle(fileURL: entry.url, fileSize: entry.size, headLines: headLines)

        let session = ClaudeSession(
            sessionId: sessionId,
            fileURL: entry.url,
            cwd: cwd,
            lastActive: entry.mtime,
            startedAt: metadata.startedAt,
            title: title,
            titleSource: titleSource,
            entrypoint: metadata.entrypoint,
            isBackground: metadata.isBackground
        )
        storeCache(session: session, entry: entry)
        return session
    }

    private static func cachedSession(for entry: FileEntry) -> ClaudeSession? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = cache[entry.url], cached.mtime == entry.mtime, cached.size == entry.size else {
            return nil
        }
        return cached.session
    }

    private static func storeCache(session: ClaudeSession, entry: FileEntry) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[entry.url] = CacheEntry(mtime: entry.mtime, size: entry.size, session: session)
    }

    /// Drops cache entries for files that no longer exist on disk (deleted
    /// or rotated away), so the cache doesn't grow without bound across the
    /// life of the app.
    private static func pruneCache(keeping urls: [URL]) {
        let stillPresent = Set(urls)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = cache.filter { stillPresent.contains($0.key) }
    }

    /// Returns the `cwd` field of the first line that has one, scanning the
    /// pre-read head window. Meta lines at the start of the log commonly
    /// lack `cwd`, so this does not assume the first line has it — but
    /// every sampled file resolved `cwd` well within `Window.headBytes`.
    private static func extractCwd(from headLines: [Data]) -> String? {
        for line in headLines {
            if let cwd = cwdFromLine(line) { return cwd }
        }
        return nil
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

    // MARK: - Title and metadata extraction

    /// Resolves `ClaudeSession.title`/`titleSource` by walking the fallback
    /// chain: tail-window rungs (custom-title/ai-title/last-prompt) first,
    /// then one bounded tail-window escalation, then the head-window
    /// slash-command rung, then finally the session id. See
    /// `SessionTitleExtractor` for the per-rung logic; this function only
    /// owns the I/O (which windows get read) and the escalation decision.
    private static func resolveTitle(fileURL: URL, fileSize: Int, headLines: [Data]) -> (String, TitleSource) {
        let tailLines = readTailWindow(fileURL, bytes: Window.tailBytes)
        if let hit = SessionTitleExtractor.titleFromTailWindow(tailLines) {
            return hit
        }

        // A single, bounded retry with a larger tail window — not a
        // fallback to reading the whole file — for the files whose ordinary
        // 64KB tail happened to contain no title material at all (~70/363
        // in the surveyed dataset, e.g. because the final lines are one
        // oversized tool_result).
        if fileSize > Window.tailBytes {
            let escalatedLines = readTailWindow(fileURL, bytes: Window.tailEscalatedBytes)
            if let hit = SessionTitleExtractor.titleFromTailWindow(escalatedLines) {
                return hit
            }
        }

        if let command = SessionTitleExtractor.slashCommandFromHeadWindow(headLines) {
            return (command, .slashCommand)
        }

        let sessionId = fileURL.deletingPathExtension().lastPathComponent
        return (String(sessionId.prefix(8)), .sessionId)
    }

    /// Pulls `entrypoint`, `sessionKind`, and the first `timestamp` out of
    /// the head window. These are common top-level fields present on most
    /// lines, so the scan stops as soon as all three are found rather than
    /// reading every line in the window.
    private static func sessionMetadata(from headLines: [Data]) -> (entrypoint: String?, isBackground: Bool, startedAt: Date?) {
        var entrypoint: String?
        var isBackground = false
        var startedAt: Date?

        for line in headLines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if entrypoint == nil, let value = obj["entrypoint"] as? String {
                entrypoint = value
            }
            if !isBackground, (obj["sessionKind"] as? String) == "bg" {
                isBackground = true
            }
            if startedAt == nil, let value = obj["timestamp"] as? String {
                startedAt = parseTimestamp(value)
            }
            if entrypoint != nil, isBackground, startedAt != nil { break }
        }

        return (entrypoint, isBackground, startedAt)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        iso8601WithFractional.date(from: value) ?? iso8601WithoutFractional.date(from: value)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601WithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Two-window reading

    /// Reads the first `bytes` of `fileURL` and splits it into complete
    /// jsonl lines. If the file is smaller than `bytes` (genuine EOF), the
    /// trailing line with no terminating newline is included as complete.
    /// Otherwise the trailing partial line — cut off mid-write by the byte
    /// budget, not by a real line boundary — is dropped rather than handed
    /// to a JSON parser as garbage.
    static func readHeadWindow(_ fileURL: URL, bytes: Int) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: bytes)
        let isEOF = data.count < bytes
        return splitCompleteLines(data, isEOF: isEOF)
    }

    /// Reads the last `bytes` of `fileURL` and splits it into complete jsonl
    /// lines. Seeking into the middle of the file necessarily lands mid-line,
    /// so the leading fragment before the first newline is discarded as
    /// partial — including in the degenerate case where the entire window
    /// contains no newline at all (a single line, such as one oversized
    /// tool_result, spanning more than `bytes`): that fragment is ALSO the
    /// file's true last line, but there's no way to tell the two apart from
    /// inside the window, so this returns an empty array rather than risk
    /// parsing a truncated line as complete JSON. Callers that need
    /// material from such a file should retry with a larger `bytes` budget
    /// (see `Window.tailEscalatedBytes`), not assume this is a hard failure.
    static func readTailWindow(_ fileURL: URL, bytes: Int) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let budget = UInt64(bytes)
        let offset = size > budget ? size - budget : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return []
        }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return [] }

        // We always read through to EOF here, so the final fragment (if any)
        // is a genuine complete line, not a truncation artifact.
        var lines = splitCompleteLines(data, isEOF: true)

        // offset > 0 means this window started mid-file, so whatever came
        // before the first newline is a partial line inherited from outside
        // the window — drop it. When offset == 0 the window covers the
        // whole file from its true start, so the first element is complete
        // and must be kept.
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines
    }

    /// Splits `data` on newline bytes. `isEOF` tells this whether the final
    /// fragment (the bytes after the last newline, if any) represents a
    /// genuine end-of-file line (kept) or a mid-stream truncation artifact
    /// (dropped). Does not interpret line content — callers decide what to
    /// do with a leading partial fragment (see `readTailWindow`).
    private static func splitCompleteLines(_ data: Data, isEOF: Bool) -> [Data] {
        guard !data.isEmpty else { return [] }
        let newline = UInt8(ascii: "\n")
        var lines: [Data] = []
        var start = data.startIndex

        while let newlineIndex = data[start...].firstIndex(of: newline) {
            lines.append(data.subdata(in: start..<newlineIndex))
            start = data.index(after: newlineIndex)
        }
        if isEOF, start < data.endIndex {
            lines.append(data.subdata(in: start..<data.endIndex))
        }
        return lines
    }
}

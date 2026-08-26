import Foundation

/// A project directory that has one or more Claude Code sessions logged
/// under it, derived from ~/.claude/projects/*/*.jsonl.
struct ProjectSession: Identifiable, Equatable {
    /// Absolute project path. Usually taken verbatim from the jsonl `cwd`
    /// field, but for a session whose `cwd` is a `git worktree` checkout
    /// this is instead the *main* checkout's path — see
    /// `SessionScanner.projectRoot(for:)` (issue #23) — so worktree
    /// sessions group under the same `ProjectSession` as the repo they
    /// belong to rather than forming their own single-session entry.
    let path: String
    /// Most recent mtime across all jsonl files that resolved to this path.
    /// Equal to `sessions.first?.lastActive` since `sessions` is sorted
    /// most-recent-first.
    let lastActive: Date
    /// Whether the directory still exists on disk.
    let exists: Bool
    /// All sessions filed under this path, sorted by `lastActive`
    /// descending. Guaranteed non-empty — a path with zero sessions never
    /// produces a `ProjectSession` in the first place.
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

    /// Distinct non-default profile labels among `sessions`. Needed because
    /// a single-session project never renders a child row (see
    /// `isExpandable`), so a project living only in a non-default profile
    /// would otherwise have nowhere to show which profile it came from.
    var profileLabels: Set<String> { Set(sessions.compactMap(\.profileLabel)) }
}

/// Scans <profile>/projects/<encoded-dir>/*.jsonl across every discovered
/// Claude Code config directory (see `ClaudeProfile`), extracts the `cwd`
/// field from each session log, groups sessions by project root (`cwd`,
/// resolved through `projectRoot(for:)` to fold `git worktree` checkouts
/// into their main checkout — issue #23) into one `ProjectSession` per
/// project (every session survives as a child, none are discarded), and
/// returns the list sorted by most recent activity first.
///
/// Grouping is by resolved project root alone, so a project that exists in
/// more than one profile (or is checked out as a worktree alongside its main
/// checkout) lands in a single row: the editor window such a row focuses is
/// the same one regardless of which profile recorded the session or which
/// checkout it ran in. The profile survives on each `ClaudeSession` as a
/// display-only label.
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

    /// Every discovered profile's `projects` root, exposed (not `private`)
    /// so `ProjectsWatcher` can watch the same roots this scanner reads from
    /// without duplicating the path construction. Recomputed on each call
    /// (not cached) for the same reason `scanSync()` re-discovers profiles
    /// every scan — a profile added after launch (or after the watcher was
    /// last started) should be picked up without restarting the app.
    static var watchedProjectsDirs: [URL] {
        ClaudeProfile.discover().map(\.projectsDir)
    }


    /// A jsonl file discovered on disk, before its content is parsed.
    private struct FileEntry {
        let url: URL
        let mtime: Date
        let size: Int
        /// The profile this file was found under; nil for the default one.
        let profileLabel: String?
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

    /// Resolved project root per `cwd`, keyed by the raw `cwd` string
    /// (issue #23). Unlike `cache`, this has no mtime/size invalidation:
    /// a directory's identity as "the main checkout" vs. "a worktree of
    /// some other checkout" essentially never changes during the life of
    /// the running app, so a stale entry is not a realistic concern and a
    /// simple grow-forever cache avoids re-spawning `git` on every scan
    /// (the popover re-scans on every open).
    private static var gitRootCache: [String: String] = [:]
    private static let gitRootCacheLock = NSLock()

    static func scan() async -> [ProjectSession] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanSync())
            }
        }
    }

    private static func scanSync() -> [ProjectSession] {
        let fm = FileManager.default

        // Rediscovered on every scan rather than cached for the process
        // lifetime: it costs one directory listing plus a couple of stats,
        // and in exchange a newly created profile shows up without having to
        // restart the app.
        var fileEntries: [FileEntry] = []
        for profile in ClaudeProfile.discover() {
            let root = profile.projectsDir
            // `continue`, not `return []`: one unreadable profile root
            // (permissions, a broken symlink) must not blank out the whole
            // list, only its own sessions.
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let projectDirs = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for dirURL in projectDirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

                // Non-recursive: only *.jsonl directly inside <projDir> are
                // real sessions. <projDir>/<sessionId>/subagents/** holds
                // sub-agent transcripts, not sessions, and
                // contentsOfDirectory here never descends into them. Adding
                // the profile loop above adds exactly one level at the top
                // and leaves this property intact.
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
                    fileEntries.append(
                        FileEntry(url: fileURL, mtime: mtime, size: size, profileLabel: profile.label))
                }
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
        // Pruned once, against the union of every profile's files — NOT once
        // per profile inside the loop above. Per-profile pruning would treat
        // the other profiles' entries as vanished files and evict them on
        // every iteration, leaving the cache permanently cold.
        pruneCache(keeping: fileEntries.map(\.url))

        // Group every session (one per jsonl file) by its *project root*
        // first, then fold each group into a single ProjectSession. This
        // replaces the old byCwd-max-mtime dedup: instead of keeping only
        // the newest session per cwd and discarding the rest, every session
        // survives and becomes a child row the UI can expand into.
        //
        // The project root is not always `session.cwd` verbatim: a `cwd`
        // inside a `git worktree` resolves (via `projectRoot(for:)`) to the
        // main repository's path, so worktree sessions land in the same
        // group as sessions from the primary checkout (issue #23) instead
        // of forming their own single-session group.
        let uniqueCwds = Set(results.compactMap { $0?.cwd })
        var rootsByCwd: [String: String] = [:]
        for cwd in uniqueCwds {
            rootsByCwd[cwd] = projectRoot(for: cwd)
        }

        var sessionsByRoot: [String: [ClaudeSession]] = [:]
        for session in results.compactMap({ $0 }) {
            let root = rootsByCwd[session.cwd] ?? session.cwd
            sessionsByRoot[root, default: []].append(session)
        }

        return sessionsByRoot.map { root, sessions in
            let sorted = sessions.sorted { $0.lastActive > $1.lastActive }
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: root, isDirectory: &isDir) && isDir.boolValue
            // sorted is non-empty here: a root only gets an entry in
            // sessionsByRoot when at least one session was appended to it.
            return ProjectSession(path: root, lastActive: sorted[0].lastActive, exists: exists, sessions: sorted)
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
            isBackground: metadata.isBackground,
            profileLabel: entry.profileLabel
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

    // MARK: - Git worktree resolution (issue #23)

    /// Resolves `cwd` to the path sessions should actually be grouped
    /// under: for an ordinary checkout this is `cwd` itself; for a `git
    /// worktree` checkout it's the *main* checkout's path, so a worktree's
    /// sessions land in the same `ProjectSession` as the repo they belong
    /// to instead of forming their own single-session group.
    ///
    /// Falls back to returning `cwd` unchanged whenever `git` can't answer
    /// (not a git repo, directory no longer exists, `git` missing/old) —
    /// this must never be able to make grouping worse than before this was
    /// introduced, only better for the worktree case it targets.
    private static func projectRoot(for cwd: String) -> String {
        gitRootCacheLock.lock()
        if let cached = gitRootCache[cwd] {
            gitRootCacheLock.unlock()
            return cached
        }
        gitRootCacheLock.unlock()

        let resolved = resolveProjectRootUncached(cwd)

        gitRootCacheLock.lock()
        gitRootCache[cwd] = resolved
        gitRootCacheLock.unlock()
        return resolved
    }

    private static func resolveProjectRootUncached(_ cwd: String) -> String {
        // `--path-format=absolute` (git >= 2.31) makes the output usable
        // regardless of `cwd`'s relationship to the process's own working
        // directory; `--git-common-dir` (as opposed to `--git-dir`) is what
        // makes this worktree-aware — for a worktree checkout it points at
        // the *main* checkout's `.git`, not the worktree-private one under
        // `.git/worktrees/<name>`. For an ordinary (non-worktree) checkout
        // it simply points at that same checkout's own `.git`, so
        // `commonDir`'s parent equals `cwd` and this is a no-op.
        guard let output = try? runGit(
            ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        ) else {
            return cwd
        }
        let commonDirPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonDirPath.isEmpty else { return cwd }

        let commonDirURL = URL(fileURLWithPath: commonDirPath)
        // A bare repository's common dir doesn't end in `.git` (it *is* the
        // repo directory) — that layout isn't the worktree case this issue
        // is about, so leave `cwd` alone rather than guessing.
        guard commonDirURL.lastPathComponent == ".git" else { return cwd }
        return commonDirURL.deletingLastPathComponent().path
    }

    private struct GitCommandFailed: Error {}

    /// Runs `git` with the given arguments and returns its stdout. Throws
    /// (and callers should treat that as "leave `cwd` unresolved") on a
    /// non-zero exit — e.g. `cwd` is not inside a git repository at all,
    /// which is an entirely normal case for a project directory.
    private static func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe() // discard; not-a-repo errors are expected/routine

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitCommandFailed()
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
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

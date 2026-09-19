import Foundation

/// Everything `SessionScanner` needs to know about Codex CLI's on-disk
/// session format, kept out of the scanner so the two agents' formats
/// don't interleave inside one function (issue #10).
///
/// Layout (surveyed 2026-08/09, cli_version 0.148–0.155):
///
///     ~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ISO ts>-<threadId>.jsonl
///     ~/.codex/session_index.jsonl     {"id","thread_name","updated_at"}
///
/// Each rollout is jsonl of `{"timestamp","type","payload"}`. Line 1 is
/// always `type == "session_meta"`, and its payload carries `cwd`, `id`,
/// `timestamp`, `originator` (`codex-tui` / `codex_exec` / `Codex Desktop`
/// / `Claude Code` …) and `source`. `source` is a plain string for a
/// user-started thread and a dictionary (`{"subagent": {...}}`) for a
/// thread Codex spawned itself — sub-agents and guardian reviews — which
/// is the one signal used to leave those out of the list.
///
/// Like `SessionTitleExtractor`, every function here is pure over
/// already-read line arrays except the two directory/index readers, so it
/// can be checked against the real dataset with an ad-hoc script.
enum CodexSessionParser {
    static let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    static var sessionsDir: URL { codexHome.appendingPathComponent("sessions") }
    static var indexFile: URL { codexHome.appendingPathComponent("session_index.jsonl") }

    struct SessionMeta {
        let sessionId: String
        let cwd: String
        /// Raw ISO-8601 string of `payload.timestamp` (thread start).
        let startedAt: String?
        let originator: String?
        /// True when `payload.source` is a dictionary, i.e. Codex spawned
        /// this thread from another one. Not a user-facing session.
        let isDerivedThread: Bool

        /// `codex exec` runs and threads driven by the Codex plugin from
        /// inside Claude Code (originator "Claude Code") have no human at
        /// the keyboard — the Codex analogue of Claude Code's `sdk-cli`.
        var isUnattended: Bool { originator == "codex_exec" || originator == "Claude Code" }
        /// Codex Desktop (and its "work" variant) rather than the TUI.
        var isDesktop: Bool { originator == "Codex Desktop" || originator == "codex_work_desktop" }
    }

    /// Enumerates `sessions/<YYYY>/<MM>/<DD>/*.jsonl` with a fixed-depth
    /// walk rather than a recursive enumerator: the depth is part of the
    /// format, and a bounded walk can't be dragged into an unexpected
    /// subtree (e.g. a future `attachments/` beside a rollout) the way an
    /// unbounded one could. Hidden entries are skipped at every level, as
    /// in the Claude walk. `archived_sessions/` (a flat, legacy layout
    /// with two files on the surveyed machine) is deliberately not read.
    static func rolloutFiles() -> [URL] {
        let fm = FileManager.default
        func subdirectories(of url: URL) -> [URL] {
            guard let entries = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return [] }
            return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }

        var files: [URL] = []
        for year in subdirectories(of: sessionsDir) {
            for month in subdirectories(of: year) {
                for day in subdirectories(of: month) {
                    guard let entries = try? fm.contentsOfDirectory(
                        at: day, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                    ) else { continue }
                    files += entries.filter { $0.pathExtension == "jsonl" }
                }
            }
        }
        return files
    }

    /// `session_index.jsonl` as `id -> thread_name`. The index is append-only
    /// and a thread can be renamed, so a later line for the same id wins.
    /// Missing or unreadable index → empty map; callers fall through to the
    /// next title rung rather than failing the scan.
    static func loadThreadNames() -> [String: String] {
        guard let data = try? Data(contentsOf: indexFile) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String, !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }

    /// Parses line 1. `sessionId` comes from `payload.id` — the filename
    /// also contains it, but behind a timestamp prefix whose exact shape
    /// isn't worth depending on when the field is right there.
    static func sessionMeta(from headLines: [Data]) -> SessionMeta? {
        guard let first = headLines.first,
              let obj = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let id = payload["id"] as? String, !id.isEmpty,
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else {
            return nil
        }
        return SessionMeta(
            sessionId: id,
            cwd: cwd,
            startedAt: payload["timestamp"] as? String,
            originator: payload["originator"] as? String,
            isDerivedThread: payload["source"] is [String: Any]
        )
    }

    /// Byte-level pre-filter so the (fat) tool-call and reasoning lines in
    /// the head window are never JSON-parsed.
    private static let userMarkers: [Data] = [
        Data("\"role\":\"user\"".utf8), Data("\"role\": \"user\"".utf8), Data("user_message".utf8)
    ]

    /// Text Codex injects into the conversation as if the user had typed
    /// it: the AGENTS.md preamble, `<environment_context>`, plugin
    /// recommendations, `<command-name>` wrappers, local-command echoes.
    /// Listed explicitly rather than as "starts with `#`" or "starts with
    /// `<`": both broad rules drop genuine prompts (Markdown-headed review
    /// prompts; `<user_action>` prompts sent by the Codex plugin), and a
    /// wrongly kept injected block is the lesser failure — it's still a
    /// title, just a poor one.
    private static let injectedPrefixes = [
        "# AGENTS.md instructions",
        "<environment_context", "<recommended_plugins", "<command-name",
        "<user_instructions", "<local-command-", "<turn_aborted", "<system-reminder",
    ]

    /// First user-authored message in the head window, or nil. Two line
    /// shapes carry user text and both are checked: `event_msg` with
    /// `payload.type == "user_message"` (`payload.message`) and
    /// `response_item` with `payload.role == "user"` (`input_text` blocks).
    static func firstUserPrompt(from headLines: [Data]) -> String? {
        for line in headLines.dropFirst() {
            guard userMarkers.contains(where: { line.range(of: $0) != nil }) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String,
                  let payload = obj["payload"] as? [String: Any] else { continue }

            let text: String?
            switch type {
            case "event_msg" where (payload["type"] as? String) == "user_message":
                text = payload["message"] as? String
            case "response_item" where (payload["type"] as? String) == "message" && (payload["role"] as? String) == "user":
                text = inputText(from: payload["content"])
            default:
                text = nil
            }

            guard let text else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if injectedPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
            return trimmed
        }
        return nil
    }

    private static func inputText(from content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let text = blocks
            .filter { ($0["type"] as? String) == "input_text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

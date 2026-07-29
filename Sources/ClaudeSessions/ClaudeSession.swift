import Foundation

/// A single Claude Code session, backed by one
/// ~/.claude/projects/<encoded-dir>/<sessionId>.jsonl file.
///
/// Sub-agent transcripts under <projDir>/<sessionId>/subagents/** are NOT
/// sessions and are never represented here — `SessionScanner`'s two-level,
/// non-recursive directory walk excludes them by construction.
struct ClaudeSession: Identifiable, Equatable, Hashable {
    /// Session UUID. Verified equal to the jsonl file's basename for every
    /// session on disk (a sample of 339 files showed 100% agreement), and
    /// unique across all project directories, so it is safe to use as a
    /// `List(selection:)` tag without qualifying it by project.
    let sessionId: String
    let fileURL: URL
    /// The project this session is filed under: the FIRST `cwd` seen in the
    /// file. A session can technically `cd` mid-conversation (observed in
    /// 1/56 sampled files), but re-filing under every cwd it ever visited
    /// would require reading past the head window this scanner uses, so a
    /// session that moves directories is only ever listed under where it
    /// started. This matches the pre-existing (pre-multi-session) behavior
    /// of `SessionScanner`, so `PreferenceStore`'s per-path editor
    /// preference keys stay valid with no migration.
    let cwd: String
    /// File mtime. This is the only activity signal available — jsonl is a
    /// history view, not a liveness signal (a session that's actively
    /// running may not have written its jsonl yet), so there is
    /// deliberately no `isRunning` field here.
    let lastActive: Date
    /// First `timestamp` seen in the head window. Present in the vast
    /// majority of files but not guaranteed (a handful lack it), so the UI
    /// must be prepared to fall back to `lastActive` for display.
    let startedAt: Date?

    /// Guaranteed non-empty, single-line (no embedded newlines), and at
    /// most 200 characters. Produced by `SessionScanner`'s title fallback
    /// chain — see `titleSource` for which rung produced it. The UI may
    /// render it directly with no further sanitizing.
    let title: String
    /// Which rung of the fallback chain produced `title`. Lets the UI
    /// de-emphasize weak titles (e.g. `.sessionId`, which means nothing
    /// usable was found and the row is only distinguishable by its id).
    let titleSource: TitleSource

    /// "cli" / "sdk-cli" (unattended, cron-style runs — these typically
    /// lack an ai-generated title) / "claude-desktop". `nil` when absent
    /// from the head window.
    let entrypoint: String?
    /// `sessionKind == "bg"` in the log.
    let isBackground: Bool

    var id: String { sessionId }
    /// Short form for degraded display, e.g. "f909915e".
    var shortId: String { String(sessionId.prefix(8)) }
}

/// Which rung of the title fallback chain produced `ClaudeSession.title`.
/// Ordered by trust, highest first — see `SessionScanner` for the
/// extraction logic and measured coverage of each rung.
enum TitleSource: String, Equatable, Hashable {
    /// User-set title (`type=="custom-title"`). Rare but authoritative.
    case customTitle
    /// Claude-generated title (`type=="ai-title"`), e.g. "QA選択機能の再実装".
    case aiTitle
    /// Most recent user prompt (`type=="last-prompt"`), truncated.
    case lastPrompt
    /// Slash command name parsed out of the first user message, e.g.
    /// "/plaud:plaud-pipeline". Rescues unattended `sdk-cli` sessions that
    /// have no ai-title and no free-text prompt to fall back on.
    case slashCommand
    /// Nothing usable was found anywhere in the read windows; `title`
    /// equals `shortId`.
    case sessionId
}

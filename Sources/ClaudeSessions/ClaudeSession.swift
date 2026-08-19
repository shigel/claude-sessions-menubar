import Foundation

/// A single Claude Code session, backed by one
/// ~/.claude/projects/<encoded-dir>/<sessionId>.jsonl file.
///
/// Sub-agent transcripts under <projDir>/<sessionId>/subagents/** are NOT
/// sessions and are never represented here — `SessionScanner`'s two-level,
/// non-recursive directory walk excludes them by construction.
struct ClaudeSession: Identifiable, Equatable, Hashable {
    /// Session UUID, equal to the jsonl file's basename for every session
    /// observed on disk.
    ///
    /// NOT assumed unique: profiles are independent config trees, and
    /// seeding one from another (`cp -r ~/.claude ~/.claude-vanilla`, which
    /// is exactly what a "compare against a clean profile" workflow does)
    /// duplicates session ids wholesale. Row identity therefore keys on
    /// `fileURL` instead, which is unique by construction.
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
    /// Which Claude Code config directory this session was found under (see
    /// `ClaudeProfile`); nil for the default `~/.claude`. Display-only — the
    /// scanner groups by `cwd` regardless of profile, because the editor
    /// window a project row opens is the same one no matter which profile
    /// the session was recorded in.
    let profileLabel: String?

    // `fileURL.path`, not `sessionId` — see `sessionId`'s doc comment above:
    // it's not unique across profiles, so using it here would contradict
    // `Identifiable`'s contract the same way it would have for `RowID`
    // (AI review nit on PR #6).
    var id: String { fileURL.path }
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

import Foundation

/// Pure functions implementing the session title fallback chain, kept
/// separate from `SessionScanner`'s file I/O so they can be exercised
/// directly against arbitrary line arrays (there is no test target in this
/// package — see `Package.swift` — but keeping these argument-in/value-out
/// makes them checkable with an ad-hoc script against the real dataset
/// without needing one).
///
/// Every function here operates on already-read, already-line-split byte
/// arrays (see `SessionScanner.readHeadWindow`/`readTailWindow`) and does
/// no file I/O of its own.
enum SessionTitleExtractor {
    private static let maxTitleLength = 200

    /// Byte-level markers used to skip JSON-parsing lines that can't
    /// possibly match any of the three tail-window title types. The tail
    /// window is dominated by fat assistant/tool_result lines (2-3KB each)
    /// that this filter rejects for a fraction of the cost of parsing them.
    private static let titleFieldMarkers: [Data] = [
        Data("custom-title".utf8), Data("ai-title".utf8), Data("last-prompt".utf8)
    ]

    /// Scans a tail window (see `SessionScanner.readTailWindow`) for the
    /// three tail-window rungs of the fallback chain, in priority order:
    /// custom-title > ai-title > last-prompt. Returns nil if none matched —
    /// callers fall through to `slashCommandFromHeadWindow`, then finally
    /// the session id itself.
    static func titleFromTailWindow(_ lines: [Data]) -> (title: String, source: TitleSource)? {
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?

        for line in lines {
            guard containsAny(line, of: titleFieldMarkers) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "custom-title":
                if customTitle == nil, let value = obj["customTitle"] as? String, !value.isEmpty {
                    customTitle = value
                }
            case "ai-title":
                // First hit wins. ai-title is appended on every turn (up to
                // 100+ times in one file), but its value was verified to
                // stay identical from the first occurrence to the last in
                // every sampled file — so the earliest hit found while
                // scanning the tail window forward is equivalent to (and
                // cheaper than) locating the true first occurrence, which
                // can sit far outside this window (median 56KB into the
                // file, max 2.6MB).
                if aiTitle == nil, let value = obj["aiTitle"] as? String, !value.isEmpty {
                    aiTitle = value
                }
            case "last-prompt":
                // Last hit wins, unconditionally overwriting any prior
                // match: last-prompt is appended every turn, and the line
                // nearest the START of a resumed session can carry over the
                // PREVIOUS session's prompt — only the most recent
                // occurrence reflects what this session is actually doing.
                //
                // Two variants of this line type exist: one carrying a
                // `lastPrompt` string, one carrying only a `leafUuid`
                // pointer to a message elsewhere in the file. Resolving the
                // pointer would require a full-file scan, which this
                // extractor deliberately never does — so the field's
                // presence and non-emptiness is checked explicitly rather
                // than trusting `type` alone to mean usable content.
                if let value = obj["lastPrompt"] as? String, !value.isEmpty {
                    lastPrompt = value
                }
            default:
                continue
            }
        }

        if let customTitle, let sanitized = sanitizeTitle(customTitle) {
            return (sanitized, .customTitle)
        }
        if let aiTitle, let sanitized = sanitizeTitle(aiTitle) {
            return (sanitized, .aiTitle)
        }
        if let lastPrompt, let sanitized = sanitizeTitle(lastPrompt) {
            return (sanitized, .lastPrompt)
        }
        return nil
    }

    /// Looks for a slash command name in the first user message of a head
    /// window. Rescues sessions that have neither an ai-title nor usable
    /// last-prompt text to fall back on — overwhelmingly unattended
    /// `sdk-cli` runs, whose first (and often only) user message is markup
    /// like `<command-name>/plaud:plaud-pipeline</command-name>` rather than
    /// free-text prose.
    ///
    /// Sessions whose first user message is ONLY wrapper markup with no
    /// `<command-name>` tag inside (e.g. a bare `<local-command-caveat>` or
    /// `<system-reminder>`) fall through here by construction: the regex
    /// requires an actual command-name tag to match, so wrapper-only
    /// content simply produces no match and the caller moves on to the
    /// session-id rung. This is deliberate — surfacing the wrapper text
    /// would make every such session show the same unhelpful string.
    static func slashCommandFromHeadWindow(_ lines: [Data]) -> String? {
        let commandNameMarker = Data("command-name".utf8)
        for line in lines {
            guard line.range(of: commandNameMarker) != nil else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["type"] as? String) == "user",
                  let message = obj["message"] as? [String: Any],
                  let text = plainText(fromMessageContent: message["content"]) else { continue }
            if let command = firstCommandName(in: text) {
                return command
            }
        }
        return nil
    }

    /// `message.content` in Claude Code jsonl is either a plain string or
    /// an array of content blocks; text-bearing blocks carry `type=="text"`.
    private static func plainText(fromMessageContent content: Any?) -> String? {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            let text = blocks
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func firstCommandName(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<command-name>(/[^<]+)</command-name>") else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let commandRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[commandRange])
    }

    /// Collapses all whitespace runs (including embedded newlines) into
    /// single spaces, trims, and truncates to `maxTitleLength` with an
    /// ellipsis. `lastPrompt` in particular is multi-line free text, so
    /// this is the single choke point that guarantees every
    /// `ClaudeSession.title` is single-line and bounded — the UI can render
    /// it with no further sanitizing. Returns nil if nothing but whitespace
    /// remains after trimming, so an empty rung is treated the same as a
    /// missing one.
    static func sanitizeTitle(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > maxTitleLength {
            return String(collapsed.prefix(maxTitleLength)) + "…"
        }
        return collapsed
    }

    private static func containsAny(_ data: Data, of markers: [Data]) -> Bool {
        markers.contains { data.range(of: $0) != nil }
    }
}

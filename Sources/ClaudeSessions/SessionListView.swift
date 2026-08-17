import SwiftUI

/// Identifies either a project row or a session child row in the flattened
/// list `SessionListViewModel.visibleRows` produces. An enum rather than a
/// prefixed String: project paths can contain arbitrary characters, so no
/// separator character could be picked that's guaranteed not to collide
/// with a real path.
enum RowID: Hashable {
    case project(String)   // ProjectSession.path
    case session(String)   // ClaudeSession.sessionId
}

/// One row as the user sees it, in visual (top-to-bottom) order. Session
/// rows always carry their parent `project`, because selecting or opening a
/// session row does exactly what selecting the parent project row does —
/// focus/open that project's editor window. There is no `claude --resume`
/// here; the session row's only job is to let the user tell sessions apart
/// in the list.
struct Row: Identifiable {
    enum Kind {
        case project
        case session(ClaudeSession)
    }

    let kind: Kind
    let project: ProjectSession
    let id: RowID
    /// Project rows only: true when the project has 2+ sessions, i.e. has
    /// something to disambiguate. Always false for session rows.
    let isExpandable: Bool
    /// Project rows only: whether its session children are currently shown.
    let isExpanded: Bool
    /// Project rows only: how many sessions are visible under this project
    /// right now (after search filtering) — shown as a small count badge.
    let visibleSessionCount: Int
}

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [ProjectSession] = []
    @Published var searchText: String = "" {
        didSet { syncSelectionIfNeeded() }
    }
    @Published var isLoading: Bool = false
    @Published var statusMessage: String?
    @Published var windowPicker: WindowPickerState?
    @Published var hasAccessibilityPermission: Bool = WindowController.checkAccessibilityPermission(prompt: false)
    /// Currently highlighted row in the session list, driven by keyboard
    /// navigation (arrow keys) or mouse hover/click via `List(selection:)`.
    @Published var selectedID: RowID?
    /// Which project rows the user has expanded to reveal their session
    /// children, keyed by `ProjectSession.path`. Deliberately reset at the
    /// start of every `refresh()` (see decision "パネルを開くたびに畳む" in
    /// the plan) — unlike `searchText`/`selectedID`, which keep their
    /// existing behavior of persisting across popover open/close, expansion
    /// always starts collapsed so a stale wall of session rows never
    /// greets the user on reopen.
    @Published var expandedProjects: Set<String> = []

    /// Prefetched editor window list, started as soon as the popover opens
    /// (in parallel with the session scan in `refresh()`) so that
    /// `selectSession(_:)` doesn't have to pay for the `osascript`
    /// round-trip synchronously when the user makes a selection. Cancelled
    /// and restarted on every `refresh()` — open windows can change while
    /// the popover is open, so this is a short-lived cache, not a
    /// long-lived one.
    private var windowsPrefetchTask: Task<[EditorWindow], Never>?

    struct WindowPickerState: Identifiable {
        let id = UUID()
        let session: ProjectSession
        let windows: [EditorWindow]
        /// Currently highlighted window in the picker sub-list.
        var selectedWindowID: EditorWindow.ID?
    }

    /// A project after search filtering, carrying only the sessions that
    /// matched (or all of them, if the project row itself matched the
    /// query).
    private struct FilteredProject {
        let project: ProjectSession
        let sessions: [ClaudeSession]
        /// True when the query matched only children, never the project
        /// row itself — such a project must render expanded regardless of
        /// `expandedProjects`, or the matching sessions the user searched
        /// for would stay hidden.
        let forceExpanded: Bool
    }

    /// Search matching. When the project row itself matches (basename or
    /// path), every session survives so browsing an already-found project
    /// isn't further filtered. When only session titles match, the project
    /// is still shown but narrowed to just the matching sessions, and
    /// force-expanded — otherwise searching a project with 69 sessions for
    /// one title would surface all 69 instead of the one that matched.
    private var filteredProjects: [FilteredProject] {
        guard !searchText.isEmpty else {
            return sessions.map { FilteredProject(project: $0, sessions: $0.sessions, forceExpanded: false) }
        }
        let needle = searchText.lowercased()
        return sessions.compactMap { project -> FilteredProject? in
            let projectMatches = project.basename.lowercased().contains(needle) || project.path.lowercased().contains(needle)
            if projectMatches {
                return FilteredProject(project: project, sessions: project.sessions, forceExpanded: false)
            }
            let matchingSessions = project.sessions.filter {
                $0.title.lowercased().contains(needle) || $0.shortId.lowercased().contains(needle)
            }
            guard !matchingSessions.isEmpty else { return nil }
            return FilteredProject(project: project, sessions: matchingSessions, forceExpanded: true)
        }
    }

    /// Flattens `filteredProjects` into the rows the `List` actually
    /// renders, in visual order. This single array is what makes keyboard
    /// up/down "just work" across the project/session boundary:
    /// `List(selection:)` walks whatever this returns, so parent-to-child
    /// traversal needs no extra code beyond List's built-in behavior — the
    /// alternative (`DisclosureGroup`/`OutlineGroup`) would hide this
    /// flattening inside the List and make left/right-arrow handling and
    /// force-expand-on-search much harder to reason about.
    var visibleRows: [Row] {
        filteredProjects.flatMap { entry -> [Row] in
            let isExpandable = entry.project.isExpandable
            let isExpanded = entry.forceExpanded || expandedProjects.contains(entry.project.path)
            let projectRow = Row(
                kind: .project,
                project: entry.project,
                id: .project(entry.project.path),
                isExpandable: isExpandable,
                isExpanded: isExpanded,
                visibleSessionCount: entry.sessions.count
            )
            guard isExpandable, isExpanded else { return [projectRow] }
            let sessionRows = entry.sessions.map { session in
                Row(
                    kind: .session(session),
                    project: entry.project,
                    id: .session(session.sessionId),
                    isExpandable: false,
                    isExpanded: false,
                    visibleSessionCount: 0
                )
            }
            return [projectRow] + sessionRows
        }
    }

    func refresh() async {
        isLoading = true
        expandedProjects.removeAll()

        // Start the (slow, osascript-backed) window enumeration in parallel
        // with the session scan, and keep the Task around so
        // `selectSession(_:)` can just await its result instead of kicking
        // off a fresh, synchronous AppleScript call at selection time.
        // Cancel any previous prefetch first: window state may have changed
        // since the popover was last open, so we don't want to serve a
        // stale result.
        windowsPrefetchTask?.cancel()
        windowsPrefetchTask = Task { await WindowController.listEditorWindows() }

        sessions = await SessionScanner.scan()
        isLoading = false
        hasAccessibilityPermission = WindowController.checkAccessibilityPermission(prompt: false)
        syncSelectionIfNeeded()
    }

    /// Keeps `selectedID` pointing at a row that's still present in
    /// `visibleRows` (e.g. after search narrows the list, or a project gets
    /// collapsed). Falls back to the parent project row — rather than
    /// jumping to the top of the list — when the previously-selected
    /// session row disappears because its project just collapsed; without
    /// this, pressing left-arrow on a session row would fling the cursor
    /// back to row one instead of leaving it on the now-collapsed parent.
    func syncSelectionIfNeeded() {
        let rows = visibleRows
        if let selectedID, rows.contains(where: { $0.id == selectedID }) {
            return
        }
        if case .session(let sessionId)? = selectedID,
           let parentProject = sessions.first(where: { project in project.sessions.contains { $0.sessionId == sessionId } }),
           rows.contains(where: { $0.id == .project(parentProject.path) }) {
            selectedID = .project(parentProject.path)
            return
        }
        selectedID = rows.first?.id
    }

    /// Keeps the window picker's selection pointing at a valid row,
    /// defaulting to the first window.
    func syncWindowSelectionIfNeeded() {
        guard var picker = windowPicker else { return }
        if picker.selectedWindowID == nil || !picker.windows.contains(where: { $0.id == picker.selectedWindowID }) {
            picker.selectedWindowID = picker.windows.first?.id
            windowPicker = picker
        }
    }

    func row(for id: RowID) -> Row? {
        visibleRows.first { $0.id == id }
    }

    /// Opens whichever row is currently selected (`selectedID`), if any.
    /// Shared by the list's `.onKeyPress(.return)` and the search field's
    /// `.onSubmit` (issue #8), so Enter opens the selected row the same way
    /// regardless of which of the two controls currently has keyboard focus.
    @discardableResult
    func openSelectedRow() -> Bool {
        guard let id = selectedID, let row = row(for: id) else { return false }
        Task { await selectSession(row.project) }
        return true
    }

    func toggleExpansion(_ path: String) {
        if expandedProjects.contains(path) {
            collapse(path)
        } else {
            expand(path)
        }
    }

    /// Returns whether this call actually changed anything, so keyboard
    /// handlers can tell a real state change (→ `.handled`) apart from a
    /// no-op on an already-expanded/single-session row (→ `.ignored`).
    @discardableResult
    func expand(_ path: String) -> Bool {
        guard expandedProjects.insert(path).inserted else { return false }
        return true
    }

    @discardableResult
    func collapse(_ path: String) -> Bool {
        guard expandedProjects.remove(path) != nil else { return false }
        syncSelectionIfNeeded()
        return true
    }

    /// Core selection flow: find editor windows already open for this project.
    /// - exactly one match -> focus it
    /// - no match -> open with the remembered/default editor
    /// - multiple matches -> let the user pick which window to focus
    func selectSession(_ session: ProjectSession) async {
        statusMessage = "ウィンドウを検索中…"
        // Await the prefetch started in `refresh()` rather than kicking off
        // a fresh AppleScript call here: by the time the user has picked a
        // session, the prefetch has usually already finished, so this
        // returns near-instantly. Fall back to a direct call only if
        // `refresh()` was never called (shouldn't happen in practice, since
        // the popover always calls it on open).
        let windows: [EditorWindow]
        if let prefetch = windowsPrefetchTask {
            windows = await prefetch.value
        } else {
            windows = await WindowController.listEditorWindows()
        }
        let matches = WindowController.matchWindowsForProject(windows, basename: session.basename)

        if matches.count == 1 {
            await focus(window: matches[0])
            return
        }

        if matches.count > 1 {
            statusMessage = nil
            windowPicker = WindowPickerState(session: session, windows: matches, selectedWindowID: matches.first?.id)
            return
        }

        await openWithPreferredEditor(session)
    }

    func focus(window: EditorWindow) async {
        do {
            try await WindowController.focusWindow(processName: window.processName, title: window.title)
            statusMessage = "\(window.title) をフォーカスしました"
        } catch {
            statusMessage = "フォーカス失敗: \(error.localizedDescription)"
        }
    }

    func openWithPreferredEditor(_ session: ProjectSession) async {
        let editorId = PreferenceStore.preferredEditorId(forProjectPath: session.path)
        guard let editor = EditorRegistry.editor(withId: editorId) else {
            statusMessage = "エディタが設定されていません"
            return
        }
        await open(session, with: editor)
    }

    func open(_ session: ProjectSession, with editor: EditorDef) async {
        statusMessage = "\(editor.name) で開いています…"
        do {
            try WindowController.openInEditor(appName: editor.appName, path: session.path)
            PreferenceStore.setPreferredEditorId(editor.id, forProjectPath: session.path)
            statusMessage = "\(editor.name) で開きました"
        } catch {
            statusMessage = "起動失敗: \(error.localizedDescription)"
        }
    }

    func requestAccessibilityPermission() {
        WindowController.checkAccessibilityPermission(prompt: true)
        WindowController.openAccessibilitySettings()
    }
}

struct SessionListView: View {
    @ObservedObject var viewModel: SessionListViewModel

    /// Which control currently has keyboard focus. Drives the
    /// search-field -> list handoff on down-arrow.
    private enum FocusTarget: Hashable {
        case search
        case list
    }

    @FocusState private var focusTarget: FocusTarget?

    /// AppKit-level monitor for the down-arrow key, used to hand focus from
    /// the search field to the list. Deliberately NOT implemented with
    /// SwiftUI's `.onKeyPress(.downArrow)` attached to the `TextField`:
    /// on macOS 14 hosting, attaching `onKeyPress` directly to a `TextField`
    /// has been observed to also intercept/interfere with ordinary character
    /// input (including IME composition), breaking search filtering. Reading
    /// the event at the AppKit layer and always returning it unmodified
    /// avoids that failure mode entirely — the TextField still receives
    /// every keystroke; we only piggyback on the down-arrow to move focus.
    @State private var downArrowMonitor: Any?

    /// AppKit-level monitor for character key presses while the list has
    /// focus, redirecting them into the search field (issue #8). Unlike
    /// `downArrowMonitor`, which lets its key event pass through unmodified,
    /// this one consumes the event and appends its characters to
    /// `searchText` directly: a `@FocusState` change made here would not
    /// take effect within the same run-loop turn, so simply moving focus and
    /// letting the keystroke pass through would drop the character instead
    /// of landing it in the now-focused field.
    @State private var listTypingMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.hasAccessibilityPermission {
                accessibilityBanner
            }

            searchField

            Divider()

            if let picker = viewModel.windowPicker {
                windowPickerView(picker)
            } else {
                sessionList
            }

            if let status = viewModel.statusMessage {
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 420, height: 480)
        .task {
            await viewModel.refresh()
            focusTarget = .search
        }
        .onAppear {
            if downArrowMonitor == nil {
                downArrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == KeyCode.downArrow, focusTarget == .search else { return event }
                    guard !viewModel.visibleRows.isEmpty else { return event }
                    viewModel.syncSelectionIfNeeded()
                    focusTarget = .list
                    // Always pass the event through: this monitor only ever
                    // observes, never consumes, so it can't block character
                    // input reaching the TextField.
                    return event
                }
            }
            if listTypingMonitor == nil {
                listTypingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard focusTarget == .list,
                          event.modifierFlags.intersection([.command, .control]).isEmpty,
                          !KeyCode.nonCharacterKeys.contains(event.keyCode),
                          let characters = event.characters, !characters.isEmpty else {
                        return event
                    }
                    viewModel.searchText += characters
                    focusTarget = .search
                    // Consumed: the character has already been redirected
                    // into `searchText` above, so letting it also reach the
                    // list (or anything else) would be a double-input.
                    return nil
                }
            }
        }
        .onDisappear {
            if let downArrowMonitor {
                NSEvent.removeMonitor(downArrowMonitor)
            }
            downArrowMonitor = nil
            if let listTypingMonitor {
                NSEvent.removeMonitor(listTypingMonitor)
            }
            listTypingMonitor = nil
        }
    }

    private enum KeyCode {
        /// Virtual keycode for the down-arrow key.
        static let downArrow: UInt16 = 125
        /// Keycodes `listTypingMonitor` must leave alone — navigation/editing
        /// keys the list already handles itself (via `.onKeyPress` above, or
        /// `List`'s own default behavior) rather than redirecting to search.
        static let nonCharacterKeys: Set<UInt16> = [
            125, // down arrow
            126, // up arrow
            123, // left arrow
            124, // right arrow
            36,  // return
            76,  // keypad enter
            53,  // escape
            48,  // tab
            51,  // delete/backspace
            117, // forward delete
        ]
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("アクセシビリティ権限がありません")
                .font(.caption.bold())
            Text("ウィンドウの検出・フォーカスにはアクセシビリティ権限が必要です。権限が無くてもエディタでの新規オープンは動作します。")
                .font(.caption2)
                .foregroundColor(.secondary)
            Button("システム設定を開く") {
                viewModel.requestAccessibilityPermission()
            }
            .font(.caption)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("プロジェクトを検索…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .focused($focusTarget, equals: .search)
                .onSubmit {
                    // issue #8: Enter while the search field has focus opens
                    // the currently selected row, same as Enter does when
                    // the list itself has focus. `.onSubmit` (rather than
                    // `.onKeyPress(.return)`) is deliberate here — attaching
                    // `.onKeyPress` directly to a `TextField` is the exact
                    // failure mode `downArrowMonitor`'s doc comment warns
                    // about (breaks IME composition); `.onSubmit` only fires
                    // once Return has actually committed the field.
                    viewModel.openSelectedRow()
                }
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(8)
    }

    private var sessionList: some View {
        List(selection: $viewModel.selectedID) {
            ForEach(viewModel.visibleRows) { row in
                rowView(for: row)
                    .tag(row.id)
            }
        }
        .listStyle(.plain)
        .focused($focusTarget, equals: .list)
        .onKeyPress(.return) {
            viewModel.openSelectedRow() ? .handled : .ignored
        }
        // Left/right arrow handling is safe as `.onKeyPress` on `List` for
        // the same reason `.onKeyPress(.return)` above already was: the
        // IME-breaking failure mode documented on `downArrowMonitor` was
        // specific to attaching `onKeyPress` to a `TextField`, which holds
        // IME composition state. `List` has no text composition state to
        // corrupt, so no `NSEvent`-monitor workaround is needed here.
        .onKeyPress(.rightArrow) {
            guard let id = viewModel.selectedID, let row = viewModel.row(for: id) else { return .ignored }
            switch row.kind {
            case .session:
                return .ignored
            case .project:
                guard row.isExpandable else { return .ignored }
                if !row.isExpanded {
                    viewModel.expand(row.project.path)
                    return .handled
                }
                // Already expanded: move selection down onto its first
                // child, which — by construction of `visibleRows` — is the
                // very next row after this project row.
                let rows = viewModel.visibleRows
                if let index = rows.firstIndex(where: { $0.id == id }), index + 1 < rows.count,
                   case .session = rows[index + 1].kind {
                    viewModel.selectedID = rows[index + 1].id
                }
                return .handled
            }
        }
        .onKeyPress(.leftArrow) {
            guard let id = viewModel.selectedID, let row = viewModel.row(for: id) else { return .ignored }
            switch row.kind {
            case .session:
                viewModel.collapse(row.project.path)
                return .handled
            case .project:
                guard row.isExpanded else { return .ignored }
                viewModel.collapse(row.project.path)
                return .handled
            }
        }
    }

    @ViewBuilder
    private func rowView(for row: Row) -> some View {
        switch row.kind {
        case .project:
            ProjectRow(row: row, viewModel: viewModel)
        case .session(let session):
            SessionChildRow(row: row, session: session, viewModel: viewModel)
        }
    }

    private func windowPickerView(_ picker: SessionListViewModel.WindowPickerState) -> some View {
        WindowPickerView(picker: picker, viewModel: viewModel)
    }
}

/// Extracted into its own `View` type (rather than a computed-property
/// helper) so `@FocusState` has a stable identity to attach to across
/// re-renders while the window picker is open.
private struct WindowPickerView: View {
    let picker: SessionListViewModel.WindowPickerState
    @ObservedObject var viewModel: SessionListViewModel

    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    viewModel.windowPicker = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Text("複数のウィンドウが見つかりました — 選択してください")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)

            List(selection: windowSelectionBinding) {
                ForEach(picker.windows) { window in
                    VStack(alignment: .leading) {
                        Text(window.title)
                        Text(EditorRegistry.editor(withId: window.editorId)?.name ?? window.processName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .tag(window.id)
                    .onTapGesture {
                        Task {
                            await viewModel.focus(window: window)
                            viewModel.windowPicker = nil
                        }
                    }
                }
            }
            .listStyle(.plain)
            .focused($listFocused)
            .onKeyPress(.return) {
                guard let id = viewModel.windowPicker?.selectedWindowID,
                      let window = picker.windows.first(where: { $0.id == id }) else { return .ignored }
                Task {
                    await viewModel.focus(window: window)
                    viewModel.windowPicker = nil
                }
                return .handled
            }
        }
        .task {
            viewModel.syncWindowSelectionIfNeeded()
            listFocused = true
        }
    }

    private var windowSelectionBinding: Binding<EditorWindow.ID?> {
        Binding(
            get: { viewModel.windowPicker?.selectedWindowID },
            set: { viewModel.windowPicker?.selectedWindowID = $0 }
        )
    }
}

/// A top-level project row. Carries its own disclosure chevron (only drawn
/// when `row.isExpandable`) separated from the row's tap target so tapping
/// the chevron toggles expansion without also triggering
/// `selectSession(_:)`.
private struct ProjectRow: View {
    let row: Row
    @ObservedObject var viewModel: SessionListViewModel

    /// Fixed-width gutter the chevron lives in, kept reserved even when no
    /// chevron is drawn (single-session projects) so every project row's
    /// icon/text lines up regardless of expandability.
    private static let chevronGutterWidth: CGFloat = 12

    var body: some View {
        let session = row.project
        HStack(spacing: 8) {
            if row.isExpandable {
                Button {
                    viewModel.toggleExpansion(session.path)
                } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: Self.chevronGutterWidth)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: Self.chevronGutterWidth)
            }
            Image(systemName: session.exists ? "folder" : "exclamationmark.triangle")
                .foregroundColor(session.exists ? .accentColor : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.basename)
                    .fontWeight(.medium)
                Text(session.path)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if row.visibleSessionCount > 1 {
                Text("\(row.visibleSessionCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .foregroundColor(session.exists ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedID = row.id
            Task { await viewModel.selectSession(session) }
        }
        .contextMenu {
            ForEach(EditorRegistry.editors) { editor in
                Button("\(editor.name) で開く") {
                    Task { await viewModel.open(session, with: editor) }
                }
            }
        }
    }
}

/// A session child row, shown nested under its expanded parent project row.
/// Selecting/opening it defers entirely to `row.project` — see `Row`'s doc
/// comment — so its only job is to be visually distinguishable from
/// siblings sharing the same project.
private struct SessionChildRow: View {
    let row: Row
    let session: ClaudeSession
    @ObservedObject var viewModel: SessionListViewModel

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            // Indent past the project row's chevron gutter + icon so
            // session titles align under the project name, not the chevron.
            Color.clear.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                    // .tail, not .middle: the fallback chain front-loads the
                    // identifying words (a slash command name, the start of
                    // a prompt), so keeping the head of the string legible
                    // matters more than keeping the tail.
                    .truncationMode(.tail)
                    // Titles with no real material (titleSource == .sessionId)
                    // are deliberately muted so the eye isn't drawn to a row
                    // that carries no useful information beyond its id.
                    .foregroundColor(session.titleSource == .sessionId ? .secondary : .primary)
                HStack(spacing: 4) {
                    Text(Self.relativeFormatter.localizedString(for: session.lastActive, relativeTo: Date()))
                    if session.entrypoint == "sdk-cli" {
                        badge("auto")
                    }
                    if session.isBackground {
                        badge("bg")
                    }
                    if session.entrypoint == "claude-desktop" {
                        badge("desktop")
                    }
                    // Always shown, not just as a fallback label: sessions
                    // with the same ai-generated title exist (fork/resume
                    // pairs), so the short id is the only reliable way to
                    // tell such rows apart.
                    Text(session.shortId)
                        .font(.system(.caption2, design: .monospaced))
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedID = row.id
            Task { await viewModel.selectSession(row.project) }
        }
        .contextMenu {
            ForEach(EditorRegistry.editors) { editor in
                Button("\(editor.name) で開く") {
                    Task { await viewModel.open(row.project, with: editor) }
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

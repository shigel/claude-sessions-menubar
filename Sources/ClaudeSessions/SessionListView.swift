import SwiftUI

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
    @Published var selectedID: ProjectSession.ID?

    struct WindowPickerState: Identifiable {
        let id = UUID()
        let session: ProjectSession
        let windows: [EditorWindow]
        /// Currently highlighted window in the picker sub-list.
        var selectedWindowID: EditorWindow.ID?
    }

    var filteredSessions: [ProjectSession] {
        guard !searchText.isEmpty else { return sessions }
        let needle = searchText.lowercased()
        return sessions.filter { $0.basename.lowercased().contains(needle) || $0.path.lowercased().contains(needle) }
    }

    func refresh() async {
        isLoading = true
        sessions = await SessionScanner.scan()
        isLoading = false
        hasAccessibilityPermission = WindowController.checkAccessibilityPermission(prompt: false)
        syncSelectionIfNeeded()
    }

    /// Keeps `selectedID` pointing at a row that's still present in
    /// `filteredSessions` (e.g. after the search text narrows the list),
    /// defaulting to the first row so Return-to-open works immediately.
    func syncSelectionIfNeeded() {
        if selectedID == nil || !filteredSessions.contains(where: { $0.id == selectedID }) {
            selectedID = filteredSessions.first?.id
        }
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

    /// Core selection flow: find editor windows already open for this project.
    /// - exactly one match -> focus it
    /// - no match -> open with the remembered/default editor
    /// - multiple matches -> let the user pick which window to focus
    func selectSession(_ session: ProjectSession) async {
        statusMessage = "ウィンドウを検索中…"
        let windows = await WindowController.listEditorWindows()
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
            guard downArrowMonitor == nil else { return }
            downArrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == KeyCode.downArrow, focusTarget == .search else { return event }
                guard !viewModel.filteredSessions.isEmpty else { return event }
                viewModel.syncSelectionIfNeeded()
                focusTarget = .list
                // Always pass the event through: this monitor only ever
                // observes, never consumes, so it can't block character
                // input reaching the TextField.
                return event
            }
        }
        .onDisappear {
            if let downArrowMonitor {
                NSEvent.removeMonitor(downArrowMonitor)
            }
            downArrowMonitor = nil
        }
    }

    private enum KeyCode {
        /// Virtual keycode for the down-arrow key.
        static let downArrow: UInt16 = 125
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
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(8)
    }

    private var sessionList: some View {
        List(selection: $viewModel.selectedID) {
            ForEach(viewModel.filteredSessions) { session in
                SessionRow(session: session, viewModel: viewModel)
                    .tag(session.id)
            }
        }
        .listStyle(.plain)
        .focused($focusTarget, equals: .list)
        .onKeyPress(.return) {
            guard let id = viewModel.selectedID,
                  let session = viewModel.filteredSessions.first(where: { $0.id == id }) else { return .ignored }
            Task { await viewModel.selectSession(session) }
            return .handled
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

private struct SessionRow: View {
    let session: ProjectSession
    @ObservedObject var viewModel: SessionListViewModel

    var body: some View {
        HStack(spacing: 8) {
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
        }
        .foregroundColor(session.exists ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedID = session.id
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

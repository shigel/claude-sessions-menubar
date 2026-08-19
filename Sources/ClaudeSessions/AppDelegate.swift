import AppKit
import IOKit.hid
import ServiceManagement
import SwiftUI

/// Transparent overlay placed on top of the status bar button that intercepts
/// clicks directly via `mouseDown`/`rightMouseDown`, instead of relying on
/// `NSApp.currentEvent` inside a shared button action (which is unreliable:
/// AppKit's event dispatch timing can make `currentEvent` report the wrong
/// event type by the time the action fires). This gives an unambiguous,
/// per-gesture callback for left vs. right clicks.
private final class StatusItemClickCatcherView: NSView {
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        (superview as? NSButton)?.highlight(true)
    }

    override func mouseUp(with event: NSEvent) {
        (superview as? NSButton)?.highlight(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onLeftClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // No highlight for right-click; showStatusMenu() drives its own
        // NSMenu presentation via performClick(nil).
    }

    override func rightMouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onRightClick?()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showPopoverNotification = Notification.Name("jp.co.najimino.claude-sessions.showPopover")

    /// ⌥⌘K
    private static let hotKeyModifiers: NSEvent.ModifierFlags = [.command, .option]
    private static let hotKeyCode: UInt16 = 0x28 // kVK_ANSI_K

    /// Matches `SessionListView`'s `.frame(width:height:)`.
    private static let panelWidth: CGFloat = 420
    private static let panelHeight: CGFloat = 480
    private static let panelCornerRadius: CGFloat = 12

    private var statusItem: NSStatusItem?
    private var sessionWindow: SessionPanelWindow?
    private var dismissMonitor: Any?
    private var hotKeyGlobalMonitor: Any?
    private var hotKeyLocalMonitor: Any?
    private var sessionListViewModel: SessionListViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude Sessions")

            // Intercept clicks via an overlay view rather than a single button
            // action + NSApp.currentEvent (see StatusItemClickCatcherView for
            // why). NSStatusItem.button is a get-only property, so we can't
            // swap in a custom NSStatusBarButton subclass directly; an
            // overlay subview achieves the same "override mouseDown /
            // rightMouseDown directly" effect without relying on undocumented
            // behavior.
            let clickCatcher = StatusItemClickCatcherView(frame: button.bounds)
            clickCatcher.autoresizingMask = [.width, .height]
            clickCatcher.onLeftClick = { [weak self] in self?.handleLeftClick() }
            clickCatcher.onRightClick = { [weak self] in self?.showStatusMenu() }
            button.addSubview(clickCatcher)
        }
        self.statusItem = statusItem

        let viewModel = SessionListViewModel()
        // issue #9: close the popover once a session was actually opened, so
        // it doesn't stay open (blocking the global shortcut from reopening
        // it) after the user has already navigated away to the editor.
        viewModel.onSessionOpened = { [weak self] in self?.closePopover() }
        self.sessionListViewModel = viewModel
        let view = SessionListView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let panelBounds = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        hostingView.frame = panelBounds
        hostingView.autoresizingMask = [.width, .height]

        // NSVisualEffectView + rounded corners approximates NSPopover's
        // white rounded-card chrome, which the borderless window otherwise
        // has none of.
        let effectView = NSVisualEffectView(frame: panelBounds)
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Self.panelCornerRadius
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]
        effectView.addSubview(hostingView)

        let window = SessionPanelWindow(
            contentRect: panelBounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.isReleasedWhenClosed = false
        window.contentView = effectView
        window.onCancel = { [weak self] in self?.closePopover() }
        self.sessionWindow = window

        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }

        // Global monitor: catches the hotkey when ClaudeSessions is NOT the
        // active app. Per NSEvent.addGlobalMonitorForEvents documentation,
        // this monitor never fires while our own app is active.
        hotKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isHotKey(event) else { return }
            DispatchQueue.main.async {
                self?.openPopover()
            }
        }

        // Local monitor: catches the hotkey when ClaudeSessions IS the active
        // app (e.g. right after openPopover() calls NSApp.activate). Without
        // this, pressing the hotkey a second time while the popover/app is
        // active would silently do nothing.
        hotKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isHotKey(event) else { return event }
            self?.openPopover()
            return nil
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowPopoverNotification),
            name: Self.showPopoverNotification,
            object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
        }
        if let hotKeyGlobalMonitor {
            NSEvent.removeMonitor(hotKeyGlobalMonitor)
        }
        if let hotKeyLocalMonitor {
            NSEvent.removeMonitor(hotKeyLocalMonitor)
        }
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private static func isHotKey(_ event: NSEvent) -> Bool {
        event.keyCode == hotKeyCode
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == hotKeyModifiers
    }

    @objc private func handleShowPopoverNotification() {
        openPopover()
    }

    private func handleLeftClick() {
        if sessionWindow?.isVisible == true {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        if !Self.hasInputMonitoringPermission() {
            let item = NSMenuItem(
                title: "⌥⌘K を使うには「入力監視」の許可が必要です",
                action: #selector(openInputMonitoringSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let loginItem = NSMenuItem(
            title: "ログイン時に起動", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private static func hasInputMonitoringPermission() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("ClaudeSessions: failed to toggle login item: \(error)")
            // NSLog alone is invisible to the user: the menu checkbox will
            // silently stay in its old state with no indication why (AI
            // review finding on PR #6). An alert is heavyweight for a menu
            // action, but registration failures here are rare enough
            // (SMAppService typically only errors on sandboxing/signing
            // issues) that surfacing them beats a checkbox that mysteriously
            // doesn't stick.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "ログイン時の起動設定を変更できませんでした"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func openPopover() {
        guard let window = sessionWindow, window.isVisible == false, statusItem?.button != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Defer the actual positioning/ordering to the next run-loop turn.
        // Computing the status item's screen frame synchronously right
        // after NSApp.activate can read a stale window/screen frame --
        // most visibly right after the global hotkey fires while a
        // different app was frontmost. Letting activation finish first (one
        // run-loop turn is enough; AppKit does not expose a completion
        // callback for NSApp.activate) fixes the positioning.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.sessionWindow, window.isVisible == false,
                  let button = self.statusItem?.button else { return }
            window.setFrameOrigin(Self.panelOrigin(for: button))
            window.makeKeyAndOrderFront(nil)
            Task { [weak self] in
                await self?.sessionListViewModel?.refresh()
            }
        }
    }

    /// Computes the top-left-docked screen position for the panel: its
    /// horizontal center aligned with the status item button, and its top
    /// edge flush against the button's bottom edge.
    ///
    /// AppKit's screen coordinate system has y increasing *upward*, with
    /// origin at the bottom-left of the primary screen. The menu bar sits
    /// at the top of the screen, so the status item button's frame has a
    /// *high* y value, and `button.frame.minY` is the button's bottom edge
    /// (the boundary between the menu bar and the desktop below it).
    /// `NSWindow`'s `frame.origin` is also its *bottom-left* corner in this
    /// same coordinate system. So docking the panel directly under the
    /// button means: the panel's top edge (`origin.y + panelHeight`) must
    /// equal the button's bottom edge (`buttonScreenFrame.minY`), i.e.
    /// `origin.y = buttonScreenFrame.minY - panelHeight`. Using the
    /// button's `midY` (its vertical center, as `NSPopover`'s automatic
    /// layout effectively behaves like) is what previously made the panel
    /// look centered on the menu bar instead of hanging below it.
    private static func panelOrigin(for button: NSStatusBarButton) -> NSPoint {
        let buttonScreenFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        var origin = NSPoint(
            x: buttonScreenFrame.midX - panelWidth / 2,
            y: buttonScreenFrame.minY - panelHeight)

        if let screen = button.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - panelWidth)
            origin.y = max(origin.y, visible.minY)
        }
        return origin
    }

    private func closePopover() {
        sessionWindow?.orderOut(nil)
    }
}

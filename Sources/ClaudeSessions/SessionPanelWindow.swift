import AppKit

/// Borderless replacement for the `NSPopover` previously used to host
/// `SessionListView`. `NSPopover`'s automatic screen-relative positioning
/// (`preferredEdge`) was observed to sometimes center the popover on the
/// status bar item instead of docking it directly underneath, clipping the
/// top of the list. This window is positioned explicitly by `AppDelegate`
/// instead of relying on that automatic layout.
///
/// Borderless windows default to `canBecomeKey == false`, which would break
/// keyboard input in the search field. Overriding it here restores that,
/// along with ESC-to-close (which `NSPopover` provided implicitly).
final class SessionPanelWindow: NSWindow {
    /// Invoked when the user presses ESC while this window is key, mirroring
    /// `NSPopover`'s default dismiss-on-Escape behavior.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

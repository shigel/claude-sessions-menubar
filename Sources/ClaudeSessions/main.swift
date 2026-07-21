import AppKit

let bundleIdentifier = Bundle.main.bundleIdentifier ?? "jp.co.najimino.claude-sessions"
let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

if let existing = otherInstances.first {
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.showPopoverNotification, object: bundleIdentifier, userInfo: nil, deliverImmediately: true)
    existing.activate()
    // Give the XPC-backed distributed notification a moment to actually go out
    // before the process disappears — posting doesn't block until delivery.
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

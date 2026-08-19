import CoreServices
import Foundation

/// Watches `~/.claude/projects` (and, transitively, every subdirectory —
/// FSEvents is recursive by construction) for filesystem changes and calls
/// `onChange` shortly after they settle.
///
/// This exists because `SessionScanner.scan()` only ever runs when the
/// popover opens (`SessionListViewModel.refresh()`), so a session created
/// while the popover is already open never appears until it's closed and
/// reopened. It also closes the two other gaps described in issue #2: a
/// brand-new project directory or a `cwd`-less first line both become
/// visible on the very next FSEvents-triggered rescan instead of waiting for
/// the next manual popover toggle.
///
/// FSEvents, not `DispatchSourceFileSystemObject`: the latter only reports
/// changes to entries directly inside the watched directory, not inside its
/// subdirectories — so it would miss new `.jsonl` files appearing inside
/// `<project-dir>/`, which is exactly the case this needs to catch.
///
/// Lifecycle: callers MUST call `stop()` when done watching — see its doc
/// comment for why plain deinit isn't enough here.
final class ProjectsWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    /// A dedicated SERIAL queue, not `DispatchQueue.global` (which is
    /// concurrent). `stop()` needs `FSEventStreamInvalidate` to run with a
    /// happens-before relationship to every already-enqueued/in-flight
    /// callback, so that once it returns, no callback can still be
    /// executing or about to start. A concurrent queue can't provide that
    /// guarantee — two blocks submitted to it may run simultaneously on
    /// different threads (AI review finding on PR #7).
    private let queue = DispatchQueue(label: "com.claudesessions.ProjectsWatcher")

    /// Coalescing window handed to FSEventStream itself (`latency`), not a
    /// manual debounce timer on our side: the OS already batches bursts of
    /// events (an entire session's worth of appended lines) into one
    /// callback when they land within this window, so a second layer of
    /// debouncing here would be redundant.
    private static let latencySeconds: CFTimeInterval = 0.5

    /// - Parameter paths: absolute directory paths to watch, e.g. every
    ///   discovered `ClaudeProfile.projectsDir`. Non-existent paths are
    ///   skipped by FSEventStreamCreate rather than causing a hard failure —
    ///   a profile can be removed while the app is running.
    init?(paths: [String], onChange: @escaping () -> Void) {
        guard !paths.isEmpty else { return nil }
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        // `passRetained`, not `passUnretained`: this makes `self` its own
        // owner for as long as the stream is alive, so the C callback below
        // can never fire against memory that's mid-deinit or already freed.
        // The matching release happens in `stop()`, once the stream is
        // fully invalidated and no further callback can occur — that's also
        // why `stop()` (not plain `deinit`) is this class's real teardown
        // entry point (AI review finding on PR #7: a `passUnretained`
        // context plus async-dispatched teardown left a use-after-free
        // window between `deinit` starting and the stream actually being
        // invalidated).
        context.info = Unmanaged.passRetained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let clientCallBackInfo else { return }
            let watcher = Unmanaged<ProjectsWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            watcher.onChange()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latencySeconds,
            UInt32(kFSEventStreamCreateFlagNoDefer)
        ) else {
            // Creation failed, so nothing will ever call `stop()` to balance
            // the `passRetained` above — release it here instead, or this
            // instance leaks permanently.
            Unmanaged<ProjectsWatcher>.fromOpaque(context.info!).release()
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stops watching, synchronously, on the same serial queue the stream is
    /// scheduled on — so by the time this returns, `onChange` is guaranteed
    /// not to fire again. Must be called explicitly by the owner before
    /// dropping its reference: `init` gave `self` an extra retain via the
    /// FSEvents callback context (see its comment), so a normal ARC
    /// `deinit` will never run on its own here — this method is what
    /// releases that retain, and is therefore this class's real
    /// destructor. Safe to call more than once (e.g. from both an explicit
    /// `stopWatchingProjects()` and a defensive `deinit`) — the `stream ==
    /// nil` guard makes every call after the first a no-op.
    func stop() {
        guard let stream else { return }
        self.stream = nil
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // Balances the `passRetained` in `init`. `passUnretained(self)`
        // here does NOT take a new retain — it just re-wraps the existing
        // pointer so `.release()` can hand back the one `init` took.
        Unmanaged.passUnretained(self).release()
    }

    deinit {
        // Reaching here with `stream != nil` means `stop()` was never
        // called — which should be unreachable, since `init`'s extra retain
        // keeps this instance alive until `stop()` releases it. Asserting
        // rather than silently leaking surfaces a caller-discipline bug
        // (a missing `stopWatchingProjects()` call) instead of hiding it as
        // a stream that quietly watches forever.
        assert(stream == nil, "ProjectsWatcher deallocated without calling stop()")
    }
}

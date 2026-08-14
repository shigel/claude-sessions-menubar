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
final class ProjectsWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    /// The queue `stream` is scheduled on (see `FSEventStreamSetDispatchQueue`
    /// in `init`). Apple's docs for `FSEventStreamInvalidate` require it to
    /// be called on the same run loop/dispatch queue the stream was
    /// scheduled on — `deinit` itself can run on any thread (here, the main
    /// thread, when a `@State ProjectsWatcher?` is torn down), so teardown
    /// is dispatched onto this queue rather than done inline. Without that,
    /// invalidation racing an in-flight callback on `queue` is a
    /// use-after-free: the callback holds an unretained `self` pointer.
    private let queue = DispatchQueue.global(qos: .utility)

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
        context.info = Unmanaged.passUnretained(self).toOpaque()

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
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        // Dispatched onto `queue`, not called inline — see the property's
        // doc comment. `stream` itself is a C pointer (not a class), so
        // capturing it by value here is safe even though `self` is already
        // being torn down.
        queue.async {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

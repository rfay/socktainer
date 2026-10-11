import Foundation

/// Runs best-effort startup work under a deadline that the work itself cannot
/// extend or ignore.
///
/// Startup housekeeping (DNS-sidecar adoption, orphaned-network reaping) calls
/// into Apple Container over XPC, and those calls can hang forever when the
/// runtime is wedged (apple/container#1884: per-container/network operations
/// hang indefinitely while reads keep working). Task cancellation can't
/// interrupt an await stuck inside an XPC continuation, so a plain
/// timeout-and-cancel race deadlocks with it. Instead the work runs in a
/// detached task and the caller resumes on whichever finishes first — the work
/// or the deadline. On timeout the stuck task is abandoned (it holds no
/// resources the daemon needs) so startup can proceed and bind the API socket;
/// the alternative is a daemon that never comes up at all. Healthcheck probes
/// make the same XPC calls and use the same deadline.
enum StartupHousekeeping {
    /// Runs `work`, returning `true` if it finished within `timeout` and
    /// `false` if it was abandoned at the deadline.
    static func runBounded(timeout: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await runBoundedResult(timeout: timeout, work) != nil
    }

    /// Runs `work`, returning its result if it finished within `timeout` and
    /// `nil` if it was abandoned at the deadline.
    static func runBoundedResult<T: Sendable>(timeout: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task.detached {
                let result = await work()
                if once.claim() { continuation.resume(returning: result) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }
}

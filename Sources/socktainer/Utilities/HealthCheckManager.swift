import ContainerAPIClient
import Foundation
import Logging
import Vapor

struct HealthCheckManagerKey: StorageKey {
    typealias Value = HealthCheckManager
}

/// A function that runs a healthcheck command inside a container and returns
/// its exit code. Injected so tests can stub the side-effecting exec path.
typealias HealthProbe = @Sendable (_ containerId: String, _ cmd: [String], _ timeoutNs: UInt64) async -> Int32

/// Runs Docker `HEALTHCHECK` probes inside containers and tracks their status.
///
/// Apple Container 1.0.0 has no native runtime healthcheck support, so we
/// implement it here: when a container is started, we periodically exec the
/// configured test command via `ContainerClient.createProcess` and record the
/// outcome. `GET /containers/{id}/json` reads from this manager to populate
/// `.State.Health`, which Docker clients (e.g. Supabase CLI, Compose
/// `depends_on: service_healthy`) gate on.
///
/// The probe config is persisted across `create → start` as a JSON-encoded
/// label (`socktainer.healthcheck`) on the container, so the manager can
/// rebuild the loop on each start without holding pre-start state itself.
actor HealthCheckManager {
    static let healthcheckLabel = "socktainer.healthcheck"

    // Docker's documented defaults when the field is absent from the request.
    // See https://docs.docker.com/reference/dockerfile/#healthcheck.
    static let defaultIntervalNs: UInt64 = 30 * 1_000_000_000
    static let defaultTimeoutNs: UInt64 = 30 * 1_000_000_000
    static let defaultRetries: Int = 3

    // Lower bounds applied to the user-supplied values. The interval floor is
    // overridable so tests can drive the loop at sub-second cadence; the
    // timeout floor stays fixed because there's no test scenario where we
    // want a sub-second timeout on a real exec.
    static let defaultMinimumIntervalNs: UInt64 = 1_000_000_000
    static let minimumTimeoutNs: UInt64 = 1_000_000_000

    private var statuses: [String: ContainerHealth] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var logs: [String: [HealthLogEntry]] = [:]  // ring buffer, max 5 entries per container
    private let log = Logger(label: "socktainer.healthcheck")
    private let probe: HealthProbe
    private let intervalFloorNs: UInt64
    /// Optional broadcaster for Docker `health_status` events. Nil in tests.
    private let broadcaster: EventBroadcaster?

    private static let maxLogEntries = 5

    private static func formatISO8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    init(probe: @escaping HealthProbe = HealthCheckManager.execProbe, intervalFloorNs: UInt64 = HealthCheckManager.defaultMinimumIntervalNs, broadcaster: EventBroadcaster? = nil) {
        self.probe = probe
        self.intervalFloorNs = intervalFloorNs
        self.broadcaster = broadcaster
    }

    func currentHealth(for id: String) -> ContainerHealth? {
        guard let status = statuses[id] else { return nil }
        return ContainerHealth(Status: status.Status, FailingStreak: status.FailingStreak, Log: logs[id] ?? [])
    }

    /// Start running healthchecks for a container. No-op if already running or if the
    /// test is disabled (`NONE`, empty, or bare `CMD` with no arguments).
    func start(containerId: String, config: HealthcheckConfig) {
        guard Self.parseTest(config.Test) != nil else { return }
        guard tasks[containerId] == nil else { return }
        statuses[containerId] = ContainerHealth(Status: "starting", FailingStreak: 0, Log: [])
        let task = Task { [self] in
            await self.runLoop(containerId: containerId, config: config)
        }
        tasks[containerId] = task
        log.info("[healthcheck] started for \(containerId)")
    }

    /// Stop the healthcheck loop for a container.
    func stop(containerId: String) {
        tasks.removeValue(forKey: containerId)?.cancel()
        statuses.removeValue(forKey: containerId)
        logs.removeValue(forKey: containerId)
    }

    /// Parses Docker's `Test` field into a runnable command vector.
    /// Returns nil for empty input or `["NONE"]` (the disable sentinel).
    static func parseTest(_ test: [String]?) -> [String]? {
        guard let test, !test.isEmpty else { return nil }
        switch test.first {
        case "NONE":
            return nil
        case "CMD-SHELL":
            return ["/bin/sh", "-c", test.dropFirst().joined(separator: " ")]
        case "CMD":
            let args = Array(test.dropFirst())
            return args.isEmpty ? nil : args
        default:
            return test
        }
    }

    // MARK: - Private

    private func updateStatus(id: String, health: ContainerHealth, logEntry: HealthLogEntry? = nil) {
        guard tasks[id] != nil else { return }  // already stopped
        let previous = statuses[id]?.Status
        statuses[id] = health
        if let entry = logEntry {
            var entries = logs[id] ?? []
            entries.append(entry)
            if entries.count > Self.maxLogEntries {
                entries.removeFirst(entries.count - Self.maxLogEntries)
            }
            logs[id] = entries
        }
        // Emit Docker health_status event on every transition (including starting → healthy).
        if previous != health.Status, let broadcaster {
            Task {
                let event = DockerEvent.simpleEvent(
                    id: id, type: "container",
                    status: "health_status: \(health.Status)"
                )
                await broadcaster.broadcast(event)
            }
        }
    }

    private func isActive(id: String) -> Bool {
        tasks[id] != nil
    }

    private func runLoop(containerId: String, config: HealthcheckConfig) async {
        // Intervals on the Docker API are nanoseconds.
        let startPeriodNs = UInt64(max(config.StartPeriod ?? 0, 0))
        let configIntervalNs = config.Interval.map { UInt64(max($0, 0)) } ?? Self.defaultIntervalNs
        let intervalNs = max(configIntervalNs, intervalFloorNs)
        let configTimeoutNs = config.Timeout.map { UInt64(max($0, 0)) } ?? Self.defaultTimeoutNs
        let timeoutNs = max(configTimeoutNs, Self.minimumTimeoutNs)
        let maxRetries = config.Retries ?? Self.defaultRetries

        // start_period suppresses *failures*, not probes: Docker probes from the
        // start and a success during the period marks the container healthy
        // immediately. Sleeping the period out instead delays the first probe past
        // it, which breaks any client whose readiness budget is the same value it
        // passed as start_period — DDEV sets both from default_container_timeout,
        // so health always landed a moment after DDEV had given up waiting.
        let startPeriodEnd = Date().addingTimeInterval(Double(startPeriodNs) / 1_000_000_000)

        var failingStreak = 0

        while !Task.isCancelled {
            guard isActive(id: containerId) else { return }

            let start = Date()
            let exitCode = await runCheck(containerId: containerId, config: config, timeoutNs: timeoutNs)
            let end = Date()

            guard !Task.isCancelled else { return }

            // A failure inside start_period is not yet a failure: leave the streak
            // alone and stay "starting" so retries aren't consumed by a container
            // that is simply still booting.
            if exitCode != 0 && end < startPeriodEnd {
                updateStatus(
                    id: containerId,
                    health: ContainerHealth(Status: "starting", FailingStreak: failingStreak, Log: []),
                    logEntry: HealthLogEntry(
                        Start: Self.formatISO8601(start),
                        End: Self.formatISO8601(end),
                        ExitCode: exitCode,
                        Output: ""
                    )
                )
                try? await Task.sleep(nanoseconds: intervalNs)
                continue
            }

            let entry = HealthLogEntry(
                Start: Self.formatISO8601(start),
                End: Self.formatISO8601(end),
                ExitCode: exitCode,
                Output: ""  // stdout capture from container VMs requires pipe infrastructure
            )

            if exitCode == 0 {
                failingStreak = 0
                updateStatus(id: containerId, health: ContainerHealth(Status: "healthy", FailingStreak: 0, Log: []), logEntry: entry)
            } else {
                failingStreak += 1
                // Once a container has reported healthy, a transient failure below the
                // retries threshold must not regress it to "starting" — Docker only ever
                // moves healthy -> unhealthy (after Retries consecutive failures) or stays
                // healthy. Only containers that never had a successful check fall back to
                // "starting" while below the threshold.
                let wasHealthy = statuses[containerId]?.Status == "healthy"
                let status: String
                if failingStreak >= maxRetries {
                    status = "unhealthy"
                } else if wasHealthy {
                    status = "healthy"
                } else {
                    status = "starting"
                }
                updateStatus(id: containerId, health: ContainerHealth(Status: status, FailingStreak: failingStreak, Log: []), logEntry: entry)
                log.debug("[healthcheck] \(containerId) → \(status) (streak=\(failingStreak), exit=\(exitCode))")
            }

            try? await Task.sleep(nanoseconds: intervalNs)
        }
    }

    private func runCheck(containerId: String, config: HealthcheckConfig, timeoutNs: UInt64) async -> Int32 {
        // nil means NONE / disabled / empty — do not mark the container healthy
        guard let cmd = Self.parseTest(config.Test) else { return 1 }
        // Bound the probe call ourselves rather than trusting it to self-enforce
        // `timeoutNs`. `execProbe` races `process.wait()` against a sleep, but that
        // race only covers the wait — the container lookup, `createProcess`, and
        // `start()` calls that happen *before* it are unbounded. Structured
        // concurrency (`withTaskGroup`) can't rescue that either: cancellation is
        // cooperative, so a `TaskGroup` still blocks its own return on a child task
        // that never checks `Task.isCancelled`. `Self.firstToFinish` sidesteps this
        // by racing via a continuation and abandoning (not awaiting) the loser, so
        // a probe that stalls anywhere in its lifecycle can never freeze this loop
        // — and therefore `.State.Health` — past `timeoutNs`. See #12: with a long
        // start_period/timeout, a stalled first probe left Status/Log frozen at
        // "starting"/empty forever.
        let probe = self.probe
        return await Self.firstToFinish(
            { await probe(containerId, cmd, timeoutNs) },
            orAfter: timeoutNs,
            fallback: 1
        )
    }

    /// Runs `operation`, returning its result — or `fallback` if it hasn't finished
    /// within `timeoutNs`. Unlike a `TaskGroup`-based race, this never blocks past
    /// `timeoutNs`: the loser is abandoned (left running unstructured in the
    /// background) rather than awaited, because Swift's structured-concurrency
    /// teardown would otherwise wait for it regardless of cancellation.
    private static func firstToFinish<T: Sendable>(
        _ operation: @escaping @Sendable () async -> T,
        orAfter timeoutNs: UInt64,
        fallback: @autoclosure @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let resumed = ResumeOnce()
            Task {
                let result = await operation()
                if resumed.tryFire() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                if resumed.tryFire() { continuation.resume(returning: fallback()) }
            }
        }
    }

    /// Guards a `CheckedContinuation` against being resumed twice when two
    /// unstructured tasks are racing to resume it.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func tryFire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !fired else { return false }
            fired = true
            return true
        }
    }

    // MARK: - Default probe (real exec)

    private enum ProbeOutcome {
        case exited(Int32)
        case timedOut
    }

    /// Runs `cmd` inside the container via `createProcess`, with a timeout race.
    /// Returns the exit code, or 1 on any failure.
    static let execProbe: HealthProbe = { containerId, cmd, timeoutNs in
        do {
            let containerClient = ContainerClient()
            guard let container = try? await containerClient.get(id: containerId) else { return 1 }

            var processConfig = container.configuration.initProcess
            processConfig.executable = cmd[0]
            processConfig.arguments = Array(cmd.dropFirst())
            processConfig.terminal = false
            // Run as the container's own user, which is what initProcess already carries.
            // Docker does the same, and probes are written for it: forcing root instead
            // leaves root-owned state behind that the container's user cannot touch. DDEV's
            // router healthcheck writes /tmp/healthy, then `rm -f /tmp/healthy` from a
            // normal exec fails with EPERM and takes `ddev restart` down with it.

            let processId = "hc-\(UUID().uuidString.lowercased())"
            let process = try await containerClient.createProcess(
                containerId: containerId,
                processId: processId,
                configuration: processConfig,
                stdio: [nil, nil, nil]
            )
            try await process.start()

            let outcome: ProbeOutcome = try await withThrowingTaskGroup(of: ProbeOutcome.self) { group in
                group.addTask { .exited(try await process.wait()) }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    return .timedOut
                }
                let result = try await group.next() ?? .timedOut
                group.cancelAll()
                return result
            }
            switch outcome {
            case .exited(let code):
                return code
            case .timedOut:
                try? await process.kill(SIGTERM)
                return 1
            }
        } catch {
            return 1
        }
    }
}

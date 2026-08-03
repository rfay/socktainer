import Foundation
import Testing

@testable import socktainer

@Suite("HealthCheckManager")
struct HealthCheckManagerTests {

    // MARK: - Test parsing (pure, no actor)

    @Test("CMD-SHELL wraps args in /bin/sh -c")
    func parseCmdShell() {
        #expect(HealthCheckManager.parseTest(["CMD-SHELL", "pg_isready -U postgres"]) == ["/bin/sh", "-c", "pg_isready -U postgres"])
    }

    @Test("CMD passes args through directly")
    func parseCmd() {
        #expect(HealthCheckManager.parseTest(["CMD", "pg_isready", "-U", "postgres"]) == ["pg_isready", "-U", "postgres"])
    }

    @Test("NONE disables the check")
    func parseNone() {
        #expect(HealthCheckManager.parseTest(["NONE"]) == nil)
    }

    @Test("Bare test (no CMD prefix) runs as-is")
    func parseBare() {
        #expect(HealthCheckManager.parseTest(["pg_isready"]) == ["pg_isready"])
    }

    @Test("Empty or nil test returns nil")
    func parseEmpty() {
        #expect(HealthCheckManager.parseTest(nil) == nil)
        #expect(HealthCheckManager.parseTest([]) == nil)
    }

    @Test("CMD with no following args returns nil (avoids exec of empty cmd)")
    func parseCmdWithoutArgs() {
        #expect(HealthCheckManager.parseTest(["CMD"]) == nil)
    }

    // MARK: - Lifecycle

    @Test("currentHealth is nil before start")
    func notRunningInitially() async {
        let mgr = HealthCheckManager()
        let h = await mgr.currentHealth(for: "c1")
        #expect(h == nil)
    }

    @Test("stop clears status")
    func stopClearsStatus() async {
        // Probe never returns within the test window — we just want a quick
        // start-then-stop to validate state is wiped.
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        #expect(await mgr.currentHealth(for: "c1") != nil)
        await mgr.stop(containerId: "c1")
        #expect(await mgr.currentHealth(for: "c1") == nil)
    }

    @Test("start is idempotent")
    func startIdempotent() async {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        let firstStatus = await mgr.currentHealth(for: "c1")
        await mgr.start(containerId: "c1", config: cfg)  // second call no-ops
        let secondStatus = await mgr.currentHealth(for: "c1")
        #expect(firstStatus?.Status == "starting")
        #expect(secondStatus?.Status == "starting")
        await mgr.stop(containerId: "c1")
    }

    // MARK: - State transitions

    @Test("First successful probe transitions to healthy")
    func healthyOnFirstSuccess() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect(h?.Status == "healthy")
        #expect(h?.FailingStreak == 0)
        await mgr.stop(containerId: "c1")
    }

    @Test("Persistent failures transition to unhealthy after Retries")
    func unhealthyAfterRetries() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 1 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "false"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 2, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("unhealthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect(h?.Status == "unhealthy")
        #expect((h?.FailingStreak ?? 0) >= 2)
        await mgr.stop(containerId: "c1")
    }

    // MARK: - Regression: status must not regress from healthy (issue #12)

    @Test("A single transient failure below Retries does not regress healthy to starting")
    func healthyDoesNotRegressToStartingOnTransientFailure() async throws {
        actor CallCounter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let counter = CallCounter()
        let mgr = HealthCheckManager(
            // Call 1 succeeds (-> healthy). Call 2 fails once (a transient blip,
            // well below Retries). Call 3+ stall so status stops changing while
            // the test inspects it right after the transient failure lands.
            probe: { _, _, _ in
                let n = await counter.next()
                if n == 1 { return 0 }
                if n == 2 { return 1 }
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 5_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")  // call #1
        try await Self.waitForFailingStreak(1, on: mgr, id: "c1")  // call #2 (the transient failure)
        let h = await mgr.currentHealth(for: "c1")
        // Before the fix, any failure below Retries unconditionally set "starting",
        // even for a container that had already reported healthy.
        #expect(h?.Status == "healthy")
        #expect(h?.FailingStreak == 1)
        await mgr.stop(containerId: "c1")
    }

    @Test("Repeated transient failures never below Retries keep status healthy, not starting")
    func healthyStaysHealthyAcrossManyTransientFailures() async throws {
        actor CallCounter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let counter = CallCounter()
        let mgr = HealthCheckManager(
            // Alternate success/failure forever. FailingStreak resets to 0 on every
            // success, so it can never reach Retries — status must stay "healthy".
            probe: { _, _, _ in
                let n = await counter.next()
                return n % 2 == 0 ? 1 : 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 2_000_000, Timeout: 1_000_000_000, Retries: 5, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        // Run through many probe cycles (well past the original 5-entry log ring
        // buffer) to confirm status remains stable over time, not just at the
        // moment of the first success.
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 3_000_000)
            let status = await mgr.currentHealth(for: "c1")?.Status
            #expect(status == "healthy" || status == nil)
        }
        await mgr.stop(containerId: "c1")
    }

    // MARK: - Regression: the loop must not freeze past Timeout (issue #12)

    @Test("Long start_period/timeout with a short interval still reaches healthy (repro ratio, scaled down)")
    func longStartPeriodShortIntervalStillReachesHealthy() async throws {
        // Mirrors the reported repro's ratio (interval=1s, timeout=70s,
        // start_period=120s) scaled down ~170x so the test runs in well under
        // a second while exercising the same relative magnitudes: interval
        // (small) << timeout < start_period.
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 6_000_000, Timeout: 400_000_000, Retries: 3, StartPeriod: 700_000_000)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect(h?.Status == "healthy")
        #expect((h?.Log.count ?? 0) > 0)
        await mgr.stop(containerId: "c1")
    }

    @Test("A probe that stalls indefinitely does not freeze the loop past its Timeout")
    func stalledProbeDoesNotFreezeLoop() async throws {
        let mgr = HealthCheckManager(
            // Simulates a probe whose underlying exec call never returns — e.g. a
            // stalled container lookup / createProcess / start, the part of a real
            // probe that isn't covered by its own internal wait()-only timeout
            // race. Without the manager bounding runCheck itself, the loop (and
            // therefore `.State.Health`) would freeze forever, exactly reproducing
            // "Status stays starting, Log stays empty indefinitely" from #12.
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 10_000_000, Timeout: 50_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)

        // Poll for up to ~1s (20x the 50ms Timeout) for a log entry to appear.
        // Pre-fix, runCheck blocks on the stalled probe forever and this loop
        // would exhaust its budget with an empty log every time.
        var logCount = 0
        for _ in 0..<200 {
            logCount = await mgr.currentHealth(for: "c1")?.Log.count ?? 0
            if logCount > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let h = await mgr.currentHealth(for: "c1")
        #expect(logCount > 0)
        #expect(h?.Status != "healthy")  // the probe never actually succeeded
        #expect((h?.FailingStreak ?? 0) > 0)
        await mgr.stop(containerId: "c1")
    }

    // MARK: - Health log entries

    @Test("Log entries are recorded after each probe")
    func logEntriesRecorded() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) > 0)
        #expect(h?.Log.first?.ExitCode == 0)
        #expect(h?.Log.first?.Start.isEmpty == false)
        await mgr.stop(containerId: "c1")
    }

    @Test("Log is capped at 5 entries")
    func logCappedAt5() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        // Wait long enough for >5 probe calls at 1ms interval
        try await Task.sleep(nanoseconds: 30_000_000)
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) <= 5)
        await mgr.stop(containerId: "c1")
    }

    // MARK: - health_status events

    @Test("health_status events are emitted on status transition to healthy")
    func healthStatusEventsEmitted() async throws {
        actor Collector {
            var statuses: [String] = []
            func append(_ s: String) { statuses.append(s) }
        }
        let collector = Collector()
        let broadcaster = EventBroadcaster()

        let collectTask = Task { @Sendable in
            for await event in await broadcaster.stream() {
                if event.status.hasPrefix("health_status:") {
                    await collector.append(event.status)
                }
                if await collector.statuses.count >= 1 { break }
            }
        }

        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000,
            broadcaster: broadcaster
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        try await Task.sleep(nanoseconds: 20_000_000)
        collectTask.cancel()
        await mgr.stop(containerId: "c1")

        let received = await collector.statuses
        #expect(received.contains("health_status: healthy"))
    }

    // MARK: - Log entry detail for failing probe

    @Test("Log entry records non-zero exit code on failure")
    func logEntryForFailingProbe() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 1 },  // always fail
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "false"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 1, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("unhealthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        #expect((h?.Log.count ?? 0) > 0)
        #expect(h?.Log.first?.ExitCode == 1)
        await mgr.stop(containerId: "c1")
    }

    @Test("Log entry Start and End are non-empty ISO8601 strings")
    func logEntryTimestampsAreISO8601() async throws {
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c1", config: cfg)
        try await Self.waitForStatus("healthy", on: mgr, id: "c1")
        let h = await mgr.currentHealth(for: "c1")
        guard let entry = h?.Log.first else {
            Issue.record("No log entries")
            return
        }
        // ISO8601 with fractional seconds: e.g. "2026-06-13T01:23:45.678Z"
        #expect(entry.Start.contains("T"))
        #expect(entry.Start.contains("Z"))
        #expect(entry.End.contains("T"))
        // End must be >= Start (both valid timestamps)
        let start = ISO8601DateFormatter().date(from: entry.Start)
        let end = ISO8601DateFormatter().date(from: entry.End)
        if let s = start, let e = end {
            #expect(e >= s)
        }
        await mgr.stop(containerId: "c1")
    }

    // MARK: - Helpers

    /// Polls every 5ms up to ~3s for the manager to report `expected` status.
    /// Fails the test if the status is never reached.
    private static func waitForStatus(_ expected: String, on mgr: HealthCheckManager, id: String) async throws {
        for _ in 0..<600 {
            if await mgr.currentHealth(for: id)?.Status == expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let actual = await mgr.currentHealth(for: id)?.Status
        Issue.record("waitForStatus timed out: expected '\(expected)' but got '\(actual ?? "nil")' for container '\(id)'")
        struct TimeoutError: Error {}
        throw TimeoutError()
    }

    /// Polls every 5ms up to ~3s for the manager to report `expected` FailingStreak.
    /// Fails the test if it's never reached.
    private static func waitForFailingStreak(_ expected: Int, on mgr: HealthCheckManager, id: String) async throws {
        for _ in 0..<600 {
            if await mgr.currentHealth(for: id)?.FailingStreak == expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let actual = await mgr.currentHealth(for: id)?.FailingStreak
        Issue.record("waitForFailingStreak timed out: expected \(expected) but got \(actual.map(String.init) ?? "nil") for container '\(id)'")
        struct TimeoutError: Error {}
        throw TimeoutError()
    }
}

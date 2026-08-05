import ContainerAPIClient
import ContainerizationArchive
import ContainerizationOS
import Foundation
import Testing

@testable import socktainer

/// Regression coverage for GitHub issue #11: `docker cp` of a directory (the
/// `/.` trailing-dot form the Docker CLI drives by streaming a tar of the
/// directory's contents straight to `PUT /containers/{id}/archive`) must
/// either succeed or fail promptly with a clear error -- it must never hang.
///
/// `putArchiveViaCopyIn`'s guest exec talks to the real `ContainerClient` XPC
/// service, so it can't be exercised here without a running container.
/// Instead this suite covers the two independently-testable layers that make
/// up that path:
///   1. `ArchiveUtility.extract`, which unpacks the uploaded tar stream (used
///      to stage file contents before they're copied into the guest) -- the
///      file explicitly called out as the likely bug location.
///   2. `ClientArchiveService.waitForGuestPreparation`, the new bound on the
///      guest-side validation/preparation exec that previously waited on
///      `process.wait()` with no timeout at all.
@Suite("ClientArchiveService directory copy (issue #11)")
struct ClientArchiveServiceCopyDirectoryTests {

    @Test("a tar stream with a directory and nested file extracts the full tree, not just a single file")
    func extractsDirectoryTreeWithoutHanging() async throws {
        let fixture = try DirectoryTarFixture()
        defer { fixture.cleanUp() }

        // Mirrors the issue's repro: mkdir -p /tmp/cpdirtest/sub && echo hi > .../file.txt
        try fixture.writeSource(relativePath: "sub/file.txt", contents: "hi\n")
        try ArchiveUtility.create(tarPath: fixture.tarPath, from: fixture.sourceDir)

        // If a regression reintroduces the old "assume one regular file entry"
        // behavior, extraction should fail fast or silently drop the nested
        // file -- not hang. Bound the call so the test fails instead of
        // blocking CI forever if a hang regresses.
        try await withTestTimeout(seconds: 10) {
            try ArchiveUtility.extract(tarPath: fixture.tarPath, to: fixture.destDir)
        }

        let extractedDir = fixture.destDir.appendingPathComponent("sub")
        var isDirectory: ObjCBool = false
        let dirExists = FileManager.default.fileExists(atPath: extractedDir.path, isDirectory: &isDirectory)
        #expect(dirExists, "extracted tree must contain the 'sub' directory")
        #expect(isDirectory.boolValue, "'sub' must be extracted as a directory, not a file")

        let extractedFile = extractedDir.appendingPathComponent("file.txt")
        let contents = try #require(
            String(data: try Data(contentsOf: extractedFile), encoding: .utf8),
            "nested file must be extracted with its content intact")
        #expect(contents == "hi\n")
    }

    @Test("waitForGuestPreparation returns promptly for a guest exec that exits normally")
    func returnsExitCodeForFastProcess() async throws {
        let process = ScriptedProcess(waitBehavior: .exits(code: 0))
        let code = try await withTestTimeout(seconds: 5) {
            try await ClientArchiveService.waitForGuestPreparation(process: process, timeoutNs: 5_000_000_000)
        }
        #expect(code == 0)
    }

    @Test("waitForGuestPreparation times out instead of hanging forever when the guest exec never returns")
    func timesOutRatherThanHanging() async throws {
        let process = ScriptedProcess(waitBehavior: .hangsForever)

        // This is the core regression check: previously `process.wait()` was
        // awaited with no timeout at all, so a wedged guest exec (which is
        // exactly what a directory copy's non-trivial mkdir/ln script risks
        // hitting) would hang the PUT /containers/{id}/archive request
        // forever. The outer withTestTimeout is a safety net so that if the
        // internal timeout regresses, this test fails after 5s instead of
        // hanging the whole suite.
        await #expect(throws: ClientArchiveError.self) {
            try await withTestTimeout(seconds: 5) {
                try await ClientArchiveService.waitForGuestPreparation(process: process, timeoutNs: 200_000_000)
            }
        }

        let killed = await process.wasKilled()
        #expect(killed, "a wedged guest exec must be sent SIGTERM when we give up waiting on it")
    }
}

// MARK: - Fixtures

private struct DirectoryTarFixture {
    let root: URL
    let sourceDir: URL
    let destDir: URL
    let tarPath: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-dir-test-\(UUID().uuidString)")
        sourceDir = root.appendingPathComponent("source")
        destDir = root.appendingPathComponent("dest")
        tarPath = root.appendingPathComponent("archive.tar")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    func writeSource(relativePath: String, contents: String) throws {
        let fileURL = sourceDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// A `ClientProcess` double that lets tests script `wait()`'s behavior
/// without a real container/XPC connection.
private final class ScriptedProcess: ClientProcess, Sendable {
    enum WaitBehavior {
        case exits(code: Int32)
        case hangsForever
    }

    let id = "scripted-guest-prep-process"
    private let waitBehavior: WaitBehavior
    private let killedFlag = KilledFlag()

    init(waitBehavior: WaitBehavior) {
        self.waitBehavior = waitBehavior
    }

    func start() async throws {}
    func resize(_ size: ContainerizationOS.Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        await killedFlag.set()
    }

    func wait() async throws -> Int32 {
        switch waitBehavior {
        case .exits(let code):
            return code
        case .hangsForever:
            // Stands in for a wedged guest exec: suspends until cancelled by
            // the timeout race in waitForGuestPreparation, never resolving on
            // its own.
            try await Task.sleep(nanoseconds: .max)
            return 0
        }
    }

    func wasKilled() async -> Bool {
        await killedFlag.get()
    }
}

private actor KilledFlag {
    private var killed = false
    func set() { killed = true }
    func get() -> Bool { killed }
}

// MARK: - Timeout helper

private struct TestTimeoutError: Error {}

/// Races `operation` against `seconds`, throwing `TestTimeoutError` if it
/// doesn't finish in time. Used so a hang regression fails the test quickly
/// instead of blocking the suite indefinitely.
private func withTestTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

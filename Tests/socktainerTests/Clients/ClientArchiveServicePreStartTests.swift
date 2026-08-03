import ContainerAPIClient
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import socktainer

/// Reproduces issue #10: `PUT`/`GET /containers/{id}/archive` 404ing with
/// "Rootfs not found" for a container that was `docker create`d but never
/// started. Apple's Containerization runtime only clones a container's
/// writable `rootfs.ext4` from its image snapshot on first bootstrap, so a
/// freshly created container's bundle directory holds only
/// `runtime-configuration.json` — no `rootfs.ext4` — until it is started at
/// least once. `ClientArchiveService.ensureRootfsMaterialized` closes that
/// gap by replicating the same local, VM-free bundle materialization that
/// Apple's runtime performs at bootstrap time, using only the pending
/// `runtime-configuration.json`.
@Suite("ClientArchiveService pre-start rootfs materialization")
struct ClientArchiveServicePreStartTests {

    @Test("GET archive succeeds on a created-but-never-started container")
    func getArchiveMaterializesRootfs() async throws {
        let fixture = try PreStartFixture(containerId: "web", imageFiles: ["/hello.txt": "hi from image\n"])
        defer { fixture.cleanUp() }

        let (tarData, stat) = try await fixture.service.getArchive(containerId: "web", path: "/hello.txt")
        #expect(stat.name == "hello.txt")
        #expect(!tarData.isEmpty)

        // Materialization must have produced a real, standalone rootfs.ext4 —
        // not merely served from the read-only image snapshot.
        let rootfsPath = fixture.service.getRootfsPath(containerId: "web")
        #expect(FileManager.default.fileExists(atPath: rootfsPath.path))
        #expect(rootfsPath.path != fixture.imageSnapshotPath.path)
    }

    @Test("PUT archive succeeds on a created-but-never-started container")
    func putArchiveMaterializesRootfs() async throws {
        let fixture = try PreStartFixture(containerId: "web", imageFiles: ["/existing.txt": "from image\n"])
        defer { fixture.cleanUp() }

        let tarPath = try fixture.makeTar(entryName: "onefile.txt", contents: "hi\n")
        defer { try? FileManager.default.removeItem(at: tarPath) }

        let snapshot = try fixture.snapshot()
        try await fixture.service.putArchive(container: snapshot, path: "/", tarPath: tarPath, noOverwriteDirNonDir: false)

        let (tarData, stat) = try await fixture.service.getArchive(containerId: "web", path: "/onefile.txt")
        #expect(stat.name == "onefile.txt")
        let extracted = fixture.appSupport.appendingPathComponent("extracted")
        try Data(tarData).write(to: fixture.appSupport.appendingPathComponent("readback.tar"))
        try ArchiveUtility.extract(tarPath: fixture.appSupport.appendingPathComponent("readback.tar"), to: extracted)
        let written = try #require(firstFile(named: "onefile.txt", under: extracted))
        #expect(try String(contentsOf: written, encoding: .utf8) == "hi\n")
    }

    @Test("a genuinely nonexistent container still 404s as rootfsNotFound")
    func missingContainerStillNotFound() async throws {
        let fixture = try PreStartFixture(containerId: "web", imageFiles: [:])
        defer { fixture.cleanUp() }

        do {
            _ = try await fixture.service.getArchive(containerId: "ghost", path: "/")
            Issue.record("archive access to a nonexistent container must throw")
        } catch let error as ClientArchiveError {
            guard case .rootfsNotFound(let id) = error else {
                Issue.record("expected rootfsNotFound, got \(error)")
                return
            }
            #expect(id == "ghost")
        }
    }

    @Test("materialization is idempotent — a second call is a no-op once the rootfs exists")
    func idempotentMaterialization() async throws {
        let fixture = try PreStartFixture(containerId: "web", imageFiles: ["/hello.txt": "hi\n"])
        defer { fixture.cleanUp() }

        try fixture.service.ensureRootfsMaterialized(containerId: "web")
        let rootfsPath = fixture.service.getRootfsPath(containerId: "web")
        let firstModified = try FileManager.default.attributesOfItem(atPath: rootfsPath.path)[.modificationDate] as? Date

        // Calling it again must be a cheap existence-check fast path: it must
        // not attempt to re-clone (which would fail with "file already exists").
        try fixture.service.ensureRootfsMaterialized(containerId: "web")
        let secondModified = try FileManager.default.attributesOfItem(atPath: rootfsPath.path)[.modificationDate] as? Date
        #expect(firstModified == secondModified)
    }
}

/// Builds a container bundle directory that only has `runtime-configuration.json`
/// on disk — the on-disk state of a container immediately after `docker create`,
/// before Apple's runtime has ever bootstrapped it.
private struct PreStartFixture {
    let appSupport: URL
    let service: ClientArchiveService
    let containerId: String
    let imageSnapshotPath: URL

    init(containerId: String, imageFiles: [String: String]) throws {
        self.containerId = containerId
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("prestart-archive-\(UUID().uuidString)")
        service = ClientArchiveService(appSupportPath: appSupport)

        let containerDir = appSupport.appendingPathComponent("containers").appendingPathComponent(containerId)
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)

        // Stand-in for the pulled image's read-only rootfs snapshot, which
        // (unlike the per-container rootfs.ext4) already exists at `create` time.
        imageSnapshotPath = appSupport.appendingPathComponent("image-snapshot.ext4")
        let formatter = try EXT4.Formatter(FilePath(imageSnapshotPath.path))
        for (path, contents) in imageFiles {
            let stream = InputStream(data: Data(contents.utf8))
            stream.open()
            try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream, recursion: true)
        }
        try formatter.close()

        // Bundle.create only copies these files byte-for-byte; their content
        // is irrelevant to rootfs materialization.
        let kernelBinary = appSupport.appendingPathComponent("kernel.bin")
        try Data("stand-in kernel".utf8).write(to: kernelBinary)
        let initfs = appSupport.appendingPathComponent("initfs.ext4")
        try Data("stand-in initfs".utf8).write(to: initfs)

        let proc = ProcessConfiguration(
            executable: "/bin/sleep", arguments: ["300"], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
        let configuration = ContainerConfiguration(id: containerId, image: img, process: proc)

        let runtimeConfig = RuntimeConfiguration(
            path: containerDir,
            initialFilesystem: .block(format: "ext4", source: initfs.path, destination: "/", options: ["ro"]),
            kernel: Kernel(path: kernelBinary, platform: .linuxArm),
            containerConfiguration: configuration,
            containerRootFilesystem: .block(format: "ext4", source: imageSnapshotPath.path, destination: "/", options: []),
            options: ContainerCreateOptions(autoRemove: false)
        )
        try runtimeConfig.writeRuntimeConfiguration()
    }

    /// A `ContainerSnapshot` matching what `ClientContainerService.getContainer`
    /// would report for this container before its first start: `.stopped`.
    func snapshot() throws -> ContainerSnapshot {
        let config = try RuntimeConfiguration.readRuntimeConfiguration(from: appSupport.appendingPathComponent("containers").appendingPathComponent(containerId))
        let containerConfiguration = try #require(config.containerConfiguration)
        return ContainerSnapshot(configuration: containerConfiguration, status: .stopped, networks: [])
    }

    func makeTar(entryName: String, contents: String) throws -> URL {
        let stagingDir = appSupport.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: stagingDir.appendingPathComponent(entryName))
        let tarPath = appSupport.appendingPathComponent("upload-\(UUID().uuidString).tar")
        try ArchiveUtility.create(tarPath: tarPath, from: stagingDir)
        return tarPath
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }
}

private func firstFile(named name: String, under directory: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return nil
    }
    return enumerator.compactMap { $0 as? URL }.first { $0.lastPathComponent == name }
}

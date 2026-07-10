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

/// Regression tests for archive operations on a created-but-never-started container.
///
/// Apple Container materializes a container's private `rootfs.ext4` lazily — in
/// `RuntimeService.bootstrap` on first start — while Docker materializes the
/// writable layer at create time. Clients rely on Docker's behavior: buildx's
/// docker-container driver seeds its builder with `create` + `PUT /archive`
/// (certs/config into `/etc`) before ever starting it, which used to 404 with
/// "Rootfs not found". The fix creates the bundle from the runtime configuration
/// written at create time, exactly as bootstrap would; bootstrap skips bundle
/// creation when one already exists, so the injected files survive the start.
final class ClientArchiveServiceMaterializeTests {
    let appSupport: URL
    let containerId = "created-not-started"

    init() throws {
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("archive-materialize-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: appSupport.appendingPathComponent("containers").appendingPathComponent(containerId),
            withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: appSupport)
    }

    private var containerDir: URL {
        appSupport.appendingPathComponent("containers").appendingPathComponent(containerId)
    }

    private var rootfsPath: URL {
        containerDir.appendingPathComponent("rootfs.ext4")
    }

    /// A small valid ext4 image, optionally with `/etc/hostname` inside — standing
    /// in for the per-image shared snapshot that `create` prepares. The dangling
    /// `/etc/mtab → /proc/mounts` symlink mirrors real images (alpine ships it);
    /// it resolves to nothing while the container isn't running, and archiving
    /// `/etc` must archive the link itself rather than fail following it.
    private func makeExt4(name: String, withEtc: Bool) throws -> URL {
        let path = appSupport.appendingPathComponent(name)
        let formatter = try EXT4.Formatter(FilePath(path.path), blockSize: 4096, minDiskSize: 16 * 1024 * 1024)
        if withEtc {
            try formatter.create(path: FilePath("/etc"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/etc/hostname"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: nil)
            try formatter.create(path: FilePath("/etc/mtab"), link: FilePath("/proc/mounts"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        }
        try formatter.close()
        return path
    }

    /// Write the `runtime-configuration.json` that Apple Container's
    /// `ContainersService.create` leaves in the container directory — the only
    /// on-disk state a created-but-never-started container has.
    private func writeRuntimeConfiguration() throws {
        let kernelBin = appSupport.appendingPathComponent("kernel.bin")
        try Data("not a real kernel".utf8).write(to: kernelBin)
        let initfs = try makeExt4(name: "initfs-source.ext4", withEtc: false)
        let imageSnapshot = try makeExt4(name: "image-snapshot.ext4", withEtc: true)

        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))

        let runtimeConfig = RuntimeConfiguration(
            path: containerDir,
            initialFilesystem: .block(format: "ext4", source: initfs.path, destination: "/", options: ["ro"]),
            kernel: Kernel(path: kernelBin, platform: .linuxArm),
            containerConfiguration: ContainerConfiguration(id: containerId, image: img, process: proc),
            containerRootFilesystem: .block(format: "ext4", source: imageSnapshot.path, destination: "/", options: [])
        )
        try runtimeConfig.writeRuntimeConfiguration()
    }

    @Test("materializeRootfsIfNeeded clones the rootfs from the runtime configuration")
    func materializesFromRuntimeConfiguration() throws {
        try writeRuntimeConfiguration()
        let service = ClientArchiveService(appSupportPath: appSupport)

        try service.materializeRootfsIfNeeded(containerId: containerId)

        #expect(FileManager.default.fileExists(atPath: rootfsPath.path))
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        #expect(reader.exists(FilePath("/etc/hostname")))
    }

    @Test("materializeRootfsIfNeeded never touches an existing rootfs")
    func leavesExistingRootfsAlone() throws {
        // No runtime configuration on disk at all — the existence check must
        // short-circuit before it is ever needed.
        let sentinel = Data("existing rootfs bytes".utf8)
        try sentinel.write(to: rootfsPath)
        let service = ClientArchiveService(appSupportPath: appSupport)

        try service.materializeRootfsIfNeeded(containerId: containerId)

        #expect(try Data(contentsOf: rootfsPath) == sentinel)
    }

    @Test("getArchive works on a created-but-never-started container, dangling symlinks included")
    func getArchiveMaterializes() async throws {
        try writeRuntimeConfiguration()
        let service = ClientArchiveService(appSupportPath: appSupport)

        // Without the materialization fix this threw ClientArchiveError.rootfsNotFound;
        // and before extraction stopped following symlinks, the dangling /etc/mtab
        // aborted the archive with "no such file or directory: mounts".
        let (tarData, stat) = try await service.getArchive(containerId: containerId, path: "/etc")

        #expect(stat.name == "etc")
        #expect(!tarData.isEmpty)
        // Go os.FileMode encoding: ModeDir is bit 31, not POSIX S_IFDIR — the
        // Docker CLI reads raw 0x4000 as "regular file" and then refuses to
        // copy a file into the directory.
        #expect(stat.mode == (UInt32(1) << 31) | 0o755)
    }

    @Test("stat modes use Go's os.FileMode encoding, not raw POSIX")
    func statModeIsGoEncoded() {
        #expect(ClientArchiveService.goFileMode(fromExt4Mode: 0x41ED) == (UInt32(1) << 31) | 0o755)  // drwxr-xr-x
        #expect(ClientArchiveService.goFileMode(fromExt4Mode: 0x81A4) == 0o644)  // -rw-r--r--
        #expect(ClientArchiveService.goFileMode(fromExt4Mode: 0xA1FF) == (UInt32(1) << 27) | 0o777)  // symlink
        #expect(ClientArchiveService.goFileMode(fromExt4Mode: 0x89ED) == (UInt32(1) << 23) | 0o755)  // setuid executable
    }

    @Test("putArchive injects into a created-but-never-started container — the buildx create+PUT flow")
    func putArchiveMaterializes() async throws {
        try writeRuntimeConfiguration()
        let service = ClientArchiveService(appSupportPath: appSupport)

        // A tar with one file, as buildx does when seeding /etc of its builder.
        let staging = appSupport.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("injected".utf8).write(to: staging.appendingPathComponent("injected.txt"))
        let tarPath = appSupport.appendingPathComponent("payload.tar")
        try ArchiveUtility.create(tarPath: tarPath, from: staging)

        let container = try makeContainerSnapshot(nativeId: containerId, networks: [], labels: [:], status: .stopped)
        try await service.putArchive(container: container, path: "/etc", tarPath: tarPath, noOverwriteDirNonDir: true)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        #expect(reader.exists(FilePath("/etc/injected.txt")))
        // The pre-existing image content survives alongside the injected file.
        #expect(reader.exists(FilePath("/etc/hostname")))
    }

    @Test("a container with neither rootfs nor runtime configuration still 404s")
    func missingEverythingStillReportsRootfsNotFound() async throws {
        let service = ClientArchiveService(appSupportPath: appSupport)

        await #expect(throws: ClientArchiveError.self) {
            _ = try await service.getArchive(containerId: self.containerId, path: "/etc")
        }
    }
}

import Vapor

struct VersionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/version", use: VersionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        do {
            let version = VersionInfo(
                Platform: ServerPlatform(Name: "socktainer"),
                // NOTE: For the time being, we will report socktainer's version as a component
                //       https://github.com/socktainer/socktainer/pull/28#issuecomment-3318209340
                Components: [Component(Name: "socktainer", Version: getBuildVersion())],
                // NOTE: `Version` is the engine/product version, distinct from `ApiVersion`.
                //       Reporting the Docker Engine API version here (e.g. "v1.51") instead of
                //       socktainer's own product version confused clients that version-gate on
                //       the engine version (e.g. update nags), since 1.51 sorts far below any
                //       real minimum-engine-version threshold. https://github.com/rfay/socktainer/issues/13
                Version: getBuildVersion(),
                ApiVersion: Self.stripVPrefix(getDockerEngineApiMaxVersion()),
                MinAPIVersion: Self.stripVPrefix(getDockerEngineApiMinVersion()),
                GitCommit: getBuildGitCommit(),
                Os: "macOS",
                Arch: "arm64",
                KernelVersion: getKernel(),
                Experimental: true,
                BuildTime: getBuildTime(),
            )
            return try await version.encodeResponse(for: req)
        } catch {
            let response = Response(status: .internalServerError)
            response.headers.add(name: .contentType, value: "application/json")
            response.body = .init(string: "{\"message\": \"Failed to generate version information\"}\n")
            return response
        }
    }

    // getDockerEngineApiM{in,ax}Version() return a "v"-prefixed label (e.g. "v1.51") meant
    // for human-readable build info (see BuildInfoApiVersionTests, the `make version` target).
    // Real Docker's own ApiVersion/MinAPIVersion wire fields are always bare digits (e.g.
    // "1.51"); clients that parse them as a dotted version number treat a leading "v" as
    // unparseable and silently sort it below any real minimum. Confirmed against DDEV's own
    // check: moby's versions.GreaterThanOrEqualTo("v1.51", "1.44") is false, but
    // GreaterThanOrEqualTo("1.51", "1.44") is true.
    private static func stripVPrefix(_ s: String) -> String {
        s.hasPrefix("v") ? String(s.dropFirst()) : s
    }
}

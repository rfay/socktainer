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
                ApiVersion: getDockerEngineApiMaxVersion(),
                MinAPIVersion: getDockerEngineApiMinVersion(),
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
}

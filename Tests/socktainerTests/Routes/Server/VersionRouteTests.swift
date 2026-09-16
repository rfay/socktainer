import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct VersionResponseBody: Decodable {
    struct Component: Decodable {
        let Name: String
        let Version: String
    }
    let Components: [Component]
    let Version: String
    let ApiVersion: String
    let MinAPIVersion: String
}

@Suite("VersionRoute GET /version")
struct VersionRouteTests {

    private func withRoute(_ test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: VersionRoute())
            try await test(app)
        }
    }

    @Test("Server.Version reports socktainer's build version, not the Docker API version")
    func serverVersionReportsBuildVersionNotApiVersion() async throws {
        try await withRoute { app in
            try await app.testing().test(.GET, "/version") { res async throws in
                #expect(res.status == .ok)
                let body = try? JSONDecoder().decode(VersionResponseBody.self, from: res.body)
                let unwrapped = try #require(body)
                #expect(unwrapped.Version == getBuildVersion())
                #expect(unwrapped.Version != getDockerEngineApiMaxVersion())
            }
        }
    }

    @Test("socktainer Components entry reports the build version")
    func componentsReportBuildVersion() async throws {
        try await withRoute { app in
            try await app.testing().test(.GET, "/version") { res async throws in
                let body = try? JSONDecoder().decode(VersionResponseBody.self, from: res.body)
                let unwrapped = try #require(body)
                let socktainerComponent = unwrapped.Components.first { $0.Name == "socktainer" }
                let component = try #require(socktainerComponent)
                #expect(component.Version == getBuildVersion())
                #expect(component.Version != getDockerEngineApiMaxVersion())
            }
        }
    }

    @Test("ApiVersion and MinAPIVersion still report the Docker Engine API version")
    func apiVersionFieldsReportEngineApiVersion() async throws {
        try await withRoute { app in
            try await app.testing().test(.GET, "/version") { res async throws in
                let body = try? JSONDecoder().decode(VersionResponseBody.self, from: res.body)
                let unwrapped = try #require(body)
                #expect(unwrapped.ApiVersion == getDockerEngineApiMaxVersion().dropFirst())
                #expect(unwrapped.MinAPIVersion == getDockerEngineApiMinVersion().dropFirst())
            }
        }
    }

    @Test("ApiVersion and MinAPIVersion are bare digits, not \"v\"-prefixed")
    func apiVersionFieldsHaveNoVPrefix() async throws {
        try await withRoute { app in
            try await app.testing().test(.GET, "/version") { res async throws in
                let body = try? JSONDecoder().decode(VersionResponseBody.self, from: res.body)
                let unwrapped = try #require(body)
                #expect(!unwrapped.ApiVersion.hasPrefix("v"))
                #expect(!unwrapped.MinAPIVersion.hasPrefix("v"))
            }
        }
    }
}

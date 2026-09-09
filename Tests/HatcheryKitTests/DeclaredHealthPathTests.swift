import Foundation
import Testing

@testable import HatcheryKit

/// A manifest directory on disk, because the registry the declaration reads lives beside the manifest.
private struct RegistryWorld {
    let directory: URL
    let manifestPath: String

    init() throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hatchery-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.manifestPath = self.directory.appendingPathComponent("hatchery.json").path
    }

    /// Writes one kind file into the registry, in the form the estate's own files take.
    func declareKind(_ kind: String, healthcheck: String) throws {
        let kinds = self.directory.appendingPathComponent("kinds")
        try FileManager.default.createDirectory(at: kinds, withIntermediateDirectories: true)
        let body = """
            {
              "kind": "\(kind)",
              "summary": "A kind declared for this test.",
              "image": "\(kind)",
              "port": 80,
              "healthcheck": "\(healthcheck)"
            }
            """
        try Data(body.utf8).write(to: kinds.appendingPathComponent("\(kind).json"))
    }

    /// The estate's shape: one dokku app whose manifest entry names no path of its own.
    func manifest(healthPath: String? = nil) -> StackManifest {
        let app = ServiceSpec(
            name: "status",
            kind: ServiceKind(rawValue: "status"),
            image: "dokku/status:latest",
            domains: ["status.opi", "status.jimmyhoughjr.net"],
            configFile: "status.config.json",
            healthPath: healthPath)
        let estate = StackSpec(
            name: "estate",
            backend: .dokku,
            environment: .dev,
            host: "dokku@192.168.0.103",
            services: [app])
        return StackManifest(version: 1, stacks: [estate])
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.directory)
    }
}

/// The one service every case reads, so a case asserts on the path and nothing else.
private func statusService(_ world: RegistryWorld, healthPath: String? = nil) throws -> Declaration.Service {
    let document = Declaration(manifests: [(manifest: world.manifest(healthPath: healthPath), path: world.manifestPath)])
    let stack = try #require(document.stacks.first)
    return try #require(stack.services.first)
}

@Suite("The health path the declaration publishes")
struct DeclaredHealthPathTests {
    @Test("the kind file answers for a service that names no path of its own")
    func theKindFileAnswers() throws {
        let world = try RegistryWorld()
        defer { world.remove() }
        try world.declareKind("status", healthcheck: "/")

        // The estate's apps were adopted before the registry existed, so the kind file is the only place this path is written.
        #expect(try statusService(world).healthPath == "/")
    }

    @Test("the service's own path wins over the kind file")
    func theServiceWins() throws {
        let world = try RegistryWorld()
        defer { world.remove() }
        try world.declareKind("status", healthcheck: "/")

        #expect(try statusService(world, healthPath: "/ready").healthPath == "/ready")
    }

    @Test("a kind with no file publishes no path, because the built-in guess is not a declaration")
    func noFilePublishesNothing() throws {
        let world = try RegistryWorld()
        defer { world.remove() }

        // `/health` is what hatchery guesses for an unknown kind, and the status board does not answer there.
        #expect(try statusService(world).healthPath == nil)
    }
}

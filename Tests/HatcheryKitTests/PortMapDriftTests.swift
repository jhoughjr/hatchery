import Foundation
import Testing

@testable import HatcheryKit

/// A manifest directory holding one dokku app, because the audit reads the kind registry beside the manifest.
private struct PortMapWorld {
    let directory: URL
    let manifestPath: String
    let manifest: StackManifest

    init(backend: Backend = .dokku) throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hatchery-portmap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.manifestPath = self.directory.appendingPathComponent("hatchery.json").path

        let app = ServiceSpec(
            name: "rookery",
            kind: ServiceKind(rawValue: "rookery"),
            image: "dokku/rookery:latest",
            domains: ["rookery.jimmyhoughjr.net"],
            configFile: "rookery.config.json")
        let estate = StackSpec(
            name: "estate",
            backend: backend,
            environment: .dev,
            host: backend == .dokku ? "dokku@192.168.0.103" : "jimmy@192.168.0.103",
            services: [app])
        self.manifest = StackManifest(version: 1, stacks: [estate])
    }

    /// Writes rookery's kind file, with or without the map it claims.
    func declareKind(portMap: [String]?) throws {
        let kinds = self.directory.appendingPathComponent("kinds")
        try FileManager.default.createDirectory(at: kinds, withIntermediateDirectories: true)
        let map = portMap.map { ",\n  \"portMap\": [\($0.map { "\"\($0)\"" }.joined(separator: ", "))]" } ?? ""
        let body = """
            {
              "kind": "rookery",
              "summary": "A kind declared for this test.",
              "image": "rookery",
              "port": 5000\(map)
            }
            """
        try Data(body.utf8).write(to: kinds.appendingPathComponent("rookery.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.directory)
    }
}

/// The audit, with the box answering `held` when it is asked for a map, and a record of what it was asked.
private func audit(held: String, asked: Asked) -> DeclarationAudit {
    DeclarationAudit(
        reader: LiveConfigReader(run: { argv in
            if argv.last == "--ports-map" {
                await asked.record()
                return Data(held.utf8)
            }
            return Data("{}".utf8)
        }))
}

/// Counts the reads of the map, so a case can say the box was never asked.
private actor Asked {
    private(set) var count = 0
    func record() { self.count += 1 }
}

private func findings(_ world: PortMapWorld, _ audit: DeclarationAudit) async -> [Declaration.Finding] {
    let all = await audit.findings(for: [(manifest: world.manifest, path: world.manifestPath)])
    return all["estate/rookery"] ?? []
}

@Suite("The proxy map the box holds against the map the kind file declares")
struct PortMapDriftTests {
    @Test("a box that moved off the declared map is a finding naming both")
    func driftIsNamed() async throws {
        let world = try PortMapWorld()
        defer { world.remove() }
        try world.declareKind(portMap: ["http:80:5000"])

        // What a deploy from an image installs when it re-detects the map from EXPOSE.
        let found = await findings(world, audit(held: "http:5000:5000\n", asked: Asked()))

        let drift = try #require(found.first { $0.code == FindingCode.portMapDrift })
        #expect(drift.text.contains("http:5000:5000"))
        #expect(drift.text.contains("http:80:5000"))
    }

    @Test("a box still on the declared map says nothing")
    func agreementIsQuiet() async throws {
        let world = try PortMapWorld()
        defer { world.remove() }
        try world.declareKind(portMap: ["http:80:5000"])

        let found = await findings(world, audit(held: "http:80:5000\n", asked: Asked()))

        #expect(found.filter { $0.code == FindingCode.portMapDrift }.isEmpty)
    }

    @Test("an app whose vhost is gone from the map is named as holding nothing")
    func anEmptyMapIsNamed() async throws {
        let world = try PortMapWorld()
        defer { world.remove() }
        try world.declareKind(portMap: ["http:80:5000"])

        let found = await findings(world, audit(held: "\n", asked: Asked()))

        let drift = try #require(found.first { $0.code == FindingCode.portMapDrift })
        #expect(drift.text.contains("the box maps nothing"))
    }

    @Test("a kind that claims no map is never asked for one")
    func noClaimIsNeverAsked() async throws {
        let world = try PortMapWorld()
        defer { world.remove() }
        try world.declareKind(portMap: nil)
        let asked = Asked()

        let found = await findings(world, audit(held: "http:5000:5000\n", asked: asked))

        #expect(found.filter { $0.code == FindingCode.portMapDrift }.isEmpty)
        #expect(await asked.count == 0)
    }

    @Test("a stack that is not dokku owns its own routing, so no map is read")
    func onlyDokkuIsAsked() async throws {
        let world = try PortMapWorld(backend: .host)
        defer { world.remove() }
        try world.declareKind(portMap: ["http:80:5000"])
        let asked = Asked()

        let found = await findings(world, audit(held: "http:5000:5000\n", asked: asked))

        #expect(found.filter { $0.code == FindingCode.portMapDrift }.isEmpty)
        #expect(await asked.count == 0)
    }
}

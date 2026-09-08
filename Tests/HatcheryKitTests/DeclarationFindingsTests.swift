import Foundation
import Testing

@testable import HatcheryKit

/// A manifest directory on disk, because the audit reads the sidecars beside the manifest.
private struct AuditWorld {
    let directory: URL
    let manifestPath: String
    let manifest: StackManifest

    init() throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hatchery-findings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.manifestPath = self.directory.appendingPathComponent("hatchery.json").path

        let container = ServiceSpec(
            name: "lan-dns", kind: .container, image: "4km3/dnsmasq:latest",
            configFile: "lan-dns.config.json",
            container: ContainerSpec(image: "4km3/dnsmasq:latest", network: "host"))
        let box = StackSpec(
            name: "box", backend: .host, environment: .prod, host: "jimmy@192.168.0.103",
            tofu: TofuBinding(directory: self.directory.path), services: [container])

        let app = ServiceSpec(
            name: "paylab", kind: .paymentGateway, image: "dokku/paylab:latest",
            domains: ["paylab.lab"], configFile: "paylab.config.json")
        let lab = StackSpec(
            name: "lab", backend: .dokku, environment: .dev, host: "dokku@192.168.0.103",
            tofu: TofuBinding(directory: self.directory.path), services: [app])

        self.manifest = StackManifest(version: 1, stacks: [box, lab])
    }

    func write(_ name: String, _ values: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: self.directory.appendingPathComponent(name))
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.directory)
    }
}

@Suite("What the declaration says about the saying of it")
struct DeclarationFindingsTests {
    @Test("a container service carries the host backend, its image and its restart policy")
    func containerInTheDocument() throws {
        let world = try AuditWorld()
        defer { world.remove() }

        let document = Declaration(manifests: [(world.manifest, world.manifestPath)])
        let box = try #require(document.stacks.first { $0.name == "box" })
        #expect(box.backend == "host")
        #expect(box.host == "jimmy@192.168.0.103")
        #expect(box.services[0].name == "lan-dns")
        #expect(box.services[0].kind == "container")
        #expect(box.services[0].image == "4km3/dnsmasq:latest")
        #expect(box.services[0].restart == "unless-stopped")
        #expect(box.services[0].findings.isEmpty)

        // A dokku service has no restart policy of its own, because dokku owns that answer.
        let lab = try #require(document.stacks.first { $0.name == "lab" })
        #expect(lab.services[0].restart == nil)
    }

    @Test("a stale sidecar and a secret still in it are both findings on the service that has them")
    func fillsFindings() async throws {
        let world = try AuditWorld()
        defer { world.remove() }

        // The container agrees with its box, so it stays clean.
        try world.write("lan-dns.config.json", ["PATH": "/usr/bin"])
        // The dokku app declares a key the box does not run with, and keeps a secret in the sidecar.
        try world.write(
            "paylab.config.json",
            ["APP_URL": "https://paylab.lab", "GATEWAY_ADMIN_TOKEN": "t", "GONE": "x"])

        let audit = DeclarationAudit(
            reader: LiveConfigReader(run: { argv in
                let command = argv.last ?? ""
                if command.hasPrefix("docker inspect") {
                    return Data("""
                        [{"Id": "a", "Name": "/lan-dns", "Config": {"Image": "4km3/dnsmasq:latest",
                          "Env": ["PATH=/usr/bin"]}, "State": {"Status": "running", "Running": true},
                          "HostConfig": {"NetworkMode": "host", "RestartPolicy": {"Name": "unless-stopped"}}}]
                        """.utf8)
                }
                return Data("""
                    {"APP_URL": "https://paylab.lab", "GATEWAY_ADMIN_TOKEN": "t", "KEYPAIR_JWKS": "j"}
                    """.utf8)
            }))
        let findings = await audit.findings(for: [(world.manifest, world.manifestPath)])

        #expect(findings["box/lan-dns"] == nil)
        let paylab = try #require(findings["lab/paylab"])
        #expect(paylab.map(\.code).sorted() == ["secret-in-sidecar", "stale-sidecar"])

        let secret = try #require(paylab.first { $0.code == FindingCode.secretInSidecar })
        #expect(secret.text.hasPrefix("GATEWAY_ADMIN_TOKEN is a secret still in the sidecar"))
        let stale = try #require(paylab.first { $0.code == FindingCode.staleSidecar })
        #expect(stale.text.contains("the box also runs with KEYPAIR_JWKS"))
        #expect(stale.text.contains("the box does not run with GONE"))
        // A value is never named, because the sidecar is gitignored for the values it holds.
        #expect(!stale.text.contains("https://paylab.lab"))

        let document = Declaration(
            manifests: [(world.manifest, world.manifestPath)], findings: findings)
        let lab = try #require(document.stacks.first { $0.name == "lab" })
        #expect(lab.services[0].findings.count == 2)
    }

    @Test("a key moved to the secrets file is declared, not missing")
    func aSplitKeyIsNotStale() async throws {
        let world = try AuditWorld()
        defer { world.remove() }
        try world.write("lan-dns.config.json", [:])
        try world.write("paylab.config.json", ["APP_URL": "https://paylab.lab"])
        try world.write("paylab.secrets.json", ["KEYPAIR_JWKS": "j"])

        let audit = DeclarationAudit(
            reader: LiveConfigReader(run: { argv in
                argv.last?.hasPrefix("docker inspect") == true
                    ? Data("[]".utf8)
                    : Data("{\"APP_URL\": \"https://paylab.lab\", \"KEYPAIR_JWKS\": \"j\"}".utf8)
            }))
        let findings = await audit.findings(for: [(world.manifest, world.manifestPath)])
        #expect(findings["lab/paylab"] == nil)
    }

    @Test("a manifest write publishes a document with no findings, because a write never reads a box")
    func aWriteNeverAudits() throws {
        let world = try AuditWorld()
        defer { world.remove() }
        let document = Declaration(manifests: [(world.manifest, world.manifestPath)])
        #expect(document.stacks.allSatisfy { $0.services.allSatisfy { $0.findings.isEmpty } })
    }

    @Test("the answers list names every service in stack order, with the backend that runs it")
    func answersInStackOrder() throws {
        let world = try AuditWorld()
        defer { world.remove() }
        let document = Declaration(manifests: [(world.manifest, world.manifestPath)])
        #expect(document.answers == ["lan-dns container host", "paylab payment-gateway dokku"])
    }

    @Test("a document with findings still reads back as itself")
    func roundTrips() throws {
        let world = try AuditWorld()
        defer { world.remove() }
        let document = Declaration(
            manifests: [(world.manifest, world.manifestPath)],
            findings: [
                "box/lan-dns": [
                    Declaration.Finding(code: FindingCode.staleSidecar, text: "one sentence")
                ]
            ])
        let decoded = try JSONDecoder().decode(Declaration.self, from: try document.encoded())
        #expect(decoded == document)
        #expect(decoded.stacks[0].services[0].findings[0].code == "stale-sidecar")
    }
}

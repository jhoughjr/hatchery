import Foundation
import Testing

@testable import HatcheryKit

/// A manifest directory holding one resolver on the box, because the audit reads the kind registry beside the manifest.
private struct ResolverWorld {
    let directory: URL
    let manifestPath: String
    let manifest: StackManifest

    init() throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hatchery-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.manifestPath = self.directory.appendingPathComponent("hatchery.json").path

        let resolver = ServiceSpec(
            name: "lan-dns",
            kind: ServiceKind(rawValue: "lan-dns"),
            image: "4km3/dnsmasq:latest",
            configFile: "lan-dns.config.json",
            container: ContainerSpec(image: "4km3/dnsmasq:latest", network: "host"))
        let box = StackSpec(
            name: "box", backend: .host, environment: .prod, host: "jimmy@192.168.0.103",
            services: [resolver])
        self.manifest = StackManifest(version: 1, stacks: [box])
    }

    /// Writes the resolver's kind file, with or without the names it claims to answer.
    func declareKind(resolves: [(String, String?)]?) throws {
        let kinds = self.directory.appendingPathComponent("kinds")
        try FileManager.default.createDirectory(at: kinds, withIntermediateDirectories: true)
        let list = resolves.map { entries in
            let rendered = entries.map { name, answer in
                answer.map { #"{"name": "\#(name)", "answer": "\#($0)"}"# } ?? #"{"name": "\#(name)"}"#
            }.joined(separator: ", ")
            return #",\#n  "resolves": [\#(rendered)]"#
        } ?? ""
        let body = """
            {
              "kind": "lan-dns",
              "summary": "A resolver declared for this test."\(list)
            }
            """
        try Data(body.utf8).write(to: kinds.appendingPathComponent("lan-dns.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.directory)
    }
}

/// The audit, with the box answering `answers` to every dig, and a record of what it was asked.
private func audit(answers: String, asked: AskedNames) -> DeclarationAudit {
    DeclarationAudit(
        reader: LiveConfigReader(run: { argv in
            let command = argv.last ?? ""
            if command.hasPrefix("dig ") {
                await asked.record(command)
                return Data(answers.utf8)
            }
            return Data("{}".utf8)
        }))
}

/// What the box was asked, so a case can say the LAN address was the one questioned.
private actor AskedNames {
    private(set) var commands: [String] = []
    func record(_ command: String) { self.commands.append(command) }
}

private func findings(_ world: ResolverWorld, _ audit: DeclarationAudit) async -> [Declaration.Finding] {
    let all = await audit.findings(for: [(manifest: world.manifest, path: world.manifestPath)])
    return all["box/lan-dns"] ?? []
}

@Suite("The names a resolver must answer, against what the box answers")
struct ResolverFindingsTests {
    @Test("a resolver that answers nothing at the LAN address is a finding")
    func silenceIsNamed() async throws {
        let world = try ResolverWorld()
        defer { world.remove() }
        try world.declareKind(resolves: [("vault.jimmyhoughjr.net", "192.168.0.103")])

        let found = await findings(world, audit(answers: "\n", asked: AskedNames()))

        let silent = try #require(found.first { $0.code == FindingCode.resolverSilent })
        #expect(silent.text.contains("192.168.0.103"))
    }

    @Test("the question is asked at the LAN address, because loopback answering is the fault itself")
    func theLanAddressIsAsked() async throws {
        let world = try ResolverWorld()
        defer { world.remove() }
        try world.declareKind(resolves: [("vault.jimmyhoughjr.net", "192.168.0.103")])
        let asked = AskedNames()

        _ = await findings(world, audit(answers: "192.168.0.103\n", asked: asked))

        let commands = await asked.commands
        #expect(commands.contains { $0.contains("@192.168.0.103") })
        #expect(!commands.contains { $0.contains("@127.0.0.1") })
    }

    @Test("an answer the declaration does not name is a finding, and names both")
    func aWrongAnswerIsNamed() async throws {
        let world = try ResolverWorld()
        defer { world.remove() }
        try world.declareKind(resolves: [("vault.jimmyhoughjr.net", "192.168.0.103")])

        let found = await findings(world, audit(answers: "104.21.68.70\n", asked: AskedNames()))

        let wrong = try #require(found.first { $0.code == FindingCode.resolverWrongAnswer })
        #expect(wrong.text.contains("104.21.68.70"))
        #expect(wrong.text.contains("192.168.0.103"))
    }

    @Test("a resolver answering what it declared says nothing")
    func agreementIsQuiet() async throws {
        let world = try ResolverWorld()
        defer { world.remove() }
        try world.declareKind(resolves: [("vault.jimmyhoughjr.net", "192.168.0.103")])

        let found = await findings(world, audit(answers: "192.168.0.103\n", asked: AskedNames()))

        #expect(found.filter { $0.code.hasPrefix("resolver-") }.isEmpty)
    }

    @Test("a name with no declared answer asks only that a reply comes back")
    func anyAnswerWillDo() async throws {
        let world = try ResolverWorld()
        defer { world.remove() }
        try world.declareKind(resolves: [("github.com", nil)])

        let found = await findings(world, audit(answers: "140.82.114.4\n", asked: AskedNames()))

        #expect(found.filter { $0.code.hasPrefix("resolver-") }.isEmpty)
    }

    @Test("a kind that claims no name is never asked for one")
    func noClaimIsNeverAsked() async throws {
        let world = try ResolverWorld()
        defer { world.remove() }
        try world.declareKind(resolves: nil)
        let asked = AskedNames()

        let found = await findings(world, audit(answers: "192.168.0.103\n", asked: asked))

        #expect(found.filter { $0.code.hasPrefix("resolver-") }.isEmpty)
        #expect(await asked.commands.isEmpty)
    }

    @Test("a silent resolver is said once, not once per name it was going to be asked")
    func silenceIsSaidOnce() async throws {
        let world = try ResolverWorld()
        defer { world.remove() }
        try world.declareKind(resolves: [
            ("vault.jimmyhoughjr.net", "192.168.0.103"),
            ("s3.jimmyhoughjr.net", "192.168.0.103"),
            ("forgejo.jimmyhoughjr.net", "192.168.0.103"),
        ])

        let found = await findings(world, audit(answers: "\n", asked: AskedNames()))

        #expect(found.filter { $0.code == FindingCode.resolverSilent }.count == 1)
    }
}

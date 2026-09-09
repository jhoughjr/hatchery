import Foundation
import Testing

import HatcheryKit

@testable import ScanKit

/// The `docker inspect` answers recorded off the opi on 2026-09-08, read only.
private func recorded(_ name: String) throws -> String {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    return try String(
        contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
}

/// The two recordings as one inspect answer, which is what a scan of the whole box reads.
private func recordedPair() throws -> String {
    let one = try recorded("lan-dns.inspect.json")
    let two = try recorded("rookery-pg.inspect.json")
    let objects = try JSONSerialization.jsonObject(with: Data(one.utf8)) as? [Any] ?? []
    let more = try JSONSerialization.jsonObject(with: Data(two.utf8)) as? [Any] ?? []
    return String(
        decoding: try JSONSerialization.data(withJSONObject: objects + more), as: UTF8.self)
}

/// Everything on the opi, as `docker ps` names it.
private let boxNames = """
    status.web.1
    rookery.runner.1
    rookery-pg
    act_runner
    lan-dns
    buildx_buildkit_builder-51d814da0
    homeassistant
    mwstack-pg-dev
    mwserver-temporal
    """

private func fakeBox(_ argv: [String], names: String = boxNames, inspect: String) -> CommandOutput {
    let command = argv.last ?? ""
    if command.hasPrefix("docker ps") {
        return CommandOutput(status: 0, standardOutput: names + "\n")
    }
    if command.hasPrefix("docker inspect") {
        return CommandOutput(status: 0, standardOutput: inspect)
    }
    if command.hasPrefix("docker info") {
        return CommandOutput(status: 0, standardOutput: "29.5.3\n")
    }
    // Everything else arrived as a dokku command in a plain shell.
    return CommandOutput(
        status: 127, standardOutput: "", standardError: "bash: line 1: apps:list: command not found")
}

private func hostStack(services: [ServiceSpec] = []) -> StackSpec {
    StackSpec(
        name: "box", backend: .host, environment: .prod, host: "jimmy@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/box"), services: services)
}

@Suite("Scanning a box for the containers dokku does not own")
struct HostScanTests {
    @Test("a target that names its own account falls through to the docker daemon")
    func identifiesHost() async throws {
        let scanner = Scanner(
            execute: { argv, _ in fakeBox(argv, inspect: "[]") }, environment: [:])
        let (provider, address) = try await scanner.identify("jimmy@192.168.0.103")
        #expect(provider == .host)
        #expect(address == "jimmy@192.168.0.103")
    }

    @Test("a box that answers as neither says so about both")
    func identifiesNeither() async {
        let scanner = Scanner(
            execute: { _, _ in CommandOutput(status: 255, standardOutput: "", standardError: "no route") },
            environment: [:])
        await #expect(throws: ScanError.self) { try await scanner.identify("jimmy@192.168.0.103") }
    }

    @Test("a scan lists what dokku and buildx do not own, with the image, network and restart policy")
    func scansHost() async throws {
        let inspect = try recordedPair()
        let scanner = Scanner(
            execute: { argv, _ in fakeBox(argv, inspect: inspect) }, environment: [:])
        let inventory = try await scanner.scan("jimmy@192.168.0.103")

        #expect(inventory.provider == .host)
        #expect(inventory.target == "jimmy@192.168.0.103")
        // A container has no database attachment the daemon knows about.
        #expect(inventory.databases == nil)
        #expect(inventory.apps.map(\.name) == ["lan-dns", "rookery-pg"])
        #expect(inventory.apps[0].network == "host")
        #expect(inventory.apps[0].restart == "unless-stopped")
        #expect(inventory.apps[0].image == "4km3/dnsmasq:latest")
        #expect(inventory.apps[1].network == "rookery_default")
        #expect(inventory.apps[1].running)
    }

    @Test("the inspect asks only for the names no other declaration owns")
    func filtersBeforeTheInspect() async throws {
        let asked = AskedCommands()
        let inspect = try recordedPair()
        let scanner = Scanner(
            execute: { argv, _ in
                asked.commands.append(argv.last ?? "")
                return fakeBox(argv, inspect: inspect)
            },
            environment: [:])
        _ = try await scanner.scan("jimmy@192.168.0.103")

        let inspectCommand = try #require(asked.commands.first { $0.hasPrefix("docker inspect") })
        #expect(!inspectCommand.contains("status.web.1"))
        #expect(!inspectCommand.contains("rookery.runner.1"))
        #expect(!inspectCommand.contains("buildx_buildkit_"))
        for name in ["rookery-pg", "act_runner", "lan-dns", "homeassistant", "mwstack-pg-dev",
                     "mwserver-temporal"] {
            #expect(inspectCommand.contains(name), "\(name) should be inspected")
        }
    }

    @Test("a scan of a box with nothing to declare asks for no inspect at all")
    func nothingToDeclare() async throws {
        let scanner = Scanner(
            execute: { argv, _ in
                fakeBox(argv, names: "status.web.1\ncoop.web.1", inspect: "[]")
            },
            environment: [:])
        let inventory = try await scanner.scan("jimmy@192.168.0.103")
        #expect(inventory.apps.isEmpty)
    }

    @Test("a container a host stack declares is classified as declared, and the rest as foreign")
    func classifiesAgainstAHostStack() throws {
        let declared = ServiceSpec(
            name: "lan-dns", kind: .container, image: "4km3/dnsmasq:latest",
            configFile: "lan-dns.config.json")
        let manifest = StackManifest(version: 1, stacks: [hostStack(services: [declared])])
        let inventory = Inventory(
            provider: .host, target: "jimmy@192.168.0.103",
            apps: [
                FoundApp(name: "lan-dns", running: true, network: "host", restart: "unless-stopped"),
                FoundApp(name: "act_runner", running: true, network: "bridge", restart: "unless-stopped"),
            ],
            databases: nil)

        let sorted = Scanner.classify(inventory, against: manifest)
        #expect(sorted[0].claim == .declared(stack: "box"))
        #expect(sorted[1].claim == .foreign)
    }
}

/// Carries the commands the fake box was asked, out of the `@Sendable` executor.
private final class AskedCommands: @unchecked Sendable {
    var commands: [String] = []
}

@Suite("Adopting a container into a host stack")
struct ContainerAdoptTests {
    private func manifest(backend: Backend = .host) -> StackManifest {
        StackManifest(
            version: 1,
            stacks: [
                StackSpec(
                    name: "box", backend: backend, environment: .prod, host: "jimmy@192.168.0.103",
                    tofu: TofuBinding(directory: "/infra/box"), services: [])
            ])
    }

    @Test("one inspect carries the whole run into the manifest, the sidecar and the declaration")
    func adoptsLANDNS() async throws {
        let inspect = try recorded("lan-dns.inspect.json")
        let adopter = Adopter(execute: { _, _ in
            CommandOutput(status: 0, standardOutput: inspect)
        })
        let facts = try await adopter.container(named: "lan-dns", on: "jimmy@192.168.0.103")
        let result = try await adopter.planContainer(
            facts, kind: .container, into: "box", box: "jimmy@192.168.0.103",
            manifest: manifest(), manifestPath: "/infra/box/hatchery.json")

        #expect(result.service.name == "lan-dns")
        #expect(result.service.kind == .container)
        #expect(result.service.image == "4km3/dnsmasq:latest")
        #expect(result.service.container?.network == "host")
        #expect(result.service.healthPath == nil)
        #expect(result.manifest.stacks[0].services.map(\.name) == ["lan-dns"])

        let declaration = try #require(result.files.first { $0.role == .declaration })
        #expect(declaration.path == "lan_dns.tf")
        #expect(declaration.contents.contains("""
            import {
              to = docker_container.lan_dns
              id = "4af81f8ff62f65b98eddd6157dcf1d44ad01e4e3f048ba606ba86856287997b2"
            }
            """))

        // No kind file, so the contract is empty and every key the box runs with stays in the sidecar.
        let sidecar = try #require(result.files.first { $0.path == "lan-dns.config.json" })
        #expect(sidecar.contents.contains("\"PATH\""))
        #expect(!result.files.contains { $0.path == "lan-dns.secrets.json" })
    }

    @Test("a kind file's secret keys leave the sidecar for the secrets file, and its health path is taken")
    func splitsTheEnvironmentByAKindFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hatchery-container-adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("kinds"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The registry answers under the container's own name, so the file is named for it.
        let kindFile = """
            {
              "kind": "rookery-pg",
              "healthcheck": "/ready",
              "environment": {
                "PGDATA": {"required": true},
                "PG_SHA256": {"secret": true}
              }
            }
            """
        try kindFile.write(
            to: directory.appendingPathComponent("kinds/rookery-pg.json"), atomically: true,
            encoding: .utf8)

        let manifestPath = directory.appendingPathComponent("hatchery.json").path
        let inspect = try recorded("rookery-pg.inspect.json")
        let adopter = Adopter(execute: { _, _ in
            CommandOutput(status: 0, standardOutput: inspect)
        })
        let facts = try await adopter.container(named: "rookery-pg", on: "jimmy@192.168.0.103")
        let registry = KindRegistry(manifestPath: manifestPath)
        let named = try #require(try registry.kindFile(for: ServiceKind(rawValue: "rookery-pg")))

        let result = try await adopter.planContainer(
            facts, kind: ServiceKind(rawValue: named.kind), into: "box",
            box: "jimmy@192.168.0.103", manifest: manifest(), manifestPath: manifestPath,
            kindFile: named)

        #expect(result.service.healthPath == "/ready")
        let sidecar = try #require(result.files.first { $0.path == "rookery-pg.config.json" })
        let secrets = try #require(result.files.first { $0.path == "rookery-pg.secrets.json" })
        #expect(sidecar.contents.contains("\"PGDATA\""))
        #expect(!sidecar.contents.contains("PG_SHA256"))
        #expect(secrets.contents.contains("\"PG_SHA256\""))
        #expect(!secrets.contents.contains("\"PGDATA\""))
    }

    @Test("a stack on another backend is refused, and the refusal names what a host stack takes")
    func refusesAStackOnAnotherBackend() async throws {
        let inspect = try recorded("lan-dns.inspect.json")
        let adopter = Adopter(execute: { _, _ in
            CommandOutput(status: 0, standardOutput: inspect)
        })
        let facts = try await adopter.container(named: "lan-dns", on: "jimmy@192.168.0.103")

        await #expect(throws: AdoptError.self) {
            try await adopter.planContainer(
                facts, kind: .container, into: "box", box: "jimmy@192.168.0.103",
                manifest: manifest(backend: .dokku), manifestPath: "/infra/box/hatchery.json")
        }
        let refusal = AdoptError.stackNotOnHost(
            stack: "estate", backend: "dokku", box: "jimmy@192.168.0.103")
        #expect(refusal.description.contains("is on the dokku backend"))
        #expect(refusal.description.contains("--backend host"))
    }

    @Test("a replace regenerates a container the stack already declares, and keeps its sidecar")
    func replacesADeclaredContainer() async throws {
        let inspect = try recorded("lan-dns.inspect.json")
        let adopter = Adopter(execute: { _, _ in
            CommandOutput(status: 0, standardOutput: inspect)
        })
        let facts = try await adopter.container(named: "lan-dns", on: "jimmy@192.168.0.103")

        var declared = manifest()
        declared.stacks[0].services = [
            ServiceSpec(
                name: "lan-dns", kind: .container, image: "4km3/dnsmasq:0.1",
                configFile: "lan-dns.config.json")
        ]

        // Without the flag the refusal stands, because adopting twice is what it is there to catch.
        await #expect(throws: AdoptError.self) {
            try await adopter.planContainer(
                facts, kind: .container, into: "box", box: "jimmy@192.168.0.103",
                manifest: declared, manifestPath: "/infra/box/hatchery.json")
        }

        let result = try await adopter.planContainer(
            facts, kind: .container, into: "box", box: "jimmy@192.168.0.103",
            manifest: declared, manifestPath: "/infra/box/hatchery.json", replacing: true)

        // The manifest entry is rewritten in place rather than doubled.
        #expect(result.manifest.stacks[0].services.map(\.name) == ["lan-dns"])
        #expect(result.manifest.stacks[0].services[0].image == "4km3/dnsmasq:latest")
        #expect(result.files.contains { $0.path == "lan_dns.tf" })
        #expect(!result.files.contains { $0.role == .config })

        // --refresh-config is what asks for the sidecar to be read off the box again.
        let refreshed = try await adopter.planContainer(
            facts, kind: .container, into: "box", box: "jimmy@192.168.0.103",
            manifest: declared, manifestPath: "/infra/box/hatchery.json", replacing: true,
            refreshConfig: true)
        #expect(refreshed.files.contains { $0.path == "lan-dns.config.json" })
    }

    @Test("the image is read a second time, and only what the run adds to it reaches the sidecar")
    func sidecarHoldsOnlyWhatTheRunAdds() async throws {
        let inspect = try recorded("rookery-pg.inspect.json")
        let imageEnv = try recorded("postgres-17-alpine.image-env.json")
        let asked = AskedCommands()
        let adopter = Adopter(execute: { command, _ in
            asked.commands.append(command.joined(separator: " "))
            let last = command.last ?? ""
            return CommandOutput(
                status: 0, standardOutput: last.hasPrefix("docker image inspect") ? imageEnv : inspect)
        })
        let facts = try await adopter.container(named: "rookery-pg", on: "jimmy@192.168.0.103")
        let image = try await adopter.imageEnvironment(
            for: facts.image, on: "jimmy@192.168.0.103")

        #expect(asked.commands.last?.contains("docker image inspect postgres:17-alpine") == true)
        #expect(image.count == 8)

        let result = try await adopter.planContainer(
            facts, kind: .container, into: "box", box: "jimmy@192.168.0.103",
            manifest: manifest(), manifestPath: "/infra/box/hatchery.json",
            imageEnvironment: image)

        // The eight keys rookery-pg reports are all the image's own, so the sidecar holds none of them.
        let sidecar = try #require(result.files.first { $0.path == "rookery-pg.config.json" })
        let recorded = try JSONDecoder().decode(
            [String: String].self, from: Data(sidecar.contents.utf8))
        #expect(recorded.isEmpty)
    }

    @Test("an image the box cannot inspect is a refusal, not an empty environment")
    func refusesAnImageItCannotRead() async {
        let refusing = Adopter(execute: { _, _ in
            CommandOutput(
                status: 1, standardOutput: "",
                standardError: "Error: No such image: postgres:17-alpine")
        })
        await #expect(throws: AdoptError.self) {
            try await refusing.imageEnvironment(
                for: "postgres:17-alpine", on: "jimmy@192.168.0.103")
        }

        // An answer the box gives with status 0 that is not an environment is refused the same way.
        let garbled = Adopter(execute: { _, _ in
            CommandOutput(status: 0, standardOutput: "{}\n")
        })
        await #expect(throws: ContainerInspectionError.self) {
            try await garbled.imageEnvironment(
                for: "postgres:17-alpine", on: "jimmy@192.168.0.103")
        }
    }

    @Test("a container the box does not hold is refused before anything is planned")
    func refusesAContainerThatIsNotThere() async {
        let adopter = Adopter(execute: { _, _ in
            CommandOutput(
                status: 1, standardOutput: "[]\n",
                standardError: "Error: No such object: nowhere")
        })
        await #expect(throws: AdoptError.self) {
            try await adopter.container(named: "nowhere", on: "jimmy@192.168.0.103")
        }
    }
}

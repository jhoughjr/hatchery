import Foundation
import Testing

import HatcheryKit

@testable import ScanKit

@Suite("Scanning a target for what runs there")
struct ScanTests {
    /// A fake dokku box with two apps, one on the shared network, and one stray database.
    private static func fakeBox(_ argv: [String]) -> CommandOutput {
        let command = argv.dropFirst(6).joined(separator: " ")
        switch command {
        case "apps:list":
            return CommandOutput(status: 0, standardOutput: "=====> My Apps\nmws-api\nwiki\n")
        case "ps:report mws-api --running":
            return CommandOutput(status: 0, standardOutput: "true\n")
        case "ps:report wiki --running":
            return CommandOutput(status: 0, standardOutput: "false\n")
        case "network:report mws-api --network-attach-post-create":
            return CommandOutput(status: 0, standardOutput: "hatchery-net\n")
        case "network:report wiki --network-attach-post-create":
            return CommandOutput(status: 0, standardOutput: "\n")
        case "postgres:app-links mws-api":
            return CommandOutput(status: 0, standardOutput: "mws-api-db\n")
        case "postgres:app-links wiki":
            return CommandOutput(status: 1, standardOutput: "", standardError: "no links")
        case "postgres:list":
            return CommandOutput(
                status: 0,
                standardOutput: "NAME        VERSION  STATUS  EXPOSED PORTS  LINKS\n"
                    + "mws-api-db  16       running -              mws-api\n"
                    + "orphan-db   16       running -              -\n")
        default:
            return CommandOutput(status: 1, standardOutput: "", standardError: "unknown \(command)")
        }
    }

    @Test("a box that answers apps:list is identified as dokku, through the dokku user")
    func identifiesDokku() async throws {
        let scanner = Scanner(execute: { argv, _ in Self.fakeBox(argv) }, environment: [:])
        let (provider, address) = try await scanner.identify("192.168.0.103")
        #expect(provider == .dokku)
        #expect(address == "dokku@192.168.0.103")
    }

    @Test("no target and a token means App Platform, and no token means nothing answered")
    func identifiesPlatform() async throws {
        let withToken = Scanner(
            execute: { _, _ in CommandOutput(status: 0, standardOutput: "") },
            environment: ["DIGITALOCEAN_TOKEN": "dop_v1_x"])
        let (provider, _) = try await withToken.identify(nil)
        #expect(provider == .appPlatform)

        let without = Scanner(
            execute: { _, _ in CommandOutput(status: 0, standardOutput: "") }, environment: [:])
        await #expect(throws: ScanError.self) { try await without.identify("appPlatform") }
    }

    @Test("a dokku scan reads every app, its state, network, and links, and every database")
    func scansDokku() async throws {
        let scanner = Scanner(execute: { argv, _ in Self.fakeBox(argv) }, environment: [:])
        let inventory = try await scanner.scan("192.168.0.103")

        #expect(inventory.provider == .dokku)
        #expect(inventory.apps.map(\.name) == ["mws-api", "wiki"])
        #expect(inventory.apps[0].running)
        #expect(inventory.apps[0].network == "hatchery-net")
        #expect(inventory.apps[0].databases == ["mws-api-db"])
        #expect(!inventory.apps[1].running)
        #expect(inventory.apps[1].network == nil)
        #expect(inventory.apps[1].databases.isEmpty)
        #expect(inventory.databases == ["mws-api-db", "orphan-db"])
    }

    @Test("classification sorts finds into declared, hatchery-shaped, and foreign")
    func classifies() {
        let inventory = Inventory(
            provider: .dokku, target: "dokku@192.168.0.103",
            apps: [
                FoundApp(name: "mws-api", running: true, network: "hatchery-net"),
                FoundApp(name: "stray", running: true, network: "hatchery-net"),
                FoundApp(name: "wiki", running: false),
            ],
            databases: [])
        let manifest = StackManifest(stacks: [
            StackSpec(
                name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
                services: [
                    ServiceSpec(
                        name: "mws-api", kind: ServiceKind(rawValue: "mwserver"),
                        image: "x:y", configFile: "c.env")
                ]),
            StackSpec(
                name: "elsewhere", backend: .dokku, host: "dokku@10.0.0.9",
                services: [
                    ServiceSpec(
                        name: "wiki", kind: ServiceKind(rawValue: "mwserver"),
                        image: "x:y", configFile: "c.env")
                ]),
        ])

        let claims = Scanner.classify(inventory, against: manifest).map(\.claim)
        #expect(claims == [.declared(stack: "lab"), .hatcheryShaped, .foreign])

        // A stray on the same network as a declared app is hatchery-shaped, whatever the
        // network is called. The box has no postgres plugin, so databases are unknown.
        let labNet = Inventory(
            provider: .dokku, target: "dokku@192.168.0.103",
            apps: [
                FoundApp(name: "mws-api", running: true, network: "infra_default"),
                FoundApp(name: "stray", running: true, network: "infra_default"),
            ],
            databases: nil)
        let labClaims = Scanner.classify(labNet, against: manifest).map(\.claim)
        #expect(labClaims == [.declared(stack: "lab"), .hatcheryShaped])

        let unclassified = Scanner.classify(inventory, against: nil).map(\.claim)
        #expect(unclassified == [.hatcheryShaped, .hatcheryShaped, .foreign])
    }

    @Test("an App Platform body becomes the same inventory shape, image and databases included")
    func readsPlatformBody() throws {
        let body = """
            {"apps": [
              {"spec": {"name": "mws-prod",
                        "services": [{"name": "web", "image": {"registry": "macworkstack",
                                      "repository": "mwserver", "tag": "staging"}}],
                        "databases": [{"name": "db"}]},
               "active_deployment": {"phase": "ACTIVE"}},
              {"spec": {"name": "sleepy", "services": []},
               "active_deployment": {"phase": "ERROR"}}
            ]}
            """
        let inventory = try Scanner.appPlatformInventory(from: Data(body.utf8))
        #expect(inventory.provider == .appPlatform)
        #expect(inventory.apps.map(\.name) == ["mws-prod", "sleepy"])
        #expect(inventory.apps[0].image == "macworkstack/mwserver:staging")
        #expect(inventory.apps[0].running)
        #expect(inventory.apps[0].databases == ["db"])
        #expect(!inventory.apps[1].running)
        #expect(inventory.databases == ["db"])
    }

    @Test("a Cloud Run services list becomes the same inventory shape, with databases unknown")
    func readsCloudRunBody() throws {
        let body = """
            [{"metadata": {"name": "mwgcp"},
              "spec": {"template": {"spec": {"containers": [{"image": "us-central1-docker.pkg.dev/p/i/mwserver:staging"}]}}},
              "status": {"conditions": [{"type": "Ready", "status": "True"}]}},
             {"metadata": {"name": "sleepy"},
              "spec": {"template": {"spec": {"containers": []}}},
              "status": {"conditions": [{"type": "Ready", "status": "False"}]}}]
            """
        let inventory = try Scanner.cloudRunInventory(from: Data(body.utf8), project: "mws-lab")
        #expect(inventory.provider == .cloudRun)
        #expect(inventory.target == "mws-lab")
        #expect(inventory.apps.map(\.name) == ["mwgcp", "sleepy"])
        #expect(inventory.apps[0].image == "us-central1-docker.pkg.dev/p/i/mwserver:staging")
        #expect(inventory.apps[0].running)
        #expect(!inventory.apps[1].running)
        #expect(inventory.databases == nil)
    }

    @Test("cloudRun as a target needs gcloud and a project, and says which is missing")
    func identifiesCloudRun() async throws {
        let none = Scanner(execute: { _, _ in CommandOutput(status: 1, standardOutput: "") }, environment: [:])
        await #expect(throws: ScanError.self) { try await none.identify("cloudRun") }

        let set = Scanner(
            execute: { argv, _ in
                argv.first == "sh"
                    ? CommandOutput(status: 0, standardOutput: "/usr/bin/gcloud")
                    : CommandOutput(status: 0, standardOutput: "mws-lab\n")
            }, environment: [:])
        let (provider, project) = try await set.identify("cloudRun")
        #expect(provider == .cloudRun)
        #expect(project == "mws-lab")
    }
}

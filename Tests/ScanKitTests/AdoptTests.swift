import Foundation
import HatcheryKit
import Testing

@testable import ScanKit

@Suite("Adopting a running app into the manifest")
struct AdoptTests {
    private static let inspect = """
        [{"Config": {"Image": "dokku/mwlab:latest",
                     "Labels": {"com.dokku.docker-image-labeler/alternate-tags":
                                "[\\"mhehmsoth/mwserver2:arm64-9cb6e4c-dev\\"]"}}}]
        """

    private static func fakeBox(_ argv: [String]) -> CommandOutput {
        let command = argv.dropFirst(6).joined(separator: " ")
        switch command {
        case "domains:report mwlab --domains-app-vhosts":
            return CommandOutput(status: 0, standardOutput: "mwlab.opi mwlab.jimmyhoughjr.net\n")
        case "ports:report mwlab --ports-map":
            return CommandOutput(status: 0, standardOutput: "http:80:8080\n")
        case "network:report mwlab --network-attach-post-create":
            return CommandOutput(status: 0, standardOutput: "macworkstack-infra_default\n")
        case "ps:inspect mwlab":
            return CommandOutput(status: 0, standardOutput: inspect)
        case "config:export --format json mwlab":
            return CommandOutput(
                status: 0, standardOutput: #"{"APP_ID": "mwlab", "DATABASE_URL": "postgres://x"}"#)
        default:
            return CommandOutput(status: 1, standardOutput: "", standardError: "unknown \(command)")
        }
    }

    @Test("facts come off the box: the real image, domains, port, network, and config")
    func readsFacts() async throws {
        let adopter = Adopter(execute: { argv, _ in Self.fakeBox(argv) })
        let facts = try await adopter.facts(for: "mwlab", on: "dokku@192.168.0.103")
        #expect(facts.image == "mhehmsoth/mwserver2:arm64-9cb6e4c-dev")
        #expect(facts.domains == ["mwlab.opi", "mwlab.jimmyhoughjr.net"])
        #expect(facts.containerPort == 8080)
        #expect(facts.network == "macworkstack-infra_default")
        #expect(facts.config == ["APP_ID": "mwlab", "DATABASE_URL": "postgres://x"])
    }

    @Test("the image falls back to dokku's retag when no alternate tag is kept")
    func imageFallback() {
        let bare = #"[{"Config": {"Image": "dokku/wiki:latest", "Labels": {}}}]"#
        #expect(Adopter.image(fromInspect: bare, app: "wiki") == "dokku/wiki:latest")
        #expect(Adopter.image(fromInspect: "not json", app: "wiki") == "dokku/wiki:latest")
        #expect(Adopter.containerPort(fromPortMap: "https:443:3000 http:80:3000") == 3000)
        #expect(Adopter.containerPort(fromPortMap: "") == 8080)
    }

    @Test("the kind is read from the image when it says, and is a question when it does not")
    func infersKind() {
        #expect(Adopter.inferKind(fromImage: "mhehmsoth/mwserver2:arm64") == .mwserver)
        #expect(Adopter.inferKind(fromImage: "x/payment-gateway:1") == .paymentGateway)
        #expect(Adopter.inferKind(fromImage: "x/comlab:1") == .communicationGateway)
        #expect(Adopter.inferKind(fromImage: "ghost:5") == nil)
    }

    @Test("the plan declares the service into the stack with the box's config, not minted values")
    func plansAdoption() async throws {
        let adopter = Adopter(execute: { argv, _ in Self.fakeBox(argv) })
        let facts = try await adopter.facts(for: "mwlab", on: "dokku@192.168.0.103")
        let manifest = StackManifest(stacks: [
            StackSpec(
                name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
                tofu: TofuBinding(directory: "/tmp/lab"))
        ])
        let result = try await adopter.plan(
            facts, kind: .mwserver, into: "lab", box: "dokku@192.168.0.103", manifest: manifest)

        #expect(result.manifest.stack(named: "lab")?.services.map(\.name) == ["mwlab"])
        #expect(result.service.image == "mhehmsoth/mwserver2:arm64-9cb6e4c-dev")
        let config = result.files.first { $0.role == .config }
        #expect(config?.path == "mwlab.config.json")
        let written = try JSONDecoder().decode(
            [String: String].self, from: Data((config?.contents ?? "").utf8))
        #expect(written == ["APP_ID": "mwlab", "DATABASE_URL": "postgres://x"])
        #expect(result.files.contains { $0.role == .declaration })
        #expect(result.importCommand == "tofu import dokku_app.mwlab mwlab")
    }

    @Test("a stack on another box, or an app already declared, is refused")
    func refusals() async throws {
        let adopter = Adopter(execute: { argv, _ in Self.fakeBox(argv) })
        let facts = try await adopter.facts(for: "mwlab", on: "dokku@192.168.0.103")
        let elsewhere = StackManifest(stacks: [
            StackSpec(name: "far", backend: .dokku, host: "dokku@10.0.0.9", tofu: TofuBinding(directory: "/tmp/far"))
        ])
        await #expect(throws: AdoptError.stackNotOnBox(stack: "far", box: "dokku@192.168.0.103")) {
            try await adopter.plan(facts, kind: .mwserver, into: "far", box: "dokku@192.168.0.103", manifest: elsewhere)
        }
        let declared = StackManifest(stacks: [
            StackSpec(
                name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
                tofu: TofuBinding(directory: "/tmp/lab"),
                services: [ServiceSpec(name: "mwlab", kind: .mwserver, image: "x", configFile: "c")])
        ])
        await #expect(throws: AdoptError.alreadyDeclared(app: "mwlab", stack: "lab")) {
            try await adopter.plan(facts, kind: .mwserver, into: "lab", box: "dokku@192.168.0.103", manifest: declared)
        }
    }
}

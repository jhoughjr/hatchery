import Foundation
import HatcheryKit
import ScanKit
import Testing

@testable import HatcheryWeb

@Suite("The box routes: scan a target, adopt a find")
struct BoxRouteTests {
    private static let inspect = """
        [{"Config": {"Image": "dokku/docs:latest", "Labels": {}}}]
        """

    /// One box with a declared app and a stray on the same network.
    private static func fakeBox(_ argv: [String]) -> CommandOutput {
        let command = argv.dropFirst(6).joined(separator: " ")
        switch command {
        case "apps:list": return CommandOutput(status: 0, standardOutput: "=====> My Apps\nmwlab\ndocs\n")
        case "ps:report mwlab --running", "ps:report docs --running":
            return CommandOutput(status: 0, standardOutput: "true\n")
        case "network:report mwlab --network-attach-post-create",
            "network:report docs --network-attach-post-create":
            return CommandOutput(status: 0, standardOutput: "infra_default\n")
        case "domains:report docs --domains-app-vhosts":
            return CommandOutput(status: 0, standardOutput: "docs.jimmyhoughjr.net\n")
        case "ports:report docs --ports-map": return CommandOutput(status: 0, standardOutput: "http:80:8080\n")
        case "ps:inspect docs": return CommandOutput(status: 0, standardOutput: inspect)
        case "config:export --format json docs": return CommandOutput(status: 0, standardOutput: #"{"A": "1"}"#)
        default: return CommandOutput(status: 1, standardOutput: "", standardError: "no \(command)")
        }
    }

    private func stack() -> StackSpec {
        StackSpec(
            name: "mwlab", backend: .dokku, host: "dokku@192.168.0.103",
            tofu: TofuBinding(directory: "/infra/mwserver-tf"),
            services: [ServiceSpec(name: "mwlab", kind: .mwserver, image: "x:y", configFile: "mwlab.config.json")])
    }

    private func post(_ path: String, _ object: [String: Any]) -> WebRequest {
        WebRequest(
            method: "POST", path: path, query: [:], headers: [:],
            body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func api(saved: @escaping @Sendable (StackManifest) -> Void = { _ in }) -> HatcheryAPI {
        HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            saveManifest: { manifest, _ in saved(manifest) },
            manifestPath: { "/infra/hatchery.json" },
            scaffolder: Scaffolder(readFile: { _ in "" }, writeFile: { _, _ in }),
            scanner: ScanKit.Scanner(execute: { argv, _ in Self.fakeBox(argv) }, environment: [:]),
            adopter: Adopter(execute: { argv, _ in Self.fakeBox(argv) }),
            sealState: { _ in nil })
    }

    @Test("a scan classifies each app against the manifest and says when databases are unlistable")
    func scans() async throws {
        let response = await api().handle(post("/api/box/scan", ["target": "192.168.0.103"]))
        #expect(response.status == 200)
        let view = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(view["provider"] as? String == "dokku")
        let apps = try #require(view["apps"] as? [[String: Any]])
        #expect(apps.map { $0["claim"] as? String } == ["declared", "hatchery-shaped"])
        #expect(apps[0]["stack"] as? String == "mwlab")
        #expect(view["databasesListable"] as? Bool == false)
    }

    @Test("adopt is a dry run without confirm, and writes the manifest with it")
    func adopts() async throws {
        final class Saved: @unchecked Sendable { var manifests: [StackManifest] = [] }
        let saved = Saved()
        let api = api(saved: { saved.manifests.append($0) })

        let dry = await api.handle(
            post("/api/box/adopt", ["target": "192.168.0.103", "app": "docs", "stack": "mwlab", "kind": "mwserver"]))
        #expect(dry.status == 200)
        let plan = try #require(try JSONSerialization.jsonObject(with: dry.body) as? [String: Any])
        #expect(plan["written"] as? Bool == false)
        #expect(plan["image"] as? String == "dokku/docs:latest")
        #expect((plan["files"] as? [String])?.contains("docs.config.json") == true)
        #expect(plan["importCommand"] as? String == "tofu import dokku_app.docs docs")
        #expect(saved.manifests.isEmpty)

        let write = await api.handle(
            post("/api/box/adopt", ["target": "192.168.0.103", "app": "docs", "stack": "mwlab", "kind": "mwserver", "confirm": "docs"]))
        #expect(write.status == 200)
        #expect(saved.manifests.first?.stack(named: "mwlab")?.services.map(\.name) == ["mwlab", "docs"])
    }

    @Test("an app with no kind in its image and none given is a question, not a guess")
    func adoptNeedsAKind() async throws {
        let response = await api().handle(
            post("/api/box/adopt", ["target": "192.168.0.103", "app": "docs", "stack": "mwlab"]))
        #expect(response.status == 400)
        #expect(String(decoding: response.body, as: UTF8.self).contains("--kind") || String(decoding: response.body, as: UTF8.self).contains("kind"))
    }
}

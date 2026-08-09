import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

/// The dashboard's `stack rm`: the plan first, the name typed back, production refused —
/// every read and write injected so nothing shells out.
struct DestroyRouteTests {
    private func stack(environment: Environment = .dev) -> StackSpec {
        StackSpec(
            name: "mwlab-3",
            backend: .dokku,
            environment: environment,
            host: "dokku@192.168.0.103",
            tofu: TofuBinding(directory: "/infra/mwlab-3"),
            services: [
                ServiceSpec(
                    name: "mwlab-3", kind: .mwserver, image: "mwserver2:arm64-abc",
                    domains: ["mwlab-3.opi"], configFile: "mwlab-3.config.json",
                    imageVariable: "mwlab_3_image")
            ])
    }

    private func post(_ path: String, _ object: [String: Any]) -> WebRequest {
        WebRequest(
            method: "POST", path: path, query: [:], headers: [:],
            body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func decoded(_ response: WebResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    /// A deployer whose tofu never runs: destroy plans answer with the given summary text.
    private func deployer(planOutput: String, destroyOutput: String = "Destroy complete!") -> Deployer {
        Deployer(execute: { argv, _ in
            if argv.contains("-destroy") {
                return CommandOutput(status: 2, standardOutput: planOutput)
            }
            return CommandOutput(status: 0, standardOutput: destroyOutput)
        })
    }

    @Test("the plan names what would be destroyed")
    func planNamesTheDamage() async throws {
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            deployer: deployer(planOutput: "Plan: 0 to add, 0 to change, 1 to destroy."))

        let response = await api.handle(
            post("/api/stack/destroy/plan", ["stack": "mwlab-3"]))

        #expect(response.status == 200)
        let plan = try decoded(response)
        #expect(plan["stack"] as? String == "mwlab-3")
        #expect(plan["noop"] as? Bool == false)
        #expect((plan["headline"] as? String ?? "").contains("1 to destroy"))
        let services = try #require(plan["services"] as? [[String: Any]])
        #expect(services.first?["name"] as? String == "mwlab-3")
    }

    @Test("an unknown stack is a 404, not an empty plan")
    func planUnknownStack() async throws {
        let api = HatcheryAPI(loadManifest: { StackManifest(stacks: [self.stack()]) })
        let response = await api.handle(
            post("/api/stack/destroy/plan", ["stack": "nope"]))
        #expect(response.status == 404)
    }

    @Test("a mismatched confirmation destroys nothing")
    func confirmMismatch() async throws {
        let saved = Saved()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            saveManifest: { manifest, _ in saved.record(manifest) })
        let response = await api.handle(
            post("/api/stack/destroy", ["stack": "mwlab-3", "confirm": "mwlab"]))
        #expect(response.status == 400)
        #expect(saved.all().isEmpty)
    }

    @Test("production destroys stay on the CLI")
    func refusesProduction() async throws {
        let saved = Saved()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack(environment: .prod)]) },
            saveManifest: { manifest, _ in saved.record(manifest) })
        let response = await api.handle(
            post("/api/stack/destroy", ["stack": "mwlab-3", "confirm": "mwlab-3"]))
        #expect(response.status == 403)
        #expect(saved.all().isEmpty)
    }

    @Test("destroy tears down, forgets the stack, and seals")
    func destroys() async throws {
        let saved = Saved()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            saveManifest: { manifest, _ in saved.record(manifest) },
            manifestPath: { "/infra/hatchery.json" },
            deployer: deployer(
                planOutput: "Plan: 0 to add, 0 to change, 1 to destroy.",
                destroyOutput: "Destroy complete! Resources: 1 destroyed."),
            sealState: { _ in "sealed secrets in /infra" })

        let response = await api.handle(
            post("/api/stack/destroy", ["stack": "mwlab-3", "confirm": "mwlab-3"]))

        #expect(response.status == 200)
        let result = try decoded(response)
        #expect(result["ok"] as? Bool == true)
        let detail = result["detail"] as? String ?? ""
        #expect(detail.contains("Resources: 1 destroyed"))
        #expect(detail.contains("left in place"))
        #expect(detail.contains("sealed secrets"))
        // The manifest written back no longer declares the stack.
        #expect(saved.all().last?.stack(named: "mwlab-3") == nil)
    }

    private final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var manifests: [StackManifest] = []
        func record(_ manifest: StackManifest) {
            lock.lock()
            manifests.append(manifest)
            lock.unlock()
        }
        func all() -> [StackManifest] {
            lock.lock()
            defer { lock.unlock() }
            return manifests
        }
    }
}

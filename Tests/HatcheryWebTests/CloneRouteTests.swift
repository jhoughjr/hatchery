import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

/// The dashboard's clone goes through the same planner and the same guards as the CLI —
/// these prove the routes, with every read and write injected so nothing shells out.
struct CloneRouteTests {
    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: [String: String]] = [:]
        func record(_ path: String, _ values: [String: String]) {
            lock.lock()
            files[path] = values
            lock.unlock()
        }
        func all() -> [String: [String: String]] {
            lock.lock()
            defer { lock.unlock() }
            return files
        }
    }

    private func stack() -> StackSpec {
        StackSpec(
            name: "mwlab",
            backend: .dokku,
            environment: .dev,
            host: "dokku@192.168.0.103",
            tofu: TofuBinding(directory: "/infra/mwserver-tf"),
            services: [
                ServiceSpec(
                    name: "mwlab", kind: .mwserver, image: "mwserver2:arm64-abc",
                    domains: ["mwlab.opi"], configFile: "mwlab.config.json",
                    imageVariable: "mwlab_image")
            ])
    }

    private func post(_ path: String, _ object: [String: Any]) -> WebRequest {
        WebRequest(
            method: "POST", path: path, query: [:], headers: [:],
            body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func planner(
        config: [String: String]
    ) -> StackClonePlanner {
        StackClonePlanner(readLive: { _, _ in config })
    }

    private func decoded(_ response: WebResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    @Test("the plan classifies keys and never sends a secret value")
    func planClassifies() async throws {
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            manifestPath: { "/infra/hatchery.json" },
            clonePlanner: planner(config: [
                "DATABASE_URL": "postgres://mwlab-postgres/mwlab",
                "LOG_LEVEL": "debug",
            ]))

        let response = await api.handle(
            post("/api/stack/clone/plan", ["source": "mwlab", "target": "mwlab-2"]))

        #expect(response.status == 200)
        let plan = try decoded(response)
        #expect(plan["target"] as? String == "mwlab-2")
        let services = try #require(plan["services"] as? [[String: Any]])
        let keys = try #require(services.first?["keys"] as? [[String: Any]])

        func entry(_ name: String) -> [String: Any]? {
            keys.first { $0["key"] as? String == name }
        }
        // The database points at something only the source's environment has.
        #expect(entry("DATABASE_URL")?["action"] as? String == "needs")
        // The signing key is minted: carrying it would grant the source's authority — and
        // minted or not, its value must not be in the payload.
        #expect(entry("KEYPAIR_JWKS")?["action"] as? String == "mint")
        #expect(entry("KEYPAIR_JWKS")?["value"] == nil)
        // An optional the source sets rides along, value visible because it is not secret.
        #expect(entry("LOG_LEVEL")?["action"] as? String == "carry")
        #expect(entry("LOG_LEVEL")?["value"] as? String == "debug")
    }

    @Test("a source that does not exist is a 404, not an empty plan")
    func planUnknownSource() async throws {
        let api = HatcheryAPI(loadManifest: { StackManifest(stacks: [self.stack()]) })
        let response = await api.handle(
            post("/api/stack/clone/plan", ["source": "nope", "target": "nope-2"]))
        #expect(response.status == 404)
    }

    @Test("a target that already exists is refused before any planning")
    func planExistingTarget() async throws {
        let api = HatcheryAPI(loadManifest: { StackManifest(stacks: [self.stack()]) })
        let response = await api.handle(
            post("/api/stack/clone/plan", ["source": "mwlab", "target": "mwlab"]))
        #expect(response.status == 400)
    }

    @Test("a full tofu directory is a warning on the plan, not a refusal after create")
    func planWarnsAboutAFullDirectory() async throws {
        // What shipped first: the plan looked fine, and the create click was refused with
        // "already holds a tofu configuration" — a whole trip through the wizard, wasted.
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            manifestPath: { "/infra/hatchery.json" },
            bootstrapper: StackBootstrapper(
                execute: { _, _ in CommandOutput(status: 0, standardOutput: "") },
                writeFile: { _, _ in },
                fileExists: { _ in true },
                createDirectory: { _ in }),
            clonePlanner: planner(config: [:]))

        let response = await api.handle(
            post("/api/stack/clone/plan", [
                "source": "mwlab", "target": "mwlab-2", "tofuDir": "/infra",
            ]))

        #expect(response.status == 200)
        let plan = try decoded(response)
        let warning = try #require(plan["warning"] as? String)
        #expect(warning.contains("already holds"))
    }

    @Test("create into a full directory refuses before anything is written")
    func createRefusesAFullDirectory() async throws {
        let written = Written()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            manifestPath: { "/infra/hatchery.json" },
            bootstrapper: StackBootstrapper(
                execute: { _, _ in CommandOutput(status: 0, standardOutput: "") },
                writeFile: { _, _ in },
                fileExists: { _ in true },
                createDirectory: { _ in }),
            clonePlanner: planner(config: [:]),
            writeConfig: { url, values in written.record(url.path, values) })

        let response = await api.handle(
            post("/api/stack/clone", [
                "source": "mwlab", "target": "mwlab-2", "tofuDir": "/infra",
                "confirm": "mwlab-2",
            ]))

        #expect(response.status == 400)
        let message = String(decoding: response.body, as: UTF8.self)
        #expect(message.contains("already holds"))
        #expect(written.all().isEmpty)
    }

    @Test("create refuses a mismatched confirmation and writes nothing")
    func createConfirmMismatch() async throws {
        let written = Written()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            writeConfig: { url, values in written.record(url.path, values) })
        let response = await api.handle(
            post("/api/stack/clone", [
                "source": "mwlab", "target": "mwlab-2", "tofuDir": "/infra/mwlab-2-tf",
                "confirm": "mwlab",
            ]))
        #expect(response.status == 400)
        #expect(written.all().isEmpty)
    }

    @Test("create needs a tofu directory for the clone's declarations")
    func createNeedsTofuDir() async throws {
        let api = HatcheryAPI(loadManifest: { StackManifest(stacks: [self.stack()]) })
        let response = await api.handle(
            post("/api/stack/clone", [
                "source": "mwlab", "target": "mwlab-2", "tofuDir": "",
                "confirm": "mwlab-2",
            ]))
        #expect(response.status == 400)
    }

    @Test("create bootstraps, scaffolds, layers the carried values, and lists what is missing")
    func createBuildsTheClone() async throws {
        let written = Written()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            saveManifest: { _, _ in },
            manifestPath: { "/infra/hatchery.json" },
            scaffolder: Scaffolder(
                readFile: { _ in "" },
                writeFile: { _, _ in },
                fileExists: { _ in false }),
            bootstrapper: StackBootstrapper(
                execute: { _, _ in CommandOutput(status: 0, standardOutput: "ok") },
                writeFile: { _, _ in },
                fileExists: { _ in false },
                createDirectory: { _ in }),
            clonePlanner: planner(config: [
                "DATABASE_URL": "postgres://mwlab-postgres/mwlab",
                "LOG_LEVEL": "debug",
            ]),
            readConfig: { _ in [:] },
            writeConfig: { url, values in written.record(url.path, values) },
            sealState: { _ in "sealed secrets in /infra" })

        let response = await api.handle(
            post("/api/stack/clone", [
                "source": "mwlab", "target": "mwlab-2", "tofuDir": "/infra/mwlab-2-tf",
                "environment": "staging", "confirm": "mwlab-2",
            ]))

        #expect(response.status == 200)
        let result = try decoded(response)
        #expect((result["message"] as? String ?? "").contains("mwlab-2"))
        #expect(result["detail"] as? String == "sealed secrets in /infra")

        let services = try #require(result["services"] as? [[String: Any]])
        let cloned = try #require(services.first)
        #expect(cloned["name"] as? String == "mwlab")
        let missing = try #require(cloned["missing"] as? [[String: Any]])
        #expect(missing.contains { $0["key"] as? String == "DATABASE_URL" })

        // The carried value landed in the clone's own config file, under its tofu directory.
        let landed = written.all().first { $0.value["LOG_LEVEL"] == "debug" }
        #expect(landed != nil)
        #expect(landed?.key.contains("mwlab-2-tf") == true)
    }
}

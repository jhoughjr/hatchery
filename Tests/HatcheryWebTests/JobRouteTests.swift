import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

/// The watchable apply: a job id immediately, the narration by polling — with the stream
/// injected so no test runs tofu.
struct JobRouteTests {
    private func stack(environment: Environment = .dev) -> StackSpec {
        StackSpec(
            name: "mwlab-2",
            backend: .dokku,
            environment: environment,
            host: "dokku@192.168.0.103",
            tofu: TofuBinding(directory: "/infra/mwlab-2"),
            services: [])
    }

    private func post(_ path: String, _ object: [String: Any]) -> WebRequest {
        WebRequest(
            method: "POST", path: path, query: [:], headers: [:],
            body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func decoded(_ response: WebResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    @Test("an apply job narrates and finishes, and polling reads it incrementally")
    func narratesTheApply() async throws {
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            stream: { argv, directory, onLine in
                #expect(argv.contains("apply"))
                #expect(directory == "/infra/mwlab-2")
                onLine("dokku_app.mwlab_2: Creating...")
                onLine("")
                onLine("Apply complete! Resources: 3 added.")
                return 0
            })

        let started = await api.handle(
            post("/api/jobs/apply", ["stack": "mwlab-2", "confirm": "mwlab-2"]))
        #expect(started.status == 200)
        let id = try #require(try decoded(started)["job"] as? String)

        // The job runs detached; poll until it settles rather than sleeping and hoping.
        var state = "running"
        var lines: [String] = []
        var from = 0
        for _ in 0..<100 where state == "running" {
            let poll = await api.handle(
                WebRequest(method: "GET", path: "/api/jobs", query: ["id": id, "from": "\(from)"]))
            let snapshot = try decoded(poll)
            lines += (snapshot["lines"] as? [String]) ?? []
            from = snapshot["next"] as? Int ?? from
            state = snapshot["state"] as? String ?? "running"
            if state == "running" { try await Task.sleep(for: .milliseconds(10)) }
        }

        #expect(state == "ok")
        #expect(lines.first?.contains("tofu apply in /infra/mwlab-2") == true)
        #expect(lines.contains { $0.contains("Creating...") })
        // Blank narration lines are dropped; the padding is for terminals.
        #expect(!lines.contains(""))
        #expect(lines.last == "apply complete")
    }

    @Test("a failing apply finishes the job as failed, with the exit status")
    func failureIsNamed() async throws {
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            stream: { _, _, onLine in
                onLine("Error: something broke")
                return 1
            })

        let started = await api.handle(
            post("/api/jobs/apply", ["stack": "mwlab-2", "confirm": "mwlab-2"]))
        let id = try #require(try decoded(started)["job"] as? String)

        var state = "running"
        var lines: [String] = []
        for _ in 0..<100 where state == "running" {
            let poll = await api.handle(
                WebRequest(method: "GET", path: "/api/jobs", query: ["id": id, "from": "0"]))
            let snapshot = try decoded(poll)
            lines = (snapshot["lines"] as? [String]) ?? []
            state = snapshot["state"] as? String ?? "running"
            if state == "running" { try await Task.sleep(for: .milliseconds(10)) }
        }

        #expect(state == "failed")
        #expect(lines.contains { $0.contains("apply failed (exit 1)") })
    }

    @Test("a destroy job narrates the teardown, forgets the stack, and purges when asked")
    func destroyJob() async throws {
        let removed = Removed()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            saveManifest: { _, _ in },
            manifestPath: { "/infra/hatchery.json" },
            removeDirectory: { removed.record($0) },
            stream: { argv, _, onLine in
                #expect(argv.contains("destroy"))
                onLine("dokku_app.mwlab_2: Destroying...")
                return 0
            },
            sealState: { _ in "sealed secrets in /infra" })

        let started = await api.handle(
            post("/api/jobs/destroy", ["stack": "mwlab-2", "confirm": "mwlab-2", "purge": true]))
        #expect(started.status == 200)
        let id = try #require(try decoded(started)["job"] as? String)

        var state = "running"
        var lines: [String] = []
        for _ in 0..<100 where state == "running" {
            let poll = await api.handle(
                WebRequest(method: "GET", path: "/api/jobs", query: ["id": id, "from": "0"]))
            let snapshot = try decoded(poll)
            lines = (snapshot["lines"] as? [String]) ?? []
            state = snapshot["state"] as? String ?? "running"
            if state == "running" { try await Task.sleep(for: .milliseconds(10)) }
        }

        #expect(state == "ok")
        #expect(lines.contains { $0.contains("Destroying...") })
        #expect(lines.contains { $0.contains("removed 'mwlab-2' from the manifest") })
        #expect(lines.contains { $0.contains("deleted /infra/mwlab-2") })
        #expect(lines.contains { $0.contains("sealed secrets") })
        #expect(removed.all() == ["/infra/mwlab-2"])
    }

    private final class Removed: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }
        func all() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    @Test("production applies stay on the CLI, jobs included")
    func refusesProduction() async throws {
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack(environment: .prod)]) },
            stream: { _, _, _ in
                Issue.record("the stream must never start for production")
                return 1
            })
        let response = await api.handle(
            post("/api/jobs/apply", ["stack": "mwlab-2", "confirm": "mwlab-2"]))
        #expect(response.status == 403)
    }

    @Test("an unknown job is a 404, not an empty transcript")
    func unknownJob() async throws {
        let api = HatcheryAPI(loadManifest: { StackManifest() })
        let response = await api.handle(
            WebRequest(method: "GET", path: "/api/jobs", query: ["id": "nope", "from": "0"]))
        #expect(response.status == 404)
    }
}

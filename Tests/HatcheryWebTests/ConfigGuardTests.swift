import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

/// The editor renders fields from the contract, but the API accepts whatever the request
/// carries — so the refusal has to live behind the route, not in the form.
struct ConfigGuardTests {
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        func total() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private func stack() -> StackSpec {
        StackSpec(
            name: "mwlab",
            backend: .dokku,
            host: "dokku@192.168.0.103",
            tofu: TofuBinding(directory: "/infra/mwserver-tf"),
            services: [
                ServiceSpec(
                    name: "mwlab", kind: .mwserver, image: "mwserver2:arm64-abc",
                    domains: ["mwlab.opi"], configFile: "mwlab.config.json")
            ])
    }

    private func post(_ path: String, _ object: [String: Any]) -> WebRequest {
        WebRequest(
            method: "POST", path: path, query: [:], headers: [:],
            body: try! JSONSerialization.data(withJSONObject: object))
    }

    @Test func aTypoIsRefusedAndNothingIsWritten() async throws {
        let writes = Writes()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            readConfig: { _ in [:] },
            writeConfig: { _, _ in writes.record() })

        let response = await api.handle(
            post("/api/config/set", [
                "stack": "mwlab", "service": "mwlab",
                "values": ["DATABSE_URL": "postgres://oops"],
                "confirm": "mwlab",
            ]))

        #expect(response.status == 400)
        let message = String(decoding: response.body, as: UTF8.self)
        #expect(message.contains("DATABSE_URL"))
        #expect(message.contains("DATABASE_URL"))
        #expect(writes.total() == 0)
    }

    @Test func removingAnUnknownKeyStillWorks() async throws {
        let writes = Writes()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            readConfig: { _ in ["DATABSE_URL": "postgres://oops"] },
            writeConfig: { _, _ in writes.record() },
            sealState: { _ in nil })

        let response = await api.handle(
            post("/api/config/set", [
                "stack": "mwlab", "service": "mwlab",
                "values": ["DATABSE_URL": ""],
                "confirm": "mwlab",
            ]))

        #expect(response.status == 200)
        #expect(writes.total() == 1)
    }

    @Test func aKnownKeyStillWritesAndSeals() async throws {
        let writes = Writes()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            readConfig: { _ in [:] },
            writeConfig: { _, _ in writes.record() },
            sealState: { _ in "sealed" })

        let response = await api.handle(
            post("/api/config/set", [
                "stack": "mwlab", "service": "mwlab",
                "values": ["DATABASE_URL": "postgres://staging"],
                "confirm": "mwlab",
            ]))

        #expect(response.status == 200)
        #expect(writes.total() == 1)
    }

    @Test func theFallbackToDeclaredSaysWhy() async throws {
        // A live read that throws lands the editor on the declared file; the response says
        // what actually happened instead of implying the box was down.
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            liveConfig: LiveConfigReader(run: { _ in
                throw CommandFailure(command: "ssh", status: 255, message: "connection refused")
            }),
            readConfig: { _ in ["DATABASE_URL": "postgres://x"] })

        let response = await api.handle(
            WebRequest(
                method: "GET", path: "/api/config",
                query: ["stack": "mwlab", "service": "mwlab"], headers: [:], body: Data()))

        #expect(response.status == 200)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(decoded["source"] as? String == "declared")
        let note = try #require(decoded["note"] as? String)
        #expect(note.contains("connection refused"))
    }
}

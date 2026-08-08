import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

/// The history route serves what the watcher recorded; these prove the translation and the
/// limit handling without a watcher, a file, or a socket.
struct HistoryRouteTests {
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var limits: [Int] = []
        func record(_ limit: Int) {
            lock.lock()
            limits.append(limit)
            lock.unlock()
        }
        func all() -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            return limits
        }
    }

    private func get(_ path: String, query: [String: String] = [:]) -> WebRequest {
        WebRequest(method: "GET", path: path, query: query, headers: [:], body: Data())
    }

    @Test func eventsComeBackComposedForThePage() async throws {
        let transition = HealthTransition(
            at: Date(timeIntervalSince1970: 0), stack: "mwlab", service: "api",
            from: .ready, to: .degraded, gained: ["1 migration pending"])
        let api = HatcheryAPI(
            loadManifest: { StackManifest() },
            history: { _ in [transition] })

        let response = await api.handle(get("/api/history"))
        #expect(response.status == 200)

        let decoded = try #require(
            try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
        #expect(decoded.count == 1)
        #expect(decoded[0]["at"] as? String == "1970-01-01T00:00:00Z")
        #expect(decoded[0]["from"] as? String == "ready")
        #expect(decoded[0]["to"] as? String == "degraded")
        #expect(decoded[0]["worsened"] as? Bool == true)
        #expect(decoded[0]["line"] as? String == "mwlab/api: ready → degraded (+ 1 migration pending)")
    }

    @Test func theLimitIsPassedThroughAndCapped() async {
        let asked = Asked()
        let api = HatcheryAPI(
            loadManifest: { StackManifest() },
            history: { limit in
                asked.record(limit)
                return []
            })

        _ = await api.handle(get("/api/history"))
        _ = await api.handle(get("/api/history", query: ["limit": "5"]))
        _ = await api.handle(get("/api/history", query: ["limit": "9999"]))
        _ = await api.handle(get("/api/history", query: ["limit": "0"]))
        #expect(asked.all() == [100, 5, 500, 1])
    }

    @Test func historyIsBehindTheTokenLikeEveryOtherRoute() async {
        let api = HatcheryAPI(
            loadManifest: { StackManifest() },
            history: { _ in [] },
            token: "sekrit")
        let denied = await api.handle(get("/api/history"))
        #expect(denied.status == 401)
    }
}

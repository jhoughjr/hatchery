import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

/// The rotation a page asks for: a job id at once, the rotation's own lines by polling, with the stream injected so
/// no test rotates anything.
/// Serialized, because two of the tests name the manifests through the process environment.
@Suite(.serialized)
struct RotateRouteTests {
    private func post(_ object: [String: Any], token: String? = "t") -> WebRequest {
        WebRequest(
            method: "POST", path: "/api/jobs/rotate", query: [:], headers: token.map { ["x-hatchery-token": $0] } ?? [:],
            body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func decoded(_ response: WebResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func settle(_ api: HatcheryAPI, _ id: String) async throws -> (state: String, lines: [String]) {
        var state = "running"
        var lines: [String] = []
        var from = 0
        for _ in 0..<200 where state == "running" {
            let poll = await api.handle(
                WebRequest(method: "GET", path: "/api/jobs", query: ["id": id, "from": "\(from)"], headers: ["x-hatchery-token": "t"]))
            let snapshot = try decoded(poll)
            lines += (snapshot["lines"] as? [String]) ?? []
            from = snapshot["next"] as? Int ?? from
            state = snapshot["state"] as? String ?? "running"
            if state == "running" { try await Task.sleep(for: .milliseconds(10)) }
        }
        return (state, lines)
    }

    @Test("a rotation runs the rotate verb with --yes over the named manifests, then publishes the ledger")
    func rotates() async throws {
        let seen = Seen()
        setenv("HATCHERY_ROTATE_MANIFESTS", "/state/estate/hatchery.json:/state/air/hatchery.json", 1)
        defer { unsetenv("HATCHERY_ROTATE_MANIFESTS") }
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: []) },
            stream: { argv, _, onLine in
                seen.add(argv)
                if argv.contains("rotate") {
                    onLine("  NODE_KEY")
                    onLine("    done     issue: hatchery mints a value")
                    onLine("")
                }
                return 0
            },
            token: "t")

        let started = await api.handle(post(["target": "estate/pulse", "key": "NODE_KEY", "confirm": "estate/pulse NODE_KEY"]))
        #expect(started.status == 200)
        let id = try #require(try decoded(started)["job"] as? String)
        let (state, lines) = try await settle(api, id)

        #expect(state == "ok")
        #expect(lines.first == "rotate estate/pulse NODE_KEY")
        #expect(lines.contains("done     issue: hatchery mints a value"))
        #expect(lines.suffix(2) == ["the ledger is on pulse", "rotation complete"])
        let calls = seen.all
        #expect(calls.count == 2)
        #expect(Array(calls[0].dropFirst().prefix(5)) == ["secrets", "rotate", "estate/pulse", "NODE_KEY", "--yes"])
        #expect(calls[0].suffix(4) == ["-m", "/state/estate/hatchery.json", "-m", "/state/air/hatchery.json"])
        #expect(Array(calls[1].dropFirst().prefix(3)) == ["secrets", "ledger", "--publish"])
    }

    @Test("a rotation that stops finishes the job as failed and publishes nothing")
    func stops() async throws {
        let seen = Seen()
        setenv("HATCHERY_ROTATE_MANIFESTS", "/state/estate/hatchery.json", 1)
        defer { unsetenv("HATCHERY_ROTATE_MANIFESTS") }
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: []) },
            stream: { argv, _, onLine in
                seen.add(argv)
                onLine("    FAILED   hold: the box did not answer")
                return 1
            },
            token: "t")
        let started = await api.handle(post(["target": "estate/pulse", "key": "NODE_KEY", "confirm": "estate/pulse NODE_KEY"]))
        let id = try #require(try decoded(started)["job"] as? String)
        let (state, lines) = try await settle(api, id)
        #expect(state == "failed")
        #expect(lines.last == "the rotation stopped (exit 1)")
        #expect(seen.all.count == 1)
    }

    @Test("it takes the token, a matching confirmation and well-shaped names, and a serve with no token rotates for nobody")
    func refusals() async throws {
        let quiet: LineStream.Runner = { _, _, _ in 0 }
        let api = HatcheryAPI(loadManifest: { StackManifest(stacks: []) }, stream: quiet, token: "t")
        let good = ["target": "estate/pulse", "key": "NODE_KEY", "confirm": "estate/pulse NODE_KEY"]
        #expect(await api.handle(post(good, token: nil)).status == 401)
        #expect(await api.handle(post(good, token: "wrong")).status == 401)
        #expect(await api.handle(post(["target": "estate/pulse", "key": "NODE_KEY", "confirm": "yes"])).status == 400)
        #expect(await api.handle(post(["target": "estate/pulse; rm", "key": "NODE_KEY", "confirm": "estate/pulse; rm NODE_KEY"])).status == 400)
        #expect(await api.handle(post(["target": "estate/pulse", "key": "--all", "confirm": "estate/pulse --all"])).status == 400)
        let open = HatcheryAPI(loadManifest: { StackManifest(stacks: []) }, stream: quiet)
        #expect(await open.handle(post(good, token: nil)).status == 403)
    }

    @Test("the manifests are the list the environment names, or the house's six where each exists")
    func manifests() {
        #expect(HatcheryAPI.rotationManifests(environment: ["HATCHERY_ROTATE_MANIFESTS": "/a.json:/b.json"]) == ["/a.json", "/b.json"])
        let house = HatcheryAPI.rotationManifests(environment: ["HOME": "/Users/j"], exists: { !$0.contains("/sites/") })
        #expect(house.first == "/Users/j/.config/hatchery/hatchery.json")
        #expect(house.contains("/Users/j/infra-state/estate/hatchery.json"))
        #expect(!house.contains { $0.contains("/sites/") })
        #expect(house.count == 5)
    }
}

/// What the injected stream was asked to run, in order.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ argv: [String]) { lock.lock(); calls.append(argv); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
}

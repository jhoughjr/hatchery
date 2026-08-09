import Foundation
import Testing

@testable import HatcheryKit

private func source() -> StackSpec {
    StackSpec(
        name: "mwlab",
        backend: .dokku,
        environment: .prod,
        host: "dokku@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/mwserver-tf"),
        services: [
            ServiceSpec(
                name: "mwlab", kind: .mwserver, image: "mwserver2:arm64-abc",
                domains: ["mwlab.opi"], configFile: "mwlab.config.json",
                imageVariable: "mwlab_image")
        ]
    )
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("The stack-level clone planner")
struct StackClonePlannerTests {
    private func plan(
        readLive: @escaping StackClonePlanner.LiveRead,
        readDeclared: @escaping StackClonePlanner.DeclaredRead = { _ in [:] }
    ) async throws -> PlannedClone {
        try await StackClonePlanner(readLive: readLive, readDeclared: readDeclared).plan(
            stack: source(), into: "mwlab-2", environment: .staging,
            manifestPath: "/infra/hatchery.json")
    }

    @Test("a plan from the box names the host it read")
    func liveOriginNamesTheHost() async throws {
        let planned = try await plan(readLive: { _, _ in ["LOG_LEVEL": "debug"] })
        // The address alone: `hostAddress` strips the SSH user, which is a login detail
        // rather than part of where the config lives.
        #expect(planned.origins["mwlab-2"] == "live config on 192.168.0.103")
    }

    @Test("a backend that cannot answer falls back without alarm")
    func expectedFallbackIsQuiet() async throws {
        // Not-implemented-yet is a fact about the backend, not a failure worth a warning.
        let planned = try await plan(
            readLive: { _, _ in throw LiveConfigError.unsupportedBackend(.dokku) })
        #expect(planned.origins["mwlab-2"] == "declared file")
    }

    @Test("an unexpected live failure is named, because the box may disagree")
    func unexpectedFallbackIsNamed() async throws {
        let planned = try await plan(
            readLive: { _, _ in
                throw CommandFailure(command: "ssh", status: 255, message: "connection refused")
            })
        let origin = try #require(planned.origins["mwlab-2"])
        #expect(origin.hasPrefix("declared file — live read failed"))
        #expect(origin.contains("the box may disagree"))
    }

    @Test("an unreachable database server is a warning on the plan, probed once per server")
    func warnsAboutTheDatabaseServer() async throws {
        let probes = Counter()
        let planned = try await StackClonePlanner(
            readLive: { _, _ in
                ["DATABASE_URL": "postgresql://mwserver:pw@mwstack-pg-dev:5432/mwserver"]
            },
            probe: { plan, _, _ in
                probes.increment()
                return "database server '\(plan.serverApp)' is not reachable"
            }
        ).plan(
            stack: source(), into: "mwlab-2", environment: .staging,
            manifestPath: "/infra/hatchery.json")

        // One warning naming the server; the environment rewrite of the server name itself
        // is the database planner's behaviour, covered in its own tests.
        #expect(planned.warnings.count == 1)
        #expect(planned.warnings.first?.contains("not reachable") == true)
        #expect(probes.value == 1)
    }

    @Test("the plan says every domain will resolve nowhere until exposure is chosen")
    func exposureSaysNowhere() async throws {
        let planned = try await plan(readLive: { _, _ in ["LOG_LEVEL": "debug"] })
        // One line per domain, honest about the missing front door.
        #expect(!planned.exposure.isEmpty)
        #expect(planned.exposure.allSatisfy { !$0.actionable })
        #expect(planned.exposure.first?.action.contains("exposure") == true)
        // The domains are the clone's, already rewritten.
        #expect(planned.exposure.contains { $0.domain == "mwlab-2.opi" })
    }

    @Test("a reachable server adds no warning")
    func quietWhenTheServerAnswers() async throws {
        let planned = try await StackClonePlanner(
            readLive: { _, _ in
                ["DATABASE_URL": "postgresql://mwserver:pw@mwstack-pg-dev:5432/mwserver"]
            },
            probe: { _, _, _ in nil }
        ).plan(
            stack: source(), into: "mwlab-2", environment: .staging,
            manifestPath: "/infra/hatchery.json")
        #expect(planned.warnings.isEmpty)
    }

    @Test("an unreadable sidecar refuses rather than planning from nothing")
    func unreadableSidecarRefuses() async throws {
        do {
            _ = try await plan(
                readLive: { _, _ in throw LiveConfigError.unsupportedBackend(.dokku) },
                readDeclared: { _ in
                    throw CocoaError(.fileReadNoSuchFile)
                })
            Issue.record("planning succeeded from a config nobody could read")
        } catch let error as StackClonePlanner.UnreadableConfig {
            #expect(error.service == "mwlab")
            #expect("\(error)".contains("cannot read mwlab's config"))
        }
    }

    @Test("domains travel through the rewrite, not a name substitution")
    func domainsAreRewritten() async throws {
        let planned = try await plan(readLive: { _, _ in [:] })
        #expect(planned.plan.services.first?.domains == ["mwlab-2.opi"])
    }
}

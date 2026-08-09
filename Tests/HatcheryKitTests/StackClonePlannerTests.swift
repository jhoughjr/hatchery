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

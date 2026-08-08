import Foundation
import Testing

@testable import HatcheryKit

private func sourceStack() -> StackSpec {
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
                baseURL: "https://mwlab.opi", healthPath: "/healthz",
                imageVariable: "mwlab_image"),
            ServiceSpec(
                name: "paylab", kind: .paymentGateway, image: "pay:arm64-def",
                domains: ["paylab.opi"], configFile: "paylab.config.json",
                imageVariable: "paylab_image"),
        ]
    )
}

@Suite("Cloning carries the whole shape, not just the required keys")
struct CloneHardeningTests {
    private func plan(
        service index: Int, config: [String: String]
    ) async throws -> ClonedService {
        let source = sourceStack()
        let service = source.services[index]
        return try await StackCloner().plan(
            service: service, from: source, into: "mwlab-2",
            environment: .staging, sourceConfig: config,
            domains: service.domains.map {
                StackCloner.rewrite($0, from: source, to: "mwlab-2", environment: .staging) ?? $0
            })
    }

    private func key(_ planned: ClonedService, _ name: String) -> ClonedKey? {
        planned.keys.first { $0.key == name }
    }

    @Test func anOptionalKeyTheSourceSetsIsCarried() async throws {
        let planned = try await plan(service: 1, config: ["LOG_LEVEL": "debug"])
        let carried = try #require(key(planned, "LOG_LEVEL"))
        #expect(carried.disposition == .carried)
        #expect(carried.required == false)
        #expect(planned.values["LOG_LEVEL"] == "debug")
    }

    @Test func anOptionalKeyTheSourceNeverSetIsNotMentioned() async throws {
        // Reporting every unset optional key would bury the report in noise; nothing is the
        // right amount of output for a key that was nothing on both sides.
        let planned = try await plan(service: 1, config: [:])
        #expect(key(planned, "LOG_LEVEL") == nil)
    }

    @Test func anOptionalKeyNamingTheSourceIsRewritten() async throws {
        let planned = try await plan(service: 1, config: ["APP_DOMAIN": "paylab.opi"])
        let rewritten = try #require(key(planned, "APP_DOMAIN"))
        #expect(rewritten.disposition == .rewritten(from: "paylab.opi", to: "mwlab-2-paylab.opi"))
        #expect(planned.values["APP_DOMAIN"] == "mwlab-2-paylab.opi")
    }

    @Test func aStripeKeyTheSourceSetsIsRefusedWithoutBlockingBoot() async throws {
        // The operator must learn staging needs its own Stripe keys — and must not be told
        // the stack cannot boot without them, because it can.
        let planned = try await plan(service: 1, config: ["STRIPE_API_KEY": "sk_live_x"])
        let refused = try #require(key(planned, "STRIPE_API_KEY"))
        #expect(refused.disposition.needsPerson)
        #expect(refused.required == false)
        #expect(planned.values["STRIPE_API_KEY"] == nil)
        #expect(!planned.unresolved.contains { $0.key == "STRIPE_API_KEY" })
    }

    @Test func aRequiredRefusalStillBlocksBoot() async throws {
        let planned = try await plan(service: 0, config: [:])
        #expect(planned.unresolved.contains { $0.required })
    }

    @Test func theServiceShapeTravels() async throws {
        let planned = try await plan(service: 0, config: [:])
        #expect(planned.baseURL == "https://mwlab-2.opi")
        #expect(planned.healthPath == "/healthz")
    }

    @Test func aServiceWithoutAShapeStaysWithoutOne() async throws {
        let planned = try await plan(service: 1, config: [:])
        #expect(planned.baseURL == nil)
        #expect(planned.healthPath == nil)
    }
}

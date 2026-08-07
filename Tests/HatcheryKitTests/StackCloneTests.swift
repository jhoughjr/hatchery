import Foundation
import Testing

@testable import HatcheryKit

private func prodStack() -> StackSpec {
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
                imageVariable: "mwlab_image"),
            ServiceSpec(
                name: "paylab", kind: .paymentGateway, image: "pay:arm64-def",
                domains: ["paylab.opi"], configFile: "paylab.config.json",
                imageVariable: "paylab_image"),
        ]
    )
}

private func disposition(_ service: ClonedService, _ key: String) -> CloneDisposition? {
    service.keys.first { $0.key == key }?.disposition
}

@Suite("Cloning a stack's configuration")
struct StackCloneTests {
    private func clone(config: [String: String]) async throws -> ClonedService {
        let source = prodStack()
        return try await StackCloner().plan(
            service: source.services[0], from: source, into: "mwlab-2",
            environment: .staging, sourceConfig: config, domains: ["mwlab-2.opi"])
    }

    /// The reason cloning exists: mwlab-2 was built by hand and shipped with nine required keys
    /// unset, every one of which was already sitting in mwlab.
    @Test("carries environment-agnostic values forward")
    func carriesValues() async throws {
        let service = try await clone(config: ["LOG_LEVEL": "debug", "DATABASE_LOG_LEVEL": "info"])

        #expect(disposition(service, "LOG_LEVEL") == .carried)
        #expect(service.values["LOG_LEVEL"] == "debug")
    }

    /// The dangerous one. Copying this points staging at production's database, and it does not
    /// fail — it works, which is worse.
    @Test("refuses to copy anything that points at the source's database")
    func refusesDatabaseURLs() async throws {
        let service = try await clone(
            config: [
                "DATABASE_URL": "postgres://user:pw@db/mwlab",
                "DATABASE_APP_URL": "postgres://app:pw@db/mwlab",
            ])

        for key in ["DATABASE_URL", "DATABASE_APP_URL"] {
            guard case .refused = disposition(service, key) else {
                Issue.record("\(key) must be refused, got \(String(describing: disposition(service, key)))")
                continue
            }
            #expect(service.values[key] == nil, "\(key) must not be written")
        }
        #expect(service.unresolved.contains { $0.key == "DATABASE_URL" })
    }

    /// Copying a gateway token does not fail either. It grants the clone the source's authority,
    /// which is exactly why it has to be regenerated rather than carried.
    @Test("regenerates credentials that would grant the source's authority")
    func regeneratesTokens() async throws {
        let service = try await clone(config: ["PAYMENT_GATEWAY_TOKEN": "prod-token-value"])

        guard case .minted = disposition(service, "PAYMENT_GATEWAY_TOKEN") else {
            Issue.record("expected a minted token, got \(String(describing: disposition(service, "PAYMENT_GATEWAY_TOKEN")))")
            return
        }
        // The point of regenerating is that the value differs from the source's.
        #expect(service.values["PAYMENT_GATEWAY_TOKEN"] != "prod-token-value")
        #expect(service.values["PAYMENT_GATEWAY_TOKEN"]?.isEmpty == false)
    }

    /// A signing key is shared *within* a stack so services accept each other's tokens — but
    /// carrying production's key into staging would let staging mint tokens production honours.
    @Test("mints a fresh signing key rather than sharing the source's")
    func mintsKeypair() async throws {
        let service = try await clone(config: ["KEYPAIR_JWKS": #"{"keys":[{"kid":"prod"}]}"#])

        guard case .minted(let how) = disposition(service, "KEYPAIR_JWKS") else {
            Issue.record("expected a minted keypair")
            return
        }
        #expect(how.contains("RSA"))
        #expect(service.values["KEYPAIR_JWKS"]?.contains("\"kid\":\"prod\"") != true)
    }

    @Test("rewrites values that name the source stack")
    func rewritesNames() async throws {
        let service = try await clone(config: ["PAYMENT_GATEWAY_URL": "https://paylab.opi"])

        guard case .rewritten(let from, let to) = disposition(service, "PAYMENT_GATEWAY_URL") else {
            Issue.record("expected a rewrite, got \(String(describing: disposition(service, "PAYMENT_GATEWAY_URL")))")
            return
        }
        #expect(from == "https://paylab.opi")
        // Both sides are reported so the substitution can be judged before anything is written.
        #expect(to == "https://mwlab-2-paylab.opi")
    }

    /// A key missing from the source is missing in the clone. Reporting it as carried would
    /// produce a clone that looks complete and will not boot.
    @Test("reports a key the source never had")
    func reportsMissingSource() async throws {
        let service = try await clone(config: [:])

        guard case .refused(let why) = disposition(service, "LOG_LEVEL") else {
            Issue.record("expected a refusal for a key absent from the source")
            return
        }
        #expect(why.contains("mwlab"))
    }

    /// An empty value is not a value — dokku rejects zero-length config outright.
    @Test("treats an empty source value as absent")
    func emptyIsAbsent() async throws {
        let service = try await clone(config: ["LOG_LEVEL": ""])
        #expect(disposition(service, "LOG_LEVEL")?.needsPerson == true)
    }

    @Test("marks secret keys so their values are never shown")
    func marksSecrets() async throws {
        let service = try await clone(config: ["LOG_LEVEL": "debug"])
        let secretKeys = service.keys.filter(\.secret).map(\.key)
        #expect(secretKeys.contains("KEYPAIR_JWKS"))
        #expect(!secretKeys.contains("LOG_LEVEL"))
    }
}

@Suite("Rewriting names inside values")
struct CloneRewriteTests {
    @Test("leaves values that mention nothing from the source alone")
    func untouched() {
        #expect(StackCloner.rewrite("debug", from: prodStack(), to: "mwlab-2") == nil)
        #expect(StackCloner.rewrite("https://example.com", from: prodStack(), to: "mwlab-2") == nil)
    }

    /// `mwlab` is a substring of `mwlab-2`, and the stack also has a service called `mwlab`.
    /// Substituting shortest-first would corrupt one into the other.
    @Test("substitutes the longest name first")
    func longestFirst() {
        let rewritten = StackCloner.rewrite("https://paylab.opi/mwlab", from: prodStack(), to: "mwlab-2")
        #expect(rewritten == "https://mwlab-2-paylab.opi/mwlab-2")
    }
}

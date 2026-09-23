import Foundation
import Testing

@testable import HatcheryKit

/// Two services, as `rotate --all` would read them from two manifests: one random key, one manual key, and
/// one key another service owns.
private func allFixtureTargets() throws -> [RotationTarget] {
    let alpha = try JSONDecoder().decode(
        KindFile.self,
        from: Data(
            """
            {
              "kind": "alpha",
              "environment": {
                "ALPHA_TOKEN": {
                  "secret": true,
                  "rotation": { "issuer": { "type": "random", "bytes": 32 }, "holders": [] }
                }
              }
            }
            """.utf8))
    let beta = try JSONDecoder().decode(
        KindFile.self,
        from: Data(
            """
            {
              "kind": "beta",
              "environment": {
                "BETA_TOKEN": {
                  "secret": true,
                  "rotation": { "issuer": { "type": "manual", "recipe": "ask ops" }, "holders": [] }
                },
                "SHARED_KEY": {
                  "secret": true,
                  "rotation": { "owner": "vault/vault" }
                }
              }
            }
            """.utf8))

    return [
        RotationTarget(
            stack: "estate", service: "alpha", kind: alpha, dokkuTargets: [:], adminTargets: [:],
            secretsURL: URL(fileURLWithPath: "/tmp/rotation-run-tests-alpha.secrets.json")),
        RotationTarget(
            stack: "estate", service: "beta", kind: beta, dokkuTargets: [:], adminTargets: [:],
            secretsURL: URL(fileURLWithPath: "/tmp/rotation-run-tests-beta.secrets.json")),
    ]
}

/// An executor that touches no vault and no disk, so `--all` is driven purely in memory.
private func stubExecutor(_ target: RotationTarget) -> RotationExecutor {
    RotationExecutor(
        vault: VaultAdmin(credential: .session("")),
        secrets: SecretsFile(read: { [:] }, write: { _ in }))
}

@Suite("rotate --all, across every service a set of manifests declares")
struct RotationRunTests {
    @Test("a kind shared by two services plans its rotation only for the service that carries the key")
    func sharedKindPlansOnlyWhereTheKeyIs() async throws {
        let alpha = try allFixtureTargets()[0]
        let serve = RotationTarget(
            stack: "air", service: "hatchery-serve", kind: alpha.kind, dokkuTargets: [:], adminTargets: [:],
            secretsURL: alpha.secretsURL, carried: ["ALPHA_TOKEN"])
        let report = RotationTarget(
            stack: "air", service: "node-report", kind: alpha.kind, dokkuTargets: [:], adminTargets: [:],
            secretsURL: alpha.secretsURL, carried: [])

        let (lines, outcomes) = await RotationRun.all(
            targets: [serve, report], apps: [], hosts: [], dryRun: true, yes: false, makeExecutor: stubExecutor)

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.service == "hatchery-serve")
        #expect(outcomes.first?.state == .dry)
        #expect(!lines.contains { $0.contains("node-report") })
    }

    @Test("a random key runs, a manual key is refused, and an owned key is skipped, one table line each")
    func allProducesOneLinePerKeyOutcome() async throws {
        let targets = try allFixtureTargets()

        let (lines, outcomes) = await RotationRun.all(
            targets: targets, apps: [], hosts: [], dryRun: false, yes: true, makeExecutor: stubExecutor)

        #expect(outcomes.map(\.state) == [.run, .refused, .skipped])
        #expect(lines.contains("  estate/alpha ALPHA_TOKEN  run"))
        #expect(lines.contains("  estate/beta BETA_TOKEN  refused"))
        #expect(lines.contains("  estate/beta SHARED_KEY  skipped"))
        #expect(lines.contains(where: { $0.contains("held from vault/vault") }))
        #expect(lines.contains(where: { $0.contains("ask ops") }))
    }

    @Test("--dry-run prints every plan and builds no executor, and every key reads dry")
    func dryRunTouchesNothing() async throws {
        let targets = try allFixtureTargets()

        let (lines, outcomes) = await RotationRun.all(
            targets: targets, apps: [], hosts: [], dryRun: true, yes: true,
            makeExecutor: { _ in
                Issue.record("--dry-run must not build an executor")
                return stubExecutor(targets[0])
            })

        #expect(outcomes.map(\.state) == [.dry, .refused, .skipped])
        #expect(lines.contains("    issues   hatchery mints 32 random bytes"))
    }

    @Test("a failed key is reported as failed, and the exit status a caller reads is non-zero")
    func aFailedKeyIsFailed() async throws {
        struct Boom: Error {}
        let targets = try allFixtureTargets()

        let (_, outcomes) = await RotationRun.all(
            targets: [targets[0]], apps: [], hosts: [], dryRun: false, yes: true,
            makeExecutor: { _ in
                RotationExecutor(
                    vault: VaultAdmin(credential: .session("")),
                    secrets: SecretsFile(
                        read: { [:] },
                        write: { _ in throw Boom() }))
            })

        #expect(outcomes.map(\.state) == [.failed])
        #expect(outcomes.contains { $0.state == .failed })
    }
}

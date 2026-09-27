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

/// What a stub was asked, in order, safe to read from a test after the run.
private final class Probed: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String]] = []
    func add(_ argv: [String]) { self.lock.withLock { self.seen.append(argv) } }
    var lines: [String] { self.lock.withLock { self.seen.map { $0.joined(separator: " ") } } }
    /// The host of each ssh probe, which is the argument before its command word.
    var hosts: [String] { self.lock.withLock { self.seen.compactMap { $0.count >= 2 ? $0[$0.count - 2] : nil } } }
}

/// An executor that touches no vault and no disk, so `--all` is driven purely in memory.
private func stubExecutor(_ target: RotationTarget) -> RotationExecutor {
    RotationExecutor(
        vault: VaultAdmin(credential: .session("")),
        secrets: SecretsFile(read: { [:] }, write: { _ in }))
}

@Suite("rotate --all, across every service a set of manifests declares")
struct RotationRunTests {
    @Test("a silent host refuses the whole run before any issuer, and a dry run warns and still plans")
    func silentHostRefusesBeforeTheFirstMint() async throws {
        let kind = try JSONDecoder().decode(
            KindFile.self,
            from: Data(
                """
                {
                  "kind": "gamma",
                  "environment": {
                    "GAMMA_TOKEN": {
                      "secret": true,
                      "rotation": {
                        "issuer": { "type": "random", "bytes": 32 },
                        "holders": [
                          { "type": "dokkuConfig", "app": "gamma", "key": "GAMMA_TOKEN" },
                          { "type": "file", "host": "jimmy@mini", "path": "~/.gamma" },
                          { "type": "file", "host": "local", "path": "~/.gamma" }
                        ]
                      }
                    }
                  }
                }
                """.utf8))
        let target = RotationTarget(
            stack: "estate", service: "gamma", kind: kind, dokkuTargets: ["gamma": "dokku@box"], adminTargets: [:],
            secretsURL: URL(fileURLWithPath: "/tmp/rotation-run-tests-gamma.secrets.json"))
        let probed = Probed()
        let probe: CommandRunner = { argv in
            probed.add(argv)
            if argv.contains("jimmy@mini") { throw CommandFailure(command: "ssh", status: 255, message: "timed out") }
            return Data()
        }

        let refused = await RotationRun.all(
            targets: [target], apps: ["gamma"], hosts: ["jimmy@mini", "local"], dryRun: false, yes: true,
            makeExecutor: { _ in
                Issue.record("a silent host must stop the run before any executor is built")
                return stubExecutor(target)
            },
            probe: probe)
        #expect(refused.silent == ["jimmy@mini"])
        #expect(refused.outcomes.isEmpty)
        #expect(refused.lines.contains { $0.contains("jimmy@mini did not answer") })
        // The box and the mini were asked once each, and this machine was not asked at all.
        #expect(probed.hosts == ["dokku@box", "jimmy@mini"])

        let dry = await RotationRun.all(
            targets: [target], apps: ["gamma"], hosts: ["jimmy@mini", "local"], dryRun: true, yes: true,
            makeExecutor: stubExecutor, probe: probe)
        #expect(dry.silent == ["jimmy@mini"])
        #expect(dry.outcomes.map(\.state) == [.dry])
    }

    @Test("every line is said as it is made, in the order the run makes it")
    func linesStreamInOrder() async throws {
        let targets = try allFixtureTargets()
        let said = Probed()
        let run = await RotationRun.all(
            targets: targets, apps: [], hosts: [], dryRun: true, yes: true, makeExecutor: stubExecutor,
            say: { said.add([$0]) })
        #expect(said.lines == run.lines)
        #expect(said.lines.first?.contains("ALPHA_TOKEN") == true)
    }

    @Test("a kind shared by two services plans its rotation only for the service that carries the key")
    func sharedKindPlansOnlyWhereTheKeyIs() async throws {
        let alpha = try allFixtureTargets()[0]
        let serve = RotationTarget(
            stack: "air", service: "hatchery-serve", kind: alpha.kind, dokkuTargets: [:], adminTargets: [:],
            secretsURL: alpha.secretsURL, carried: ["ALPHA_TOKEN"])
        let report = RotationTarget(
            stack: "air", service: "node-report", kind: alpha.kind, dokkuTargets: [:], adminTargets: [:],
            secretsURL: alpha.secretsURL, carried: [])

        let run = await RotationRun.all(
            targets: [serve, report], apps: [], hosts: [], dryRun: true, yes: false, makeExecutor: stubExecutor)

        #expect(run.outcomes.count == 1)
        #expect(run.outcomes.first?.service == "hatchery-serve")
        #expect(run.outcomes.first?.state == .dry)
        #expect(!run.lines.contains { $0.contains("node-report") })
    }

    @Test("a random key runs, a manual key is refused, and an owned key is skipped, one table line each")
    func allProducesOneLinePerKeyOutcome() async throws {
        let targets = try allFixtureTargets()

        let run = await RotationRun.all(
            targets: targets, apps: [], hosts: [], dryRun: false, yes: true, makeExecutor: stubExecutor)

        #expect(run.outcomes.map(\.state) == [.run, .refused, .skipped])
        #expect(run.lines.contains("  estate/alpha ALPHA_TOKEN  run"))
        #expect(run.lines.contains("  estate/beta BETA_TOKEN  refused"))
        #expect(run.lines.contains("  estate/beta SHARED_KEY  skipped"))
        #expect(run.lines.contains(where: { $0.contains("held from vault/vault") }))
        #expect(run.lines.contains(where: { $0.contains("ask ops") }))
    }

    @Test("--dry-run prints every plan and builds no executor, and every key reads dry")
    func dryRunTouchesNothing() async throws {
        let targets = try allFixtureTargets()

        let run = await RotationRun.all(
            targets: targets, apps: [], hosts: [], dryRun: true, yes: true,
            makeExecutor: { _ in
                Issue.record("--dry-run must not build an executor")
                return stubExecutor(targets[0])
            })

        #expect(run.outcomes.map(\.state) == [.dry, .refused, .skipped])
        #expect(run.lines.contains("    issues   hatchery mints 32 random bytes"))
    }

    @Test("a failed key is reported as failed, and the exit status a caller reads is non-zero")
    func aFailedKeyIsFailed() async throws {
        struct Boom: Error {}
        let targets = try allFixtureTargets()

        let run = await RotationRun.all(
            targets: [targets[0]], apps: [], hosts: [], dryRun: false, yes: true,
            makeExecutor: { _ in
                RotationExecutor(
                    vault: VaultAdmin(credential: .session("")),
                    secrets: SecretsFile(
                        read: { [:] },
                        write: { _ in throw Boom() }))
            })

        #expect(run.outcomes.map(\.state) == [.failed])
        #expect(run.outcomes.contains { $0.state == .failed })
    }
}

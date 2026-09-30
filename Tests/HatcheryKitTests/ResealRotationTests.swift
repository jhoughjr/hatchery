import Foundation
import Testing

@testable import HatcheryKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Vault's session secret as the estate declares it after house#45: a sealing key issued by the re-seal route, held by vault and by pulse.
private let vaultKind = """
    {
      "kind": "vault",
      "environment": {
        "SESSION_SECRET": {
          "class": "sealingKey",
          "secret": true,
          "why": "vault re-seals every document under the new value, then vault and pulse take it and restart",
          "rotation": {
            "issuer": { "type": "vaultReseal" },
            "holders": [
              { "type": "dokkuConfig", "app": "vault", "key": "SESSION_SECRET", "restart": "stopStart" },
              { "type": "dokkuConfig", "app": "pulse", "key": "SESSION_SECRET", "restart": "stopStart" }
            ]
          }
        }
      }
    }
    """

private func vaultPlan() throws -> RotationPlan {
    let kind = try JSONDecoder().decode(KindFile.self, from: Data(vaultKind.utf8))
    let plans = try RotationPlanner.plans(service: "vault", keys: ["SESSION_SECRET"], in: kind, apps: ["vault", "pulse"], hosts: [])
    return try #require(plans.first)
}

/// Vault, the box, and both secrets files in memory, with one log in the order things happened.
private final class Estate: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var files: [String: [String: String]] = [
        "vault": ["SESSION_SECRET": "old"],
        "pulse": ["SESSION_SECRET": "old", "NODE_KEY": "n"],
    ]
    private var checks = 0
    /// The reseal answer, and what the check after the restart answers on each read.
    private let resealStatus: Int
    private let checkAnswers: [(Int, [String: Any])]
    private let running: String

    init(resealStatus: Int = 200, checkAnswers: [(Int, [String: Any])]? = nil, running: String = "true") {
        self.resealStatus = resealStatus
        self.checkAnswers = checkAnswers ?? [(200, ["app_documents": 14, "s3_keys": 3, "failed": [String]()])]
        self.running = running
    }

    var happened: [String] { self.lock.withLock { self.log } }
    func file(_ app: String) -> [String: String] { self.lock.withLock { self.files[app] ?? [:] } }

    /// A command's input shows after a `<`, so a test reads what went on standard input apart from the arguments.
    func run(_ command: ShellCommand) -> Data {
        let input = command.standardInput.map { " < " + String(decoding: $0, as: UTF8.self) } ?? ""
        let line = command.argv.joined(separator: " ") + input
        self.lock.withLock { self.log.append("run " + line) }
        return line.contains("ps:report") ? Data((self.running + "\n").utf8) : Data()
    }

    func vault(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""
        self.lock.withLock { self.log.append("vault \(method) \(path)") }

        var status = 200
        var body: [String: Any]
        switch (method, path) {
        case ("GET", "/api/admin/whoami"):
            body = ["email": "boss@example.com", "via": "token", "token_name": "cli:hatchery"]

        case ("POST", "/api/admin/reseal"):
            let sent = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String]
            self.lock.withLock { self.log.append("vault took secret \(sent?["secret"] ?? "none")") }
            status = self.resealStatus
            body = status == 200
                ? ["ok": true, "app_documents": 14, "s3_keys": 3, "backup": "reseal-backups/20260930T120000Z"]
                : ["error": "the current secret does not open every sealed value, so nothing was written", "failed": ["gigs.secrets.json"]]

        case ("GET", "/api/admin/reseal"):
            let index = self.lock.withLock { () -> Int in
                defer { self.checks += 1 }
                return self.checks
            }
            let answer = self.checkAnswers[min(index, self.checkAnswers.count - 1)]
            status = answer.0
            body = answer.1

        default:
            status = 404
            body = ["error": "no such route"]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }

    func secretsFile(_ app: String) -> SecretsFile {
        SecretsFile(
            read: { self.lock.withLock { self.files[app] ?? [:] } },
            write: { values in
                self.lock.withLock {
                    self.files[app] = values
                    self.log.append("record \(app) " + values.keys.sorted().joined(separator: ","))
                }
            })
    }
}

private func makeExecutor(_ estate: Estate, pauses: PauseLog = PauseLog()) -> RotationExecutor {
    RotationExecutor(
        vault: VaultAdmin(credential: .session("cookie"), exchange: { try estate.vault($0) }),
        secrets: estate.secretsFile("vault"),
        dokkuTargets: ["vault": "dokku@opi", "pulse": "dokku@opi"],
        holderSecrets: ["vault": estate.secretsFile("vault"), "pulse": estate.secretsFile("pulse")],
        run: { estate.run($0) },
        mint: { _ in "minted-session-secret" },
        pause: { seconds in pauses.add(seconds) })
}

private final class PauseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: [Int] = []
    var all: [Int] { self.lock.withLock { self.seconds } }
    func add(_ value: Int) { self.lock.withLock { self.seconds.append(value) } }
}

@Suite("Vault's session secret, rotated through the re-seal route")
struct ResealRotationTests {
    // MARK: - The declaration and the plan

    @Test("the vaultReseal issuer decodes, fits a sealing key, and survives a round trip")
    func issuerRoundTrips() throws {
        let kind = try JSONDecoder().decode(KindFile.self, from: Data(vaultKind.utf8))
        let rotation = try #require(kind.rotation(forKey: "SESSION_SECRET"))

        #expect(rotation.issuer == .vaultReseal)
        #expect(rotation.issuer.typeName == "vaultReseal")
        #expect(SecretClass.sealingKey.fits(rotation.issuer))
        #expect(try JSONDecoder().decode(KindFile.self, from: try JSONEncoder().encode(kind)) == kind)
    }

    @Test("the plan runs the re-seal, then vault and pulse take the value, then both restart, then the check")
    func planPrintsTheRunInOrder() throws {
        let plan = try vaultPlan()

        #expect(plan.secretClass == .sealingKey)
        #expect(plan.lines() == [
            "  SESSION_SECRET",
            "    class    sealingKey",
            "    before   a re-seal route is declared, the operator token works, and every holder is running",
            "    runs     mint, re-seal every document under the value, every holder, every restart, then vault opens every document",
            "    issues   hatchery mints a value, and vault re-seals every app secrets document and S3 key under it",
            "    holds    SESSION_SECRET in the config of vault, stop then start",
            "    holds    SESSION_SECRET in the config of pulse, stop then start",
            "    restarts vault, stop then start",
            "    restarts pulse, stop then start",
            "    checks   vault opens every app secrets document and S3 key under the new value after its restart",
        ])
    }

    @Test("a sealing key with a manual issuer is still refused with its recipe")
    func manualSealingKeyIsRefused() throws {
        let manual = vaultKind.replacingOccurrences(
            of: #"{ "type": "vaultReseal" }"#, with: #"{ "type": "manual", "recipe": "re-seal by hand" }"#)
        let kind = try JSONDecoder().decode(KindFile.self, from: Data(manual.utf8))

        #expect(throws: RotationRefusal.noResealRoute(keys: ["SESSION_SECRET"], recipe: "re-seal by hand")) {
            try RotationPlanner.plans(service: "vault", keys: ["SESSION_SECRET"], in: kind, apps: ["vault", "pulse"], hosts: [])
        }
    }

    @Test("the preflight asks vault's health route before the mint")
    func preflightAsksVault() throws {
        let probes = RotationPreflight.probes(of: [(try vaultPlan(), ["vault": "dokku@opi", "pulse": "dokku@opi"], [:])],
                                              vault: "https://vault.example")

        #expect(probes.map(\.host) == ["vault at https://vault.example", "dokku@opi"])
    }

    @Test("the ledger puts a sealing key with the re-seal route up for rotation, and keeps the re-seal row for a manual one")
    func ledgerRowsFollowTheIssuer() throws {
        var state = LedgerState()
        let kind = try JSONDecoder().decode(KindFile.self, from: Data(vaultKind.utf8))
        let rows = SecretLedger.rows(for: [LedgerTarget(stack: "estate", service: "vault", kind: kind)], state: &state, today: Date())
        let row = try #require(rows.first)

        #expect(row.next == .rotate)
        #expect(row.listedForRotation)
        #expect(row.issuer == "vault")
        #expect(!SecretLedger.lines(for: rows).contains { $0.contains("no re-seal route declared") })
    }

    // MARK: - The run

    @Test("the run checks, mints, re-seals, records both files, sets both configs, restarts both, then reads the check")
    func runsInTheRuledOrder() async throws {
        let estate = Estate()

        let report = await makeExecutor(estate).execute(try vaultPlan())

        #expect(report.succeeded)
        #expect(estate.happened == [
            "vault GET /api/admin/whoami",
            "run ssh -o BatchMode=yes dokku@opi ps:report vault --running",
            "run ssh -o BatchMode=yes dokku@opi ps:report pulse --running",
            "vault POST /api/admin/reseal",
            "vault took secret minted-session-secret",
            "record vault SESSION_SECRET",
            "record pulse NODE_KEY,SESSION_SECRET",
            #"run ssh -o BatchMode=yes dokku@opi --quiet config:import --format=json --no-restart vault - < {"SESSION_SECRET":"minted-session-secret"}"#,
            #"run ssh -o BatchMode=yes dokku@opi --quiet config:import --format=json --no-restart pulse - < {"SESSION_SECRET":"minted-session-secret"}"#,
            "run ssh -o BatchMode=yes dokku@opi ps:stop vault",
            "run ssh -o BatchMode=yes dokku@opi ps:start vault",
            "run ssh -o BatchMode=yes dokku@opi ps:stop pulse",
            "run ssh -o BatchMode=yes dokku@opi ps:start pulse",
            "vault GET /api/admin/reseal",
        ])
        #expect(report.done.map(\.phase) == [.ready, .issue, .record, .record, .hold, .hold, .restart, .restart, .check])
        #expect(report.done[1].what.contains("re-sealed 14 app document(s) and 3 S3 key(s)"))
        #expect(report.done[1].what.contains("reseal-backups/20260930T120000Z"))
        #expect(estate.file("vault")["SESSION_SECRET"] == "minted-session-secret")
        #expect(estate.file("pulse") == ["SESSION_SECRET": "minted-session-secret", "NODE_KEY": "n"])
    }

    @Test("a re-seal vault refuses stops the run with the files named, and nothing is recorded or placed")
    func refusedResealStopsEverything() async throws {
        let estate = Estate(resealStatus: 409)

        let report = await makeExecutor(estate).execute(try vaultPlan())

        #expect(!report.succeeded)
        #expect(report.stopped?.phase == .issue)
        #expect(report.reason?.contains("gigs.secrets.json") == true)
        #expect(!estate.happened.contains { $0.hasPrefix("record") || $0.contains("config:import") || $0.contains("ps:stop") })
        #expect(estate.file("vault")["SESSION_SECRET"] == "old")
        #expect(estate.file("pulse")["SESSION_SECRET"] == "old")
    }

    @Test("a holder that is not running stops the run before the mint")
    func stoppedHolderStopsBeforeTheMint() async throws {
        let estate = Estate(running: "false")

        let report = await makeExecutor(estate).execute(try vaultPlan())

        #expect(report.stopped?.phase == .ready)
        #expect(report.reason?.contains("vault") == true)
        #expect(!estate.happened.contains("vault POST /api/admin/reseal"))
    }

    @Test("the check waits for the restarted vault, then accepts it")
    func checkWaitsForVault() async throws {
        let estate = Estate(checkAnswers: [
            (502, ["error": "bad gateway"]),
            (502, ["error": "bad gateway"]),
            (200, ["app_documents": 14, "s3_keys": 3, "failed": [String]()]),
        ])
        let pauses = PauseLog()

        let report = await makeExecutor(estate, pauses: pauses).execute(try vaultPlan())

        #expect(report.succeeded)
        #expect(estate.happened.filter { $0 == "vault GET /api/admin/reseal" }.count == 3)
        #expect(pauses.all == [3, 3])
        #expect(report.done.last?.what == "vault opens 14 app document(s) and 3 S3 key(s) under the new value")
    }

    @Test("a restarted vault that does not open a document fails the check and names the backup to roll back from")
    func failedCheckNamesTheBackup() async throws {
        let estate = Estate(checkAnswers: [(200, ["app_documents": 13, "s3_keys": 3, "failed": ["gigs.secrets.json"]])])

        let report = await makeExecutor(estate).execute(try vaultPlan())

        #expect(report.stopped?.phase == .check)
        #expect(report.reason?.contains("does not open gigs.secrets.json") == true)
        #expect(report.reason?.contains("reseal-backups/20260930T120000Z") == true)
        // The holders already took the value, so the report names every step that ran.
        #expect(report.done.map(\.phase) == [.ready, .issue, .record, .record, .hold, .hold, .restart, .restart])
    }
}

@Suite("A step that stops after the re-seal says the way back")
struct AfterResealTests {
    @Test("a reason with no re-seal is unchanged")
    func noReseal() {
        #expect(RotationExecutor.afterReseal("the holder refused", resealed: nil) == "the holder refused")
    }

    @Test("a reason after the re-seal names the backup and both ways back")
    func afterReseal() {
        // given a re-seal that kept the old set
        let count = VaultResealCount(appDocuments: 4, s3Keys: 3, backup: "reseal-backups/20260930T120000Z")

        // when a later step stops
        let reason = RotationExecutor.afterReseal("config:set failed", resealed: count)

        // then the reason keeps the error and says where the old set is and how to recover
        #expect(reason.hasPrefix("config:set failed"))
        #expect(reason.contains("reseal-backups/20260930T120000Z"))
        #expect(reason.contains("set the new value from vault's secrets file"))
        #expect(reason.contains("copy the old set back"))
    }
}

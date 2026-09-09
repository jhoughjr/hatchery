import Foundation
import Testing

@testable import HatcheryKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The box, vault, and the secrets file, all in memory, with one log of everything in the order it happened.
///
/// One log rather than three is the point of the suite. The declaration's rule is an order: the issuer, then
/// the record, then the config, then the restart. Three separate logs could not show that the order was kept.
///
/// This is a lock rather than an actor because ``SecretsFile`` takes synchronous closures, matching Foundation's
/// file APIs. Nothing here opens a file or a socket.
private final class Estate: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var file: [String: String]
    private var minted = 0
    /// The command that fails, by the word that identifies it. Nothing fails when it is empty.
    private let failing: String

    init(file: [String: String] = [:], failing: String = "") {
        self.file = file
        self.failing = failing
    }

    var happened: [String] { self.lock.withLock { self.log } }
    var secrets: [String: String] { self.lock.withLock { self.file } }

    /// Every command lands here as one line, so a test reads the run as a story.
    func run(_ argv: [String]) throws -> Data {
        let line = argv.joined(separator: " ")
        self.lock.withLock { self.log.append("run " + line) }
        if !self.failing.isEmpty, line.contains(self.failing) {
            throw CommandFailure(command: argv.first ?? "", status: 1, message: "the box refused it")
        }
        return Data()
    }

    /// Vault answers each minted value once, the way the real routes do.
    func vault(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""
        self.lock.withLock { self.log.append("vault \(method) \(path)") }

        let body: [String: Any]
        switch path {
        case "/api/admin/apps/rookery/key":
            body = ["ok": true, "app_key": "new-app-key"]

        case "/api/admin/apps/forgejo/s3key":
            body = ["ok": true, "access_key_id": "new-id", "secret_access_key": "new-secret"]

        case "/api/admin/apps/hatchery/secrets":
            body = ["ok": true, "names": ["HATCHERY_SERVE_TOKEN"]]

        default:
            body = ["error": "no such route"]
        }
        let status = body["error"] == nil ? 200 : 404
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }

    func read() -> [String: String] { self.lock.withLock { self.file } }

    func write(_ values: [String: String]) {
        self.lock.withLock {
            self.file = values
            self.log.append("record " + values.keys.sorted().joined(separator: ","))
        }
    }

    /// A predictable value per call, so an assertion names it.
    func mint(_ bytes: Int) -> String {
        self.lock.withLock {
            self.minted += 1
            return "minted-\(self.minted)"
        }
    }
}

private func makeExecutor(_ estate: Estate) -> RotationExecutor {
    RotationExecutor(
        vault: VaultAdmin(session: "cookie", exchange: { try estate.vault($0) }),
        secrets: SecretsFile(read: { estate.read() }, write: { estate.write($0) }),
        dokkuTargets: ["rookery": "dokku@opi", "coop": "dokku@opi", "forgejo": "dokku@opi"],
        adminTargets: ["rookery-pg": "jimmy@opi"],
        run: { try estate.run($0) },
        mint: { estate.mint($0) })
}

private func rookeryPlan(_ key: String) throws -> RotationPlan {
    let kind = try recordedKind("rookery.kind.json")
    return RotationPlan(
        service: "rookery", keys: [key], rotation: try #require(kind.rotation(forKey: key)))
}

@Suite("Running a rotation in the ruled order")
struct RotationExecutorTests {
    @Test("vault mints the app key once, it reaches the secrets file, then the config, then the restart")
    func vaultAppKeyRunsInOrder() async throws {
        let estate = Estate()

        let report = await makeExecutor(estate).execute(try rookeryPlan("VAULT_APP_KEY"))

        #expect(report.succeeded)
        #expect(
            estate.happened == [
                "vault POST /api/admin/apps/rookery/key",
                "record VAULT_APP_KEY",
                "run ssh -o BatchMode=yes dokku@opi config:set rookery VAULT_APP_KEY=new-app-key",
            ])
        #expect(estate.secrets["VAULT_APP_KEY"] == "new-app-key")
    }

    @Test("the secrets file holds the new value before the first config:set, so a crash between them loses nothing")
    func theRecordComesBeforeAnyHolder() async throws {
        let estate = Estate()

        _ = await makeExecutor(estate).execute(try rookeryPlan("ROOKERY_TOKEN"))

        let record = try #require(estate.happened.firstIndex(where: { $0.hasPrefix("record") }))
        let firstSet = try #require(estate.happened.firstIndex(where: { $0.contains("config:set") }))
        #expect(record < firstSet)
        #expect(estate.secrets["ROOKERY_TOKEN"] == "minted-1")
    }

    @Test("the shared bearer reaches both holders, rookery first and the coop second")
    func bothHoldersTakeTheSharedValue() async throws {
        let estate = Estate()

        let report = await makeExecutor(estate).execute(try rookeryPlan("ROOKERY_TOKEN"))

        #expect(report.succeeded)
        #expect(
            estate.happened == [
                "record ROOKERY_TOKEN",
                "run ssh -o BatchMode=yes dokku@opi config:set rookery ROOKERY_TOKEN=minted-1",
                "run ssh -o BatchMode=yes dokku@opi config:set coop ROOKERY_TOKEN=minted-1",
            ])
    }

    @Test("ALTER ROLE runs first, and the new password goes back inside the URL the secrets file held")
    func databasePasswordIsRewrittenIntoTheURL() async throws {
        let estate = Estate(
            file: ["DATABASE_URL": "postgresql://rookery:oldpass@rookery-pg:5432/rookery"])

        let report = await makeExecutor(estate).execute(try rookeryPlan("DATABASE_URL"))

        #expect(report.succeeded)
        #expect(estate.happened[0].contains("ssh -o BatchMode=yes jimmy@opi docker exec rookery-pg psql"))
        #expect(estate.happened[0].contains("ALTER ROLE"))
        #expect(estate.happened[1] == "record DATABASE_URL")
        #expect(
            estate.secrets["DATABASE_URL"]
                == "postgresql://rookery:minted-1@rookery-pg:5432/rookery")
    }

    @Test("a failed config:set stops the run and the report names what already ran")
    func aFailedHolderStopsTheRun() async throws {
        let estate = Estate(failing: "config:set coop")

        let report = await makeExecutor(estate).execute(try rookeryPlan("ROOKERY_TOKEN"))

        #expect(!report.succeeded)
        #expect(report.done.map(\.phase) == [.issue, .record, .hold])
        #expect(report.stopped?.what == "ROOKERY_TOKEN in the config of coop, rolling deploy")
        #expect(report.reason?.contains("the box refused it") == true)
        // The value is live and rookery has it, so the report must say so rather than read as a clean failure.
        #expect(estate.secrets["ROOKERY_TOKEN"] == "minted-1")
        #expect(report.lines().contains("    FAILED   hold: ROOKERY_TOKEN in the config of coop, rolling deploy"))
        #expect(
            report.lines().contains(
                "    The steps above ran. Finish the rest by hand, then seal the state."))
    }

    @Test("a vault route that refuses stops the run before anything is written")
    func aRefusedIssuerWritesNothing() async throws {
        let estate = Estate()
        let plan = RotationPlan(
            service: "unknown-app",
            keys: ["VAULT_APP_KEY"],
            rotation: KindFile.Rotation(issuer: .vaultAppKey, holders: []))

        let report = await makeExecutor(estate).execute(plan)

        #expect(!report.succeeded)
        #expect(report.done.isEmpty)
        #expect(estate.secrets.isEmpty)
    }

    @Test("the forge's pair is minted once, and the two halves land on the keys their names claim")
    func theS3PairLandsByName() async throws {
        let estate = Estate()
        let kind = try recordedKind("forgejo.kind.json")
        let plan = RotationPlan(
            service: "forgejo",
            keys: [
                "FORGEJO__storage__MINIO_ACCESS_KEY_ID",
                "FORGEJO__storage__MINIO_SECRET_ACCESS_KEY",
            ],
            rotation: try #require(kind.rotation(forKey: "FORGEJO__storage__MINIO_ACCESS_KEY_ID")))

        let report = await makeExecutor(estate).execute(plan)

        #expect(report.succeeded)
        #expect(estate.secrets["FORGEJO__storage__MINIO_ACCESS_KEY_ID"] == "new-id")
        #expect(estate.secrets["FORGEJO__storage__MINIO_SECRET_ACCESS_KEY"] == "new-secret")
        #expect(estate.happened.filter { $0.contains("s3key") }.count == 1)
    }

    @Test("a stop-then-start holder sets its config without a restart, and stops and starts afterwards")
    func stopStartSeparatesTheConfigFromTheRestart() async throws {
        let estate = Estate()
        let kind = try recordedKind("forgejo.kind.json")
        let plan = RotationPlan(
            service: "forgejo",
            keys: [
                "FORGEJO__storage__MINIO_ACCESS_KEY_ID",
                "FORGEJO__storage__MINIO_SECRET_ACCESS_KEY",
            ],
            rotation: try #require(kind.rotation(forKey: "FORGEJO__storage__MINIO_ACCESS_KEY_ID")))

        _ = await makeExecutor(estate).execute(plan)

        #expect(estate.happened.allSatisfy { !$0.contains("ps:restart") })
        #expect(estate.happened.filter { $0.contains("config:set --no-restart") }.count == 2)
        let stop = try #require(estate.happened.firstIndex(where: { $0.contains("ps:stop") }))
        let lastSet = try #require(estate.happened.lastIndex(where: { $0.contains("config:set") }))
        #expect(lastSet < stop)
        #expect(estate.happened.last == "run ssh -o BatchMode=yes dokku@opi ps:start forgejo")
    }
}

@Suite("The pieces a rotation is built from")
struct RotationCommandTests {
    @Test("ALTER ROLE goes through the same docker exec channel db provision uses")
    func alterRoleUsesTheProvisioningChannel() {
        #expect(
            RotationExecutor.alterRoleCommand(
                server: "rookery-pg", role: "rookery", password: "abc", on: "local")
                == [
                    "docker", "exec", "rookery-pg", "psql", "-U", "postgres", "-v",
                    "ON_ERROR_STOP=1", "-Atc",
                    "ALTER ROLE \"rookery\" WITH LOGIN PASSWORD 'abc'",
                ])
    }

    @Test("a new password replaces the old one and leaves the rest of the URL alone")
    func passwordReplacementKeepsTheURL() {
        #expect(
            RotationExecutor.replacingPassword(
                in: "postgresql://user:old@box:5432/db", with: "new")
                == "postgresql://user:new@box:5432/db")
        #expect(RotationExecutor.replacingPassword(in: "postgresql://box/db", with: "new") == nil)
        #expect(RotationExecutor.replacingPassword(in: "not-a-url", with: "new") == nil)
    }

    @Test("the S3 half named SECRET takes the secret, whatever order the keys arrive in")
    func s3HalvesLandByName() throws {
        let pair = (accessKeyID: "id", secretAccessKey: "secret")
        let keys = ["FORGEJO__storage__MINIO_SECRET_ACCESS_KEY", "FORGEJO__storage__MINIO_ACCESS_KEY_ID"]

        #expect(
            try RotationExecutor.s3Values(pair, keys: keys) == [
                "FORGEJO__storage__MINIO_ACCESS_KEY_ID": "id",
                "FORGEJO__storage__MINIO_SECRET_ACCESS_KEY": "secret",
            ])
        #expect(throws: RotationExecutorError.notAPair(keys: ["ONE"])) {
            try RotationExecutor.s3Values(pair, keys: ["ONE"])
        }
    }

    @Test("the roostrc rewrite keeps every other line and moves the new file into place")
    func roostrcRewriteIsAtomic() {
        let script = RotationExecutor.roostrcScript(key: "ROOST_HATCHERY_TOKEN", value: "abc")

        #expect(script.contains("grep -v '^ROOST_HATCHERY_TOKEN='"))
        #expect(script.hasSuffix("mv \"$f.rotating\" \"$f\""))
    }

    @Test("a launchd holder sets the plist key and bootstraps the agent again")
    func launchdHolderSetsAndBootstraps() throws {
        let holder = KindFile.Holder.launchdEnvironment(
            host: "mini", label: "net.jimmyhoughjr.serve", key: "TOKEN")
        let plan = RotationPlan(
            service: "serve", keys: ["TOKEN"],
            rotation: KindFile.Rotation(issuer: .random(bytes: 32), holders: [holder]))

        let write = try RotationExecutor.writeCommands(
            holder, plan: plan, values: ["TOKEN": "abc"], dokkuTargets: [:])
        let restart = try RotationExecutor.restartCommands(holder, dokkuTargets: [:])

        #expect(write[0].last?.contains("PlistBuddy") == true)
        #expect(write[0].last?.contains("Set :EnvironmentVariables:TOKEN abc") == true)
        #expect(restart[0].last?.contains("launchctl bootstrap gui/$(id -u)") == true)
    }

    @Test("a systemd holder writes hatchery's own drop-in rather than the unit the installer owns")
    func systemdHolderWritesADropIn() throws {
        let holder = KindFile.Holder.systemdEnvironment(
            host: "opi", unit: "roost-node.service", key: "TOKEN")
        let plan = RotationPlan(
            service: "node", keys: ["TOKEN"],
            rotation: KindFile.Rotation(issuer: .random(bytes: 32), holders: [holder]))

        let write = try RotationExecutor.writeCommands(
            holder, plan: plan, values: ["TOKEN": "abc"], dokkuTargets: [:])
        let restart = try RotationExecutor.restartCommands(holder, dokkuTargets: [:])

        #expect(write[0].last?.contains("roost-node.service.d/rotation.conf") == true)
        #expect(write[0].last?.contains("systemctl --user daemon-reload") == true)
        #expect(restart[0].last?.contains("systemctl --user restart roost-node.service") == true)
    }

    @Test("a vault-reading holder writes nothing, because vault already holds the value")
    func vaultReadingHolderWritesNothing() throws {
        let holder = KindFile.Holder.vaultSecret(app: "hatchery", name: "TOKEN")
        let plan = RotationPlan(
            service: "hatchery-serve", keys: ["TOKEN"],
            rotation: KindFile.Rotation(issuer: .random(bytes: 32), holders: [holder]))

        #expect(
            try RotationExecutor.writeCommands(
                holder, plan: plan, values: ["TOKEN": "abc"], dokkuTargets: [:]).isEmpty)
        #expect(throws: RotationExecutorError.unknownRestart(app: "hatchery")) {
            try RotationExecutor.restartCommands(holder, dokkuTargets: [:])
        }
    }

    @Test("a holder that renames the value takes the plan's one value")
    func aRenamedHolderTakesTheOneValue() throws {
        let plan = RotationPlan(
            service: "hatchery-serve", keys: ["HATCHERY_SERVE_TOKEN"],
            rotation: KindFile.Rotation(issuer: .random(bytes: 32), holders: []))

        #expect(
            try RotationExecutor.value(
                for: "ROOST_HATCHERY_TOKEN", plan: plan, values: ["HATCHERY_SERVE_TOKEN": "abc"])
                == "abc")
    }
}

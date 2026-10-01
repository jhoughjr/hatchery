import Foundation
import Testing

@testable import HatcheryKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A made-up forge token: forty lower-case hex digits, the shape the forge's CLI prints.
private let mintedToken = String(repeating: "0a", count: 20)

/// The forge's box, vault, the forge's API and the secrets file, all in memory, with one log of everything in the order it happened.
private final class Forge: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var file: [String: String]
    private let answer: String
    private let failing: String
    private let takes: Bool

    init(file: [String: String] = [:], answer: String = mintedToken + "\n", failing: String = "", takes: Bool = true) {
        self.file = file
        self.answer = answer
        self.failing = failing
        self.takes = takes
    }

    var happened: [String] { self.lock.withLock { self.log } }
    var secrets: [String: String] { self.lock.withLock { self.file } }

    /// The box: the CLI prints the token on standard output for a mint, and nothing for a retire.
    func run(_ command: ShellCommand) throws -> Data {
        let input = command.standardInput.map { " < " + String(decoding: $0, as: UTF8.self) } ?? ""
        let line = command.argv.joined(separator: " ") + input
        self.lock.withLock { self.log.append("run " + line) }
        if !self.failing.isEmpty, line.contains(self.failing) {
            throw CommandFailure(command: command.argv.first ?? "", status: 1, message: "no token of that name")
        }
        return command.argv.contains("generate-access-token") ? Data(self.answer.utf8) : Data()
    }

    func vault(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let path = request.url?.path ?? ""
        self.lock.withLock { self.log.append("vault \(request.httpMethod ?? "") \(path) \(body)") }
        let names = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])?.keys.sorted() ?? []
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: ["ok": true, "names": names]), response)
    }

    func accepts(_ token: String) -> Bool {
        self.lock.withLock { self.log.append("check \(token)") }
        return self.takes
    }

    func repos(_ name: String, _ value: String) -> [String] {
        self.lock.withLock { self.log.append("repos \(name) \(value)") }
        return ["jimmy/rookery", "jimmy/vault-hb"]
    }

    func read() -> [String: String] { self.lock.withLock { self.file } }

    func write(_ values: [String: String]) {
        self.lock.withLock {
            self.file = values
            self.log.append("record " + values.keys.sorted().joined(separator: ","))
        }
    }
}

private func makeExecutor(_ forge: Forge) -> RotationExecutor {
    RotationExecutor(
        vault: VaultAdmin(session: "cookie", exchange: { try forge.vault($0) }),
        secrets: SecretsFile(read: { forge.read() }, write: { forge.write($0) }),
        dokkuTargets: ["coop": "dokku@opi"],
        run: { try forge.run($0) },
        forgeAccepts: { forge.accepts($0) },
        forgeRepos: { forge.repos($0, $1) })
}

private func forgePlan(_ key: String) throws -> RotationPlan {
    let kind = try recordedKind("forge-tokens.kind.json")
    return RotationPlan(service: "forgejo", keys: [key], rotation: try #require(kind.rotation(forKey: key)), in: kind)
}

@Suite("The forgeToken issuer")
struct ForgeTokenIssuerTests {
    @Test("the CLI calls are the ones forge-token makes, over ssh to the opi, and no argument carries a value")
    func commandsMatchForgeToken() {
        let retire = ForgeTokenIssuer.retireCommand(name: "house-read")
        let mint = ForgeTokenIssuer.mintCommand(name: "house-read", scopes: "read:issue")

        #expect(retire.argv.prefix(6) == ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "jimmy@opi.jimmyhoughjr.net"])
        #expect(
            Array(retire.argv.dropFirst(6)) == [
                "docker", "exec", "-u", "git", "forgejo.web.1", "forgejo", "--config", "/data/gitea/conf/app.ini",
                "admin", "user", "delete-access-token", "--username", "jimmy", "--token-name", "house-read",
            ])
        #expect(
            Array(mint.argv.dropFirst(16)) == [
                "generate-access-token", "--username", "jimmy", "--token-name", "house-read", "--scopes", "read:issue", "--raw",
            ])
        #expect(retire.standardInput == nil)
        #expect(mint.standardInput == nil)
    }

    @Test("a local box runs the CLI with no ssh hop")
    func localBoxHasNoHop() {
        #expect(ForgeTokenIssuer.mintCommand(name: "n", scopes: "read:issue", on: "local").argv.first == "docker")
    }

    @Test("the token is the last line of standard output, and only forty lower-case hex digits read as one")
    func tokenParsing() {
        #expect(ForgeTokenIssuer.token(in: Data("\(mintedToken)\n".utf8)) == mintedToken)
        #expect(ForgeTokenIssuer.token(in: Data("a warning\n\(mintedToken)\n".utf8)) == mintedToken)
        #expect(ForgeTokenIssuer.token(in: Data("Access token was successfully created\n".utf8)) == nil)
        #expect(ForgeTokenIssuer.token(in: Data(mintedToken.uppercased().utf8)) == nil)
        #expect(ForgeTokenIssuer.token(in: Data()) == nil)
    }

    @Test("a name or scope list with a character the box's shell reads fails to decode")
    func unsafeNameIsRefused() {
        let json = #"{ "type": "forgeToken", "name": "house read; rm", "scopes": "read:issue" }"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(KindFile.Issuer.self, from: Data(json.utf8)) }
    }

    @Test("the issuer round-trips, and retires is left out when it is empty")
    func issuerRoundTrips() throws {
        let issuer = KindFile.Issuer.forgeToken(name: "house-read", scopes: "read:issue", retires: ["rookery-read"])
        let decoded = try JSONDecoder().decode(KindFile.Issuer.self, from: try JSONEncoder().encode(issuer))
        #expect(decoded == issuer)

        let bare = String(decoding: try JSONEncoder().encode(KindFile.Issuer.forgeToken(name: "n", scopes: "s", retires: [])), as: UTF8.self)
        #expect(!bare.contains("retires"))
    }

    @Test("the run retires every earlier name before the mint, then records, places, checks, and reports the revoke as a fact")
    func retireBeforeMint() async throws {
        let forge = Forge()

        let report = await makeExecutor(forge).execute(try forgePlan("FORGE_READ_TOKEN"))

        #expect(report.succeeded)
        let happened = forge.happened
        let retireHouse = try #require(happened.firstIndex { $0.contains("delete-access-token") && $0.hasSuffix("house-read") })
        let retireRookery = try #require(happened.firstIndex { $0.contains("delete-access-token") && $0.hasSuffix("rookery-read") })
        let mint = try #require(happened.firstIndex { $0.contains("generate-access-token") })
        let record = try #require(happened.firstIndex { $0.hasPrefix("record ") })
        let check = try #require(happened.firstIndex { $0.hasPrefix("check ") })
        #expect(retireHouse < mint && retireRookery < mint)
        #expect(mint < record && record < check)
        #expect(happened.filter { $0.hasPrefix("vault PUT") }.count == 2)
        #expect(report.done.map(\.phase) == [.issue, .record, .hold, .hold, .check, .revoke])
        #expect(forge.secrets["FORGE_READ_TOKEN"] == mintedToken)
    }

    @Test("the new token is captured from standard output and reaches no command line; the holders take it in a request body")
    func valueStaysOffArgv() async throws {
        let forge = Forge()

        let report = await makeExecutor(forge).execute(try forgePlan("FORGE_PACKAGE_TOKEN"))

        #expect(report.succeeded)
        #expect(!forge.happened.filter { $0.hasPrefix("run ") }.contains { $0.contains(mintedToken) })
        #expect(forge.happened.contains("vault PUT /api/admin/apps/forge/secrets {\"FORGE_PACKAGE_TOKEN\":\"\(mintedToken)\"}"))
        #expect(forge.happened.contains("repos FORGE_PACKAGE_TOKEN \(mintedToken)"))
        #expect(report.done.contains { $0.what.hasSuffix("jimmy/rookery, jimmy/vault-hb") })
        #expect(!report.lines().joined().contains(mintedToken))
    }

    @Test("a retire the forge refuses for a missing name does not stop the mint")
    func missingNameIsNothingToRetire() async throws {
        let forge = Forge(failing: "delete-access-token")

        let report = await makeExecutor(forge).execute(try forgePlan("FORGE_ISSUE_TOKEN"))

        #expect(report.succeeded)
    }

    @Test("an answer that is not a token stops the run at the issue, and its output is not quoted")
    func malformedAnswerStops() async throws {
        let forge = Forge(answer: "almost-a-token-\(mintedToken)\n")

        let report = await makeExecutor(forge).execute(try forgePlan("FORGE_ISSUE_TOKEN"))

        #expect(report.stopped?.phase == .issue)
        #expect(report.reason?.contains("not a forge token") == true)
        #expect(!report.lines().joined().contains(mintedToken))
        #expect(!forge.happened.contains { $0.hasPrefix("vault ") })
    }

    @Test("a token the forge refuses stops the run at the check, after the holders, and names the token")
    func refusedTokenStopsAtTheCheck() async throws {
        let forge = Forge(takes: false)

        let report = await makeExecutor(forge).execute(try forgePlan("FORGE_ISSUE_TOKEN"))

        #expect(report.stopped?.phase == .check)
        #expect(report.done.map(\.phase) == [.issue, .record, .hold])
        #expect(report.reason?.contains("house-issue") == true)
    }

    @Test("the coop's token goes to its dokku config on standard input")
    func coopTokenOnStandardInput() async throws {
        let plan = RotationPlan(
            service: "coop",
            keys: ["FORGE_TOKEN"],
            rotation: KindFile.Rotation(
                issuer: .forgeToken(name: "coop-runs", scopes: "read:repository", retires: []),
                holders: [.dokkuConfig(app: "coop", key: "FORGE_TOKEN", restart: .rolling)]),
            secretClass: .token)
        let forge = Forge()

        let report = await makeExecutor(forge).execute(plan)

        #expect(report.succeeded)
        let place = try #require(forge.happened.first { $0.contains("config:import") })
        #expect(place.hasSuffix("coop - < {\"FORGE_TOKEN\":\"\(mintedToken)\"}"))
    }

    @Test("the preflight asks the forge's box before the mint, and the forge's API for a repository holder")
    func preflightAsksTheBox() throws {
        let plan = try forgePlan("FORGE_PACKAGE_TOKEN")

        let probes = RotationPreflight.probes(of: [(plan, [:], [:])], vault: "https://vault.example")

        #expect(probes.map(\.host) == ["jimmy@opi.jimmyhoughjr.net", "vault at https://vault.example", "the forge at https://forgejo.jimmyhoughjr.net"])
        #expect(probes[2].command.last == "https://forgejo.jimmyhoughjr.net/api/v1/version")
    }
}

@Suite("The forge kind")
struct ForgeKindTests {
    @Test("it declares the three vault-held forge tokens, each a token issued by the forge's CLI")
    func declaresTheThreeTokens() throws {
        let kind = try recordedKind("forge-tokens.kind.json")

        #expect(kind.rotatableKeys() == ["FORGE_ISSUE_TOKEN", "FORGE_PACKAGE_TOKEN", "FORGE_READ_TOKEN"])
        for key in kind.rotatableKeys() {
            #expect(kind.environment[key]?.secretClass == .token)
            guard case .forgeToken? = kind.rotation(forKey: key)?.issuer else {
                Issue.record("\(key) is not issued by the forge")
                continue
            }
        }
        #expect(kind.keysHeldOutsideFiles() == ["FORGE_ISSUE_TOKEN", "FORGE_PACKAGE_TOKEN", "FORGE_READ_TOKEN"])
    }

    @Test("the registry and the ledger read a kind beside the real manifest through a symlink, and list the keys no service file names")
    func ledgerReadsThroughASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-kind-\(UUID().uuidString)")
        let real = root.appendingPathComponent("infra-state/mwserver-tf")
        let link = root.appendingPathComponent("config/hatchery")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("kinds"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = #"""
            {"version": 1, "stacks": [{"name": "forge", "backend": "dokku", "host": "dokku@box", "services": [
              {"name": "forgejo", "kind": "forgejo", "image": "codeberg.org/forgejo/forgejo:15", "domains": [], "configFile": "forgejo.config.json"}
            ]}]}
            """#
        try Data(manifest.utf8).write(to: real.appendingPathComponent("hatchery.json"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/forge-tokens.kind.json")
        try FileManager.default.copyItem(at: fixture, to: real.appendingPathComponent("kinds/forgejo.json"))
        let linked = link.appendingPathComponent("hatchery.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real.appendingPathComponent("hatchery.json"))

        let loaded = try ManifestLocator.load(linked.path)
        let targets = try SecretLedger.targets(in: [loaded])
        var state = LedgerState()
        let rows = SecretLedger.rows(for: targets, state: &state, today: Date())

        #expect(rows.map(\.key) == ["FORGE_ISSUE_TOKEN", "FORGE_PACKAGE_TOKEN", "FORGE_READ_TOKEN"])
        #expect(rows.allSatisfy { $0.issuer == "forge" && $0.next == .rotate })
        let stack = loaded.manifest.stacks[0]
        let secrets = try #require(
            ConfigSync.secretsURL(
                for: stack.services[0],
                in: stack,
                manifestPath: linked.path))
        #expect(secrets.path.hasSuffix("infra-state/mwserver-tf/forgejo.secrets.json"))
    }
}

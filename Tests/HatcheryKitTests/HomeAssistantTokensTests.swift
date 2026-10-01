import Foundation
import Testing

@testable import HatcheryKit

/// Home Assistant, the box and the secrets file in memory, with one log of everything in the order it happened.
///
/// Home Assistant answers by which token signed in: the old token sees itself as current, and the new token sees the old one beside it.
private final class Home: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var file: [String: String]
    private let oldType: String
    private var renamed: Bool

    init(file: [String: String] = ["GIGS_HA_TOKEN": "old-ha-token"], oldType: String = "long_lived_access_token", renamed: Bool = false) {
        self.file = file
        self.oldType = oldType
        self.renamed = renamed
    }

    var happened: [String] { self.lock.withLock { self.log } }
    var secrets: [String: String] { self.lock.withLock { self.file } }

    func call(_ url: String, _ token: String, _ commands: [[String: JSONValue]]) throws -> [JSONValue] {
        try commands.map { command in
            guard case .string(let type)? = command["type"] else { throw HomeAssistantTokenError.unreadableList }
            self.lock.withLock { self.log.append("ha \(token) \(type)") }
            switch type {
            case "auth/refresh_tokens":
                // A rename shows only to the new token's read, so the mint still reads the old name.
                let oldName = self.lock.withLock { self.renamed } && token == "new-ha-token" ? "someone else" : "gigs"
                return .array([
                    .object(["id": .string("phone-id"), "client_name": .string("iPhone"), "token_type": .string("normal"), "is_current": .bool(false)]),
                    .object([
                        "id": .string("old-id"), "client_name": .string(oldName), "token_type": .string(self.oldType),
                        "is_current": .bool(token == "old-ha-token"),
                    ]),
                    .object([
                        "id": .string("new-id"), "client_name": .string("gigs 2026-10-01 12:00 UTC"),
                        "token_type": .string("long_lived_access_token"), "is_current": .bool(token == "new-ha-token"),
                    ]),
                ])

            case "auth/long_lived_access_token":
                guard command["client_name"] == .string("gigs 2026-10-01 12:00 UTC"), command["lifespan"] == .number(3650) else {
                    throw HomeAssistantTokenError.refused(command: type, reason: "unexpected fields")
                }
                return .string("new-ha-token")

            case "auth/current_user":
                return .object(["name": .string("jimmy")])

            case "auth/delete_refresh_token":
                guard case .string(let id)? = command["refresh_token_id"] else { throw HomeAssistantTokenError.unreadableList }
                self.lock.withLock { self.log.append("deleted \(id)") }
                return .null

            default:
                throw HomeAssistantTokenError.refused(command: type, reason: "unknown command")
            }
        }
    }

    func run(_ command: ShellCommand) throws -> Data {
        let input = command.standardInput.map { " < " + String(decoding: $0, as: UTF8.self) } ?? ""
        self.lock.withLock { self.log.append("run " + command.argv.joined(separator: " ") + input) }
        return Data()
    }

    func read() -> [String: String] { self.lock.withLock { self.file } }

    func write(_ values: [String: String]) {
        self.lock.withLock {
            self.file = values
            self.log.append("record " + values.keys.sorted().joined(separator: ","))
        }
    }
}

/// 2026-10-01 12:00 UTC, so the new token's name is fixed.
private let noon = Date(timeIntervalSince1970: 1_790_856_000)

private func makeExecutor(_ home: Home) -> RotationExecutor {
    RotationExecutor(
        vault: VaultAdmin(session: ""),
        secrets: SecretsFile(read: { home.read() }, write: { home.write($0) }),
        dokkuTargets: ["gigs": "dokku@opi"],
        run: { try home.run($0) },
        homeAssistant: { try home.call($0, $1, $2) },
        now: { noon })
}

private let gigsPlan = RotationPlan(
    service: "gigs",
    keys: ["GIGS_HA_TOKEN"],
    rotation: KindFile.Rotation(
        issuer: .homeAssistantToken(url: "http://192.168.0.103:8123", name: "gigs"),
        holders: [.dokkuConfig(app: "gigs", key: "GIGS_HA_TOKEN", restart: .rolling)]),
    secretClass: .token)

@Suite("The homeAssistantToken issuer")
struct HomeAssistantTokensTests {
    @Test("the new token's name carries the minute in UTC, so a second rotation never meets Home Assistant's one-name rule")
    func nameCarriesTheTime() {
        #expect(HomeAssistantTokens.clientName("gigs", at: noon) == "gigs 2026-10-01 12:00 UTC")
    }

    @Test("the run makes the new token with the old, places it, then checks and deletes the old token only after every holder has it")
    func deleteComesAfterTheHolders() async throws {
        let home = Home()

        let report = await makeExecutor(home).execute(gigsPlan)

        #expect(report.succeeded)
        #expect(
            home.happened == [
                "ha old-ha-token auth/refresh_tokens",
                "ha old-ha-token auth/long_lived_access_token",
                "record GIGS_HA_TOKEN",
                "run ssh -o BatchMode=yes dokku@opi --quiet config:import --format=json gigs - < {\"GIGS_HA_TOKEN\":\"new-ha-token\"}",
                "ha new-ha-token auth/current_user",
                "ha new-ha-token auth/refresh_tokens",
                "ha new-ha-token auth/delete_refresh_token",
                "deleted old-id",
            ])
        #expect(report.done.map(\.phase) == [.issue, .record, .hold, .restart, .check, .revoke])
        #expect(report.done.last?.what == "Home Assistant deleted the old token 'gigs'")
        #expect(home.secrets["GIGS_HA_TOKEN"] == "new-ha-token")
    }

    @Test("no command line carries a token: the holder takes it on standard input, and Home Assistant inside a websocket message")
    func valuesStayOffArgv() async throws {
        let home = Home()

        _ = await makeExecutor(home).execute(gigsPlan)

        let commands = home.happened.filter { $0.hasPrefix("run ") }.map { $0.components(separatedBy: " < ")[0] }
        #expect(!commands.contains { $0.contains("ha-token") })
    }

    @Test("an old id that now carries another name is not deleted, and the run stops at the revoke")
    func renamedOldTokenIsKept() async throws {
        let home = Home(renamed: true)

        let report = await makeExecutor(home).execute(gigsPlan)

        #expect(report.stopped?.phase == .revoke)
        #expect(!home.happened.contains("deleted old-id"))
        #expect(report.reason?.contains("delete it on the profile page") == true)
    }

    @Test("a token the service holds that is not long-lived makes nothing")
    func shortLivedTokenMakesNothing() async throws {
        let home = Home(oldType: "normal")

        let report = await makeExecutor(home).execute(gigsPlan)

        #expect(report.stopped?.phase == .issue)
        #expect(!home.happened.contains { $0.hasSuffix("auth/long_lived_access_token") })
    }

    @Test("a secrets file with no current token stops before Home Assistant is asked, and says how to seed one")
    func noCurrentTokenStops() async throws {
        let home = Home(file: [:])

        let report = await makeExecutor(home).execute(gigsPlan)

        #expect(report.stopped?.phase == .issue)
        #expect(home.happened.isEmpty)
        #expect(report.reason?.contains("house-secret") == true)
    }

    @Test("the old token is chosen by the current mark, never by its place in the list")
    func currentMarkChoosesTheOldToken() throws {
        let answer = JSONValue.array([
            .object(["id": .string("a"), "client_name": .string("first"), "token_type": .string("long_lived_access_token"), "is_current": .bool(false)]),
            .object(["id": .string("b"), "client_name": .string("pulse"), "token_type": .string("long_lived_access_token"), "is_current": .bool(true)]),
        ])

        #expect(try HomeAssistantTokens.currentToken(in: answer) == HomeAssistantTokens.Retiring(id: "b", clientName: "pulse"))
    }

    @Test("a message id goes to Home Assistant as an integer")
    func idIsAnInteger() throws {
        let object = HomeAssistantTokens.foundation(.object(["id": .number(3), "lifespan": .number(3650)])) as? [String: Any]
        #expect(object?["id"] as? Int == 3)
    }

    @Test("the issuer round-trips through a kind file, and the preflight asks Home Assistant for any answer")
    func issuerRoundTripsAndProbes() throws {
        let issuer = KindFile.Issuer.homeAssistantToken(url: "http://192.168.0.103:8123", name: "pulse")
        #expect(try JSONDecoder().decode(KindFile.Issuer.self, from: try JSONEncoder().encode(issuer)) == issuer)

        let probes = RotationPreflight.probes(of: [(gigsPlan, ["gigs": "dokku@opi"], [:])])
        #expect(probes.first?.host == "Home Assistant at http://192.168.0.103:8123")
        #expect(probes.first?.command == ["curl", "-sS", "-o", "/dev/null", "--max-time", "6", "http://192.168.0.103:8123/api/"])
    }
}

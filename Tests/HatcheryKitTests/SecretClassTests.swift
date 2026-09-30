import Foundation
import Testing

@testable import HatcheryKit

/// A kind file decoded from JSON text, the way the registry reads one.
private func kind(_ json: String) throws -> KindFile {
    try JSONDecoder().decode(KindFile.self, from: Data(json.utf8))
}

/// A kind file written to a scratch path and loaded through ``KindFile/load(atPath:)``, which is where validation runs.
private func loaded(_ json: String) throws -> KindFile {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("class-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try KindFile.load(atPath: url.path)
}

/// One service with a key of every refused shape and one key that runs: a class owed, a sealing key, an address, and a shared key.
private let mixedKind = """
    {
      "kind": "mixed",
      "environment": {
        "OWED_TOKEN": {
          "secret": true,
          "rotation": { "issuer": { "type": "random", "bytes": 32 }, "holders": [] }
        },
        "SESSION_SECRET": {
          "class": "sealingKey",
          "secret": true,
          "rotation": { "issuer": { "type": "manual", "recipe": "re-seal every document first" }, "holders": [] }
        },
        "NTFY_TOPIC": {
          "class": "address",
          "secret": true,
          "rotation": { "issuer": { "type": "manual", "recipe": "pick a new topic on the phone" }, "holders": [] }
        },
        "SHARED_TOKEN": {
          "class": "sharedKey",
          "secret": true,
          "rotation": { "issuer": { "type": "random", "bytes": 32 }, "holders": [] }
        }
      }
    }
    """

@Suite("A secret's class, as the kind file declares it")
struct SecretClassDeclarationTests {
    @Test("the class decodes from class and survives a round trip")
    func classRoundTrips() throws {
        let file = try kind(mixedKind)

        #expect(file.environment["SESSION_SECRET"]?.secretClass == .sealingKey)
        #expect(file.environment["OWED_TOKEN"]?.secretClass == nil)

        let encoded = try JSONEncoder().encode(file)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"class\":\"sealingKey\""))
        #expect(try JSONDecoder().decode(KindFile.self, from: encoded) == file)
    }

    @Test("a class hatchery does not know is refused")
    func unknownClassIsRefused() {
        #expect(throws: DecodingError.self) {
            try kind(#"{ "kind": "coop", "environment": { "K": { "secret": true, "class": "apiKey" } } }"#)
        }
    }

    @Test("a sealing key with a random issuer fails validation, and the refusal names what fits")
    func sealingKeyWithRandomIsRefused() {
        let json = """
            {
              "kind": "vault",
              "environment": {
                "SESSION_SECRET": {
                  "class": "sealingKey",
                  "secret": true,
                  "rotation": { "issuer": { "type": "random", "bytes": 32 }, "holders": [] }
                }
              }
            }
            """

        #expect {
            try loaded(json)
        } throws: { error in
            guard case .classDoesNotFit(_, let key, let secretClass, let issuer) = error as? KindFileError else { return false }
            return key == "SESSION_SECRET" && secretClass == .sealingKey && issuer == "random"
                && "\(error)".contains("a sealingKey takes manual")
        }
    }

    @Test("a list on a key that is not a shared key fails validation")
    func listOnATokenIsRefused() {
        let json = """
            { "kind": "vault", "environment": { "K": { "class": "token", "list": true, "secret": true } } }
            """

        #expect(throws: KindFileError.self) { try loaded(json) }
    }

    @Test("a secret with no class loads, because a class owed is refused by the rotation and not by the file")
    func missingClassLoads() throws {
        #expect(try loaded(mixedKind).environment.count == 4)
    }

    @Test("the fit table: each class takes its issuers and refuses the rest")
    func fitTable() {
        let issuers: [KindFile.Issuer] = [
            .vaultAppKey, .vaultS3Key(app: "a"), .vaultSecret(app: "a", name: "N"),
            .postgresRole(server: "s", role: "r"), .random(bytes: 32), .manual(recipe: "r"),
        ]
        for secretClass in SecretClass.allCases {
            let fitting = issuers.filter { secretClass.fits($0) }.map(\.typeName)
            #expect(fitting == secretClass.fittingIssuers)
        }
        #expect(!SecretClass.sealingKey.fits(.random(bytes: 32)))
        #expect(!SecretClass.sealingKey.fits(.vaultSecret(app: "vault", name: "SESSION_SECRET")))
        #expect(!SecretClass.token.fits(.random(bytes: 32)))
        #expect(SecretClass.password.fits(.postgresRole(server: "rookery-pg", role: "rookery")))
    }
}

@Suite("The rotation, run by class")
struct SecretClassRotationTests {
    @Test("a key with no class is refused, and nothing guesses one from its name")
    func missingClassIsRefused() throws {
        #expect(throws: RotationRefusal.noClass(keys: ["OWED_TOKEN"])) {
            try RotationPlanner.plans(service: "mixed", keys: ["OWED_TOKEN"], in: try kind(mixedKind), apps: [], hosts: [])
        }
    }

    @Test("a sealing key with no re-seal route is refused with its recipe")
    func sealingKeyIsRefused() throws {
        #expect {
            try RotationPlanner.plans(service: "mixed", keys: ["SESSION_SECRET"], in: try kind(mixedKind), apps: [], hosts: [])
        } throws: { error in
            guard case .noResealRoute(let keys, let recipe) = error as? RotationRefusal else { return false }
            return keys == ["SESSION_SECRET"] && recipe == "re-seal every document first"
                && "\(error)".contains("house#45")
        }
    }

    @Test("an address is refused with the recipe a person follows on the device")
    func addressIsRefused() throws {
        #expect(throws: RotationRefusal.address(keys: ["NTFY_TOPIC"], recipe: "pick a new topic on the phone")) {
            try RotationPlanner.plans(service: "mixed", keys: ["NTFY_TOPIC"], in: try kind(mixedKind), apps: [], hosts: [])
        }
    }

    @Test("rotate --all refuses each unrunnable row alone, prints its class, and the shared key still plans")
    func allGoesOnPastRefusedRows() async throws {
        let target = RotationTarget(
            stack: "estate",
            service: "mixed",
            kind: try kind(mixedKind),
            dokkuTargets: [:],
            adminTargets: [:],
            secretsURL: URL(fileURLWithPath: "/tmp/secret-class-tests.secrets.json"))
        let executor = RotationExecutor(vault: VaultAdmin(session: ""), secrets: SecretsFile(read: { [:] }, write: { _ in }))

        let run = await RotationRun.all(
            targets: [target],
            apps: [],
            hosts: [],
            dryRun: true,
            yes: false,
            makeExecutor: { _ in executor })

        let states = Dictionary(uniqueKeysWithValues: run.outcomes.map { ($0.keys[0], $0.state) })
        #expect(states == ["NTFY_TOPIC": .refused, "OWED_TOKEN": .refused, "SESSION_SECRET": .refused, "SHARED_TOKEN": .dry])
        #expect(run.lines.contains("    class    owed"))
        #expect(run.lines.contains("    class    sealingKey"))
        #expect(run.lines.contains("    runs     one value onto every holder, restart each"))
    }

    @Test("the preflight asks vault for a token's issuer and the database for a password, before any mint")
    func preflightChecksByClass() throws {
        let rookery = try recordedKind("rookery.kind.json")
        let plans = try RotationPlanner.plans(
            service: "rookery",
            keys: ["DATABASE_URL", "VAULT_APP_KEY"],
            in: rookery,
            apps: ["rookery", "coop"],
            hosts: [])

        let probes = RotationPreflight.probes(
            of: plans.map { ($0, ["rookery": "dokku@opi"], ["rookery-pg": "jimmy@opi"]) },
            vault: "https://vault.example")

        #expect(probes.map(\.host) == ["the database rookery-pg on jimmy@opi", "dokku@opi", "vault at https://vault.example"])
        #expect(probes[0].command.suffix(6) == ["docker", "exec", "rookery-pg", "pg_isready", "-U", "postgres"])
        #expect(probes[2].command.last == "https://vault.example/health")
    }

    @Test("a list receiver prints the overlap in its plan")
    func listPrintsOverlap() {
        let plan = RotationPlan(
            service: "vault",
            keys: ["KIOSK_TOKENS"],
            rotation: KindFile.Rotation(issuer: .random(bytes: 32)),
            secretClass: .sharedKey,
            list: true)

        #expect(plan.lines().contains { $0.hasPrefix("    overlaps the new value joins the list") })
    }
}

@Suite("The ledger's class column")
struct SecretClassLedgerTests {
    @Test("a row with no class shows the class owed and asks for one first")
    func owedClassIsShown() throws {
        var state = LedgerState()
        let target = LedgerTarget(stack: "estate", service: "mixed", kind: try kind(mixedKind))

        let rows = SecretLedger.rows(for: [target], state: &state, today: Date())
        let owed = try #require(rows.first { $0.key == "OWED_TOKEN" })

        #expect(owed.classOwed)
        #expect(owed.next == .declareClass)
        #expect(owed.listedForRotation == false)
        #expect(rows.first { $0.key == "SESSION_SECRET" }?.next == .reseal)
        #expect(SecretLedger.lines(for: rows).contains { $0.contains("OWED_TOKEN") && $0.contains("owed") })
    }

    @Test("a password row names its role, and the document carries class, classOwed and role by name")
    func passwordCarriesItsRole() throws {
        var state = LedgerState()
        let target = LedgerTarget(stack: "rookery", service: "rookery", kind: try recordedKind("rookery.kind.json"))

        let rows = SecretLedger.rows(for: [target], state: &state, today: Date())
        let password = try #require(rows.first { $0.key == "DATABASE_URL" })
        #expect(password.secretClass == .password)
        #expect(password.role == "rookery")
        #expect(SecretLedger.lines(for: rows).contains { $0.contains("DATABASE_URL (role rookery)") })

        let data = try LedgerDocument(manifests: [], rows: rows, reminders: []).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"class\" : \"password\""))
        #expect(text.contains("\"role\" : \"rookery\""))
        #expect(text.contains("\"classOwed\" : false"))
        let back = try JSONDecoder().decode(LedgerDocument.self, from: data)
        #expect(back.rows.first { $0.key == "DATABASE_URL" }?.secretClass == "password")
    }
}

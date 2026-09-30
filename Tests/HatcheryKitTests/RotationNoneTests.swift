import Foundation
import Testing

@testable import HatcheryKit

/// A kind file decoded from JSON text, the way the registry reads one.
private func kind(_ json: String) throws -> KindFile {
    try JSONDecoder().decode(KindFile.self, from: Data(json.utf8))
}

/// A kind file written to a scratch path and loaded through ``KindFile/load(atPath:)``, the way the registry loads one.
private func loaded(_ json: String) throws -> KindFile {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try KindFile.load(atPath: url.path)
}

private let labReason = "A lab database's password on the box, reset only when the lab is rebuilt; nothing outside the lab holds it."

/// A lab database in the box's shape: two passwords nothing rotates, and one shared key hatchery mints.
/// The admin password carries `probe: none` too, so it would owe a reminder if the rotation of none did not stop one.
private let labKind = """
    {
      "kind": "lab-pg",
      "environment": {
        "POSTGRES_PASSWORD": {
          "class": "password",
          "secret": true,
          "probe": "none",
          "rotation": { "none": "\(labReason)" }
        },
        "APP_PASSWORD": {
          "class": "password",
          "secret": true,
          "rotation": { "none": "\(labReason)" }
        },
        "SHARED_TOKEN": {
          "class": "sharedKey",
          "secret": true,
          "rotation": { "issuer": { "type": "random", "bytes": 32 }, "holders": [] }
        }
      }
    }
    """

@Suite("A rotation of none, as the kind file declares it")
struct RotationNoneDeclarationTests {
    @Test("a rotation of none decodes with its reason and survives a round trip")
    func noneRoundTrips() throws {
        let lab = try kind(labKind)

        #expect(lab.environment["POSTGRES_PASSWORD"]?.rotation == .unrotated(reason: labReason))
        #expect(lab.unrotatedReason(forKey: "APP_PASSWORD") == labReason)
        #expect(lab.unrotatedReason(forKey: "SHARED_TOKEN") == nil)
        let back = try JSONDecoder().decode(KindFile.self, from: JSONEncoder().encode(lab))
        #expect(back == lab)
    }

    @Test("a key with a rotation of none is not rotatable, and never folds with another key")
    func noneIsNotRotatable() throws {
        let lab = try kind(labKind)

        #expect(lab.rotatableKeys() == ["SHARED_TOKEN"])
        #expect(lab.rotationGroups().map(\.keys) == [["APP_PASSWORD"], ["POSTGRES_PASSWORD"], ["SHARED_TOKEN"]])
    }

    @Test("a rotation of none with an empty reason fails to load")
    func emptyReasonFails() {
        let json = """
            { "kind": "lab-pg", "environment": { "P": { "class": "password", "secret": true, "rotation": { "none": "  " } } } }
            """
        #expect(throws: DecodingError.self) { try loaded(json) }
    }

    @Test("a rotation of none beside an issuer or holders fails to load")
    func noneWithIssuerOrHoldersFails() {
        let withIssuer = """
            { "kind": "lab-pg", "environment": { "P": { "class": "password", "secret": true,
              "rotation": { "none": "lab", "issuer": { "type": "random", "bytes": 32 } } } } }
            """
        let withHolders = """
            { "kind": "lab-pg", "environment": { "P": { "class": "password", "secret": true,
              "rotation": { "none": "lab", "holders": [] } } } }
            """
        #expect(throws: DecodingError.self) { try loaded(withIssuer) }
        #expect(throws: DecodingError.self) { try loaded(withHolders) }
    }
}

@Suite("A rotation of none in the ledger")
struct RotationNoneLedgerTests {
    @Test("the row shows the reason, is not put up for rotation, and owes nothing")
    func rowShowsReason() throws {
        var state = LedgerState()
        let target = LedgerTarget(stack: "box", service: "lab-pg", kind: try kind(labKind))

        let rows = SecretLedger.rows(for: [target], state: &state, today: Date())
        let password = try #require(rows.first { $0.key == "POSTGRES_PASSWORD" })

        #expect(password.next == .notRotated(labReason))
        #expect(password.listedForRotation == false)
        #expect(password.classOwed == false)
        #expect(password.issuer == "not rotated")
        #expect(SecretLedger.nextText(password.next) == "not rotated: \(labReason)")
        #expect(SecretLedger.lines(for: rows).contains { $0.contains("POSTGRES_PASSWORD") && $0.hasSuffix(labReason) })
    }

    @Test("only the minted key is counted as put up for rotation")
    func countsLeaveNoneOut() throws {
        var state = LedgerState()
        let target = LedgerTarget(stack: "box", service: "lab-pg", kind: try kind(labKind))

        let rows = SecretLedger.rows(for: [target], state: &state, today: Date())

        #expect(rows.count == 3)
        #expect(rows.filter(\.listedForRotation).map(\.key) == ["SHARED_TOKEN"])
        #expect(rows.filter(\.classOwed).isEmpty)
    }

    @Test("a rotation of none owes no reminder, even on a key no API can check with no expiry typed")
    func noReminderFires() throws {
        let target = LedgerTarget(stack: "box", service: "lab-pg", kind: try kind(labKind))

        #expect(SecretLedger.reminders(for: [target], within: SecretLedger.reminderDays, today: Date()).isEmpty)
    }

    @Test("the document writes next as none and carries the reason as noneReason")
    func documentCarriesReason() throws {
        var state = LedgerState()
        let target = LedgerTarget(stack: "box", service: "lab-pg", kind: try kind(labKind))
        let rows = SecretLedger.rows(for: [target], state: &state, today: Date())

        let data = try LedgerDocument(manifests: [], rows: rows, reminders: []).encoded()
        let back = try JSONDecoder().decode(LedgerDocument.self, from: data)
        let password = try #require(back.rows.first { $0.key == "POSTGRES_PASSWORD" })
        let shared = try #require(back.rows.first { $0.key == "SHARED_TOKEN" })

        #expect(password.next == "none")
        #expect(password.noneReason == labReason)
        #expect(password.listedForRotation == false)
        #expect(shared.noneReason == nil)
        #expect(String(decoding: data, as: UTF8.self).contains("\"noneReason\" : "))
    }
}

@Suite("A rotation of none in rotate")
struct RotationNoneRotateTests {
    @Test("rotate --all skips each key with its reason, and the shared key still plans")
    func allSkipsWithReason() async throws {
        let target = RotationTarget(
            stack: "box",
            service: "lab-pg",
            kind: try kind(labKind),
            dokkuTargets: [:],
            adminTargets: [:],
            secretsURL: URL(fileURLWithPath: "/tmp/rotation-none-tests.secrets.json"))
        let executor = RotationExecutor(vault: VaultAdmin(session: ""), secrets: SecretsFile(read: { [:] }, write: { _ in }))

        let run = await RotationRun.all(
            targets: [target],
            apps: [],
            hosts: [],
            dryRun: true,
            yes: false,
            makeExecutor: { _ in executor })

        let states = Dictionary(uniqueKeysWithValues: run.outcomes.map { ($0.keys[0], $0.state) })
        #expect(states == ["APP_PASSWORD": .skipped, "POSTGRES_PASSWORD": .skipped, "SHARED_TOKEN": .dry])
        #expect(run.lines.filter { $0 == "    not rotated  \(labReason)" }.count == 2)
        #expect(!run.lines.contains { $0.contains("refused") })
    }

    @Test("rotate names a key with a rotation of none, plans nothing for it, and reads its reason")
    func namedKeyIsSkipped() throws {
        let lab = try kind(labKind)

        let plans = try RotationPlanner.plans(service: "lab-pg", keys: ["POSTGRES_PASSWORD"], in: lab, apps: [], hosts: [])
        let unrotated = RotationPlanner.unrotated(keys: ["POSTGRES_PASSWORD"], in: lab)

        #expect(plans.isEmpty)
        #expect(unrotated.map(\.keys) == [["POSTGRES_PASSWORD"]])
        #expect(unrotated.map(\.reason) == [labReason])
    }
}

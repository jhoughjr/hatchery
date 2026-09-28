import Foundation
import Testing

@testable import HatcheryKit

/// A vault kind in the estate's shape: two keys no API can check, the key everything is sealed under, one key hatchery
/// mints, and one key another service owns.
private func vaultKind(appleExpires: String? = nil, googleExpires: String? = nil) throws -> KindFile {
    var kind = try JSONDecoder().decode(
        KindFile.self,
        from: Data(
            """
            {
              "kind": "vault",
              "environment": {
                "APPLE_PRIVATE_KEY": {
                  "secret": true,
                  "rotation": { "issuer": { "type": "manual", "recipe": "App Store Connect, Keys" }, "holders": [] }
                },
                "GOOGLE_CLIENT_SECRET": {
                  "secret": true,
                  "rotation": { "issuer": { "type": "manual", "recipe": "Google Cloud console" }, "holders": [] }
                },
                "SESSION_SECRET": {
                  "secret": true,
                  "rotation": { "issuer": { "type": "manual", "recipe": "re-seal every document first" }, "holders": [] }
                },
                "NODE_KEY": {
                  "secret": true,
                  "rotation": { "issuer": { "type": "random", "bytes": 32 }, "holders": [] }
                },
                "HATCHERY_TOKEN": {
                  "secret": true,
                  "rotation": { "owner": "air/hatchery-serve" }
                },
                "BASE_URL": { "deployed": "https://vault.example" }
              }
            }
            """.utf8))
    kind.environment["APPLE_PRIVATE_KEY"]?.expires = appleExpires
    kind.environment["GOOGLE_CLIENT_SECRET"]?.expires = googleExpires
    return kind
}

private func day(_ text: String) -> Date {
    LedgerDay.date(text) ?? Date(timeIntervalSince1970: 0)
}

private func rows(
    _ kind: KindFile, state: inout LedgerState, today: String = "2026-09-28", carried: Set<String>? = nil
) -> [String: LedgerRow] {
    let target = LedgerTarget(stack: "estate", service: "vault", kind: kind, carried: carried)
    let listed = SecretLedger.rows(for: [target], state: &state, today: day(today))
    return Dictionary(uniqueKeysWithValues: listed.map { ($0.key, $0) })
}

@Suite("The ledger's row for a token no API can check")
struct CannotProbeTests {
    @Test("the Apple and Google keys read cannot probe, and show expiry not typed until a person types one")
    func appleAndGoogleAreCannotProbe() throws {
        var state = LedgerState()

        let listed = rows(try vaultKind(), state: &state)

        #expect(listed["APPLE_PRIVATE_KEY"]?.liveness == .cannotProbe)
        #expect(listed["GOOGLE_CLIENT_SECRET"]?.liveness == .cannotProbe)
        #expect(listed["APPLE_PRIVATE_KEY"]?.expiry == .notTyped)
        #expect(listed["NODE_KEY"]?.liveness == .notChecked)
        #expect(listed["NODE_KEY"]?.expiry == .undeclared)
    }

    @Test("a typed expiry shows on the row, and one that is not a day shows as unreadable")
    func typedExpiryShows() throws {
        var state = LedgerState()

        let listed = rows(try vaultKind(appleExpires: "2027-01-31", googleExpires: "next spring"), state: &state)

        #expect(listed["APPLE_PRIVATE_KEY"]?.expiry == .on("2027-01-31"))
        #expect(listed["GOOGLE_CLIENT_SECRET"]?.expiry == .unreadable("next spring"))
    }

    @Test("a cannot-probe key never reads live, even when a check once recorded it live")
    func cannotProbeNeverReadsLive() throws {
        var state = LedgerState()
        let live = LedgerState.Check(on: "2026-09-27", live: true)
        state.records[LedgerState.id(stack: "estate", service: "vault", key: "APPLE_PRIVATE_KEY")] =
            LedgerState.Record(firstSeen: "2026-09-27", checked: live)
        state.records[LedgerState.id(stack: "estate", service: "vault", key: "NODE_KEY")] =
            LedgerState.Record(firstSeen: "2026-09-27", checked: live)

        let listed = rows(try vaultKind(), state: &state)

        #expect(listed["APPLE_PRIVATE_KEY"]?.liveness == .cannotProbe)
        #expect(listed["NODE_KEY"]?.liveness == .live)
    }

    @Test("a kind file marks any other key cannot probe with probe none")
    func declaredProbeNone() throws {
        let kind = try JSONDecoder().decode(
            KindFile.self,
            from: Data(
                """
                { "kind": "x", "environment": { "OTHER": { "secret": true, "probe": "none", "expires": "2027-02-01" } } }
                """.utf8))

        #expect(kind.environment["OTHER"]?.probe == .unavailable)
        #expect(kind.environment["OTHER"]?.expires == "2027-02-01")
        #expect(SecretLedger.cannotProbe(key: "OTHER", entry: kind.environment["OTHER"] ?? .init()))

        let encoded = try JSONEncoder().encode(kind)
        #expect(try JSONDecoder().decode(KindFile.self, from: encoded) == kind)
    }
}

@Suite("The reminder before a typed expiry")
struct ExpiryReminderTests {
    @Test("a reminder fires inside the window and on an expired key, and stays quiet outside it")
    func reminderWindow() throws {
        let kind = try vaultKind(appleExpires: "2026-10-15", googleExpires: "2027-03-01")
        let target = LedgerTarget(stack: "estate", service: "vault", kind: kind)

        let near = SecretLedger.reminders(for: [target], within: 30, today: day("2026-09-28"))
        let late = SecretLedger.reminders(for: [target], within: 30, today: day("2026-10-20"))

        #expect(
            near == [
                "estate/vault APPLE_PRIVATE_KEY expires on 2026-10-15, in 17 day(s); turn it over by its recipe before then"
            ])
        #expect(late.first == "estate/vault APPLE_PRIVATE_KEY expired on 2026-10-15, 5 day(s) ago; turn it over by its recipe")
    }

    @Test("a cannot-probe key with no typed expiry owes a reminder, and a key a probe can check owes none")
    func untypedExpiryOwesReminder() throws {
        let target = LedgerTarget(stack: "estate", service: "vault", kind: try vaultKind())

        let lines = SecretLedger.reminders(for: [target], within: 30, today: day("2026-09-28"))

        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("no typed expiry") })
        #expect(!lines.contains { $0.contains("NODE_KEY") })
    }

    @Test("the published findings carry the reminder, so the daily declared job takes it to the board")
    func auditFindingCarriesReminder() throws {
        let kind = try vaultKind(appleExpires: "2026-10-15", googleExpires: "2027-03-01")

        let findings = DeclarationAudit.rotationFindings(in: kind, today: day("2026-09-28"))

        let expiry = findings.filter { $0.code == FindingCode.secretExpiry }
        #expect(expiry.count == 1)
        #expect(expiry.first?.text.hasPrefix("APPLE_PRIVATE_KEY expires on 2026-10-15") == true)
    }
}

@Suite("A token older than the ledger")
struct UnknownIssueDateTests {
    @Test("an unknown issue date shows the first-seen day and puts the key up for rotation")
    func unknownIssueIsListed() throws {
        var state = LedgerState()

        let listed = rows(try vaultKind(), state: &state, today: "2026-09-28")

        #expect(listed["NODE_KEY"]?.issued == nil)
        #expect(listed["NODE_KEY"]?.firstSeen == "2026-09-28")
        #expect(listed["NODE_KEY"]?.next == .rotate)
        #expect(listed["APPLE_PRIVATE_KEY"]?.next == .rotateByHand)
        #expect(listed["NODE_KEY"]?.listedForRotation == true)
    }

    @Test("the first-seen day stays the first one on a later run")
    func firstSeenIsKept() throws {
        var state = LedgerState()
        _ = rows(try vaultKind(), state: &state, today: "2026-09-28")

        let later = rows(try vaultKind(), state: &state, today: "2026-10-05")

        #expect(later["NODE_KEY"]?.firstSeen == "2026-09-28")
    }

    @Test("a rotation stamps the issue date, and the key is no longer put up for rotation")
    func rotationStampsIssueDate() throws {
        var state = LedgerState()
        _ = rows(try vaultKind(), state: &state, today: "2026-09-28")

        state.stampIssued(
            from: [
                RotationOutcome(stack: "estate", service: "vault", keys: ["NODE_KEY"], state: .run),
                RotationOutcome(stack: "estate", service: "vault", keys: ["APPLE_PRIVATE_KEY"], state: .refused),
            ],
            on: "2026-10-01")
        let listed = rows(try vaultKind(), state: &state, today: "2026-10-02")

        #expect(listed["NODE_KEY"]?.issued == "2026-10-01")
        #expect(listed["NODE_KEY"]?.next == .nothing)
        #expect(listed["NODE_KEY"]?.firstSeen == "2026-09-28")
        #expect(listed["APPLE_PRIVATE_KEY"]?.issued == nil)
    }

    @Test("vault's session secret is re-sealed, never put up for rotation, with its issue date unknown")
    func sealingKeyIsNeverRotated() throws {
        var state = LedgerState()

        let listed = rows(try vaultKind(), state: &state)

        #expect(listed["SESSION_SECRET"]?.issued == nil)
        #expect(listed["SESSION_SECRET"]?.next == .reseal)
        #expect(listed["SESSION_SECRET"]?.listedForRotation == false)
        #expect(listed["SESSION_SECRET"]?.recipe == "re-seal every document first")
    }

    @Test("an owned key points at its owner's row and is not put up for rotation here")
    func ownedKeyPointsAtOwner() throws {
        var state = LedgerState()

        let listed = rows(try vaultKind(), state: &state)

        #expect(listed["HATCHERY_TOKEN"]?.next == .heldFrom("air/hatchery-serve"))
        #expect(listed["HATCHERY_TOKEN"]?.listedForRotation == false)
        #expect(listed["BASE_URL"] == nil)
    }

    @Test("a service that does not carry a key gets no row for it")
    func carriedFiltersRows() throws {
        var state = LedgerState()

        let listed = rows(try vaultKind(), state: &state, carried: ["NODE_KEY"])

        #expect(Array(listed.keys) == ["NODE_KEY"])
    }

    @Test("the ledger file holds names and dates, and reads back what it wrote")
    func stateRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
        var state = LedgerState()
        state.stampIssued(stack: "estate", service: "vault", keys: ["NODE_KEY"], on: "2026-09-28")

        try state.save(to: url)
        let read = try LedgerState.load(from: url)

        #expect(read == state)
        #expect(try LedgerState.load(from: url.appendingPathExtension("missing")) == LedgerState())
    }
}

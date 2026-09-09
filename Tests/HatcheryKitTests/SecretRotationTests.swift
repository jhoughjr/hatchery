import Foundation
import Testing

@testable import HatcheryKit

/// One of the three kind files that declare the estate's six exposed secrets, from `Tests/Fixtures/`.
///
/// The fixtures are the estate's real declarations rather than a hand-written sample. The forge's pair is the
/// reason: one issuer answers for two keys, which no shape guessed from a single key would have produced.
func recordedKind(_ name: String) throws -> KindFile {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    return try KindFile.load(atPath: fixtures.appendingPathComponent(name).path)
}

@Suite("A secret's rotation, as the kind file declares it")
struct SecretRotationTests {
    @Test("rookery declares all three of its secrets, each with a different issuer")
    func rookeryDeclaresThree() throws {
        let kind = try recordedKind("rookery.kind.json")

        #expect(kind.rotatableKeys() == ["DATABASE_URL", "ROOKERY_TOKEN", "VAULT_APP_KEY"])
        #expect(kind.rotation(forKey: "VAULT_APP_KEY")?.issuer == .vaultAppKey)
        #expect(kind.rotation(forKey: "ROOKERY_TOKEN")?.issuer == .random(bytes: 32))
        #expect(
            kind.rotation(forKey: "DATABASE_URL")?.issuer
                == .postgresRole(server: "rookery-pg", role: "rookery"))
    }

    @Test("the shared bearer names the coop as a holder beside rookery itself")
    func sharedBearerNamesEveryHolder() throws {
        let kind = try recordedKind("rookery.kind.json")

        #expect(
            kind.rotation(forKey: "ROOKERY_TOKEN")?.holders == [
                .dokkuConfig(app: "rookery", key: "ROOKERY_TOKEN", restart: .rolling),
                .dokkuConfig(app: "coop", key: "ROOKERY_TOKEN", restart: .rolling),
            ])
    }

    @Test("the forge's two storage keys declare one issuer, and both restart by stop then start")
    func forgePairSharesOneIssuer() throws {
        let kind = try recordedKind("forgejo.kind.json")
        let first = kind.rotation(forKey: "FORGEJO__storage__MINIO_ACCESS_KEY_ID")
        let second = kind.rotation(forKey: "FORGEJO__storage__MINIO_SECRET_ACCESS_KEY")

        #expect(first == second)
        #expect(first?.issuer == .vaultS3Key(app: "forgejo"))
        #expect(first?.holders.count == 2)
        #expect(
            first?.holders.allSatisfy { holder in
                guard case .dokkuConfig(_, _, let restart) = holder else { return false }
                return restart == .stopStart
            } == true)
    }

    @Test("the forge pull token is a printed recipe and names no holder")
    func pullTokenIsManual() throws {
        let kind = try recordedKind("forgejo.kind.json")
        let rotation = try #require(kind.rotation(forKey: "FORGE_PULL_TOKEN"))

        guard case .manual(let recipe) = rotation.issuer else {
            Issue.record("the pull token declares \(rotation.issuer) rather than a manual issuer")
            return
        }
        #expect(recipe.contains("dokku registry:login"))
        #expect(rotation.holders.isEmpty)
    }

    @Test("hatchery-serve names vault first, then the two roost hosts, then the coop")
    func serveNamesFourHolders() throws {
        let kind = try recordedKind("hatchery-serve.kind.json")
        let rotation = try #require(kind.rotation(forKey: "HATCHERY_SERVE_TOKEN"))

        #expect(rotation.issuer == .vaultSecret(app: "hatchery", name: "HATCHERY_SERVE_TOKEN"))
        #expect(
            rotation.holders == [
                .vaultSecret(app: "hatchery", name: "HATCHERY_SERVE_TOKEN"),
                .roostrc(host: "mini", key: "ROOST_HATCHERY_TOKEN"),
                .roostrc(host: "air", key: "ROOST_HATCHERY_TOKEN"),
                .dokkuConfig(app: "coop", key: "HATCHERY_TOKEN", restart: .rolling),
            ])
    }

    @Test("the six exposed values are declared across the three files, and the forge pair counts once")
    func theSixAreDeclared() throws {
        let files = ["rookery.kind.json", "forgejo.kind.json", "hatchery-serve.kind.json"]
        let groups = try files.map { try recordedKind($0).rotationGroups().count }

        // Seven keys, six values: the forge's two storage keys are two halves of one S3 key.
        #expect(groups == [3, 2, 1])
        #expect(groups.reduce(0, +) == 6)
        #expect(try recordedKind("forgejo.kind.json").rotationGroups()[0].keys.count == 2)
    }

    @Test("a kind file that declares no rotation decodes the way it always did")
    func fileWithoutRotationStillReads() throws {
        let json = """
            {
              "kind": "coop",
              "environment": {
                "COOP_TOKEN": { "required": true, "secret": true }
              }
            }
            """
        let kind = try JSONDecoder().decode(KindFile.self, from: Data(json.utf8))

        #expect(kind.environment["COOP_TOKEN"]?.secret == true)
        #expect(kind.environment["COOP_TOKEN"]?.rotation == nil)
        #expect(kind.rotatableKeys().isEmpty)
    }

    @Test("a rotation survives a round trip through the encoder")
    func rotationRoundTrips() throws {
        let kind = try recordedKind("hatchery-serve.kind.json")

        let encoded = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(KindFile.self, from: encoded)

        #expect(decoded == kind)
    }

    @Test("an issuer the file names but hatchery does not know is refused")
    func unknownIssuerIsRefused() throws {
        let json = """
            {
              "kind": "coop",
              "environment": {
                "COOP_TOKEN": {
                  "secret": true,
                  "rotation": { "issuer": { "type": "carrierPigeon" }, "holders": [] }
                }
              }
            }
            """

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KindFile.self, from: Data(json.utf8))
        }
    }
}

@Suite("What the audit says about a secret nothing can replace")
struct RotationAuditTests {
    @Test("a service whose secrets all declare a rotation is reported as covered and flagged for nothing")
    func coveredServiceIsNotFlagged() throws {
        let findings = DeclarationAudit.rotationFindings(in: try recordedKind("rookery.kind.json"))

        #expect(findings.count == 1)
        #expect(findings.first?.code == FindingCode.rotationCoverage)
        #expect(findings.first?.text == "3 of 3 secret(s) declare a rotation, and 0 do not")
    }

    @Test("a secret with no rotation is named, and the coverage line counts it")
    func undeclaredSecretIsFlagged() throws {
        var kind = try recordedKind("rookery.kind.json")
        kind.environment["ROOKERY_TOKEN"]?.rotation = nil

        let findings = DeclarationAudit.rotationFindings(in: kind)

        #expect(findings.map(\.code) == [FindingCode.secretNoRotation, FindingCode.rotationCoverage])
        #expect(findings[0].text.hasPrefix("ROOKERY_TOKEN is a secret with no declared rotation"))
        #expect(findings[1].text == "2 of 3 secret(s) declare a rotation, and 1 do not")
    }

    @Test("a service that marks no key secret produces no rotation finding at all")
    func serviceWithoutSecretsSaysNothing() throws {
        let kind = KindFile(kind: "coop", environment: ["COOP_PORT": .init(default: "5000")])

        #expect(DeclarationAudit.rotationFindings(in: kind).isEmpty)
    }
}

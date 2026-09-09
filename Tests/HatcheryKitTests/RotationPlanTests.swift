import Foundation
import Testing

@testable import HatcheryKit

/// What the estate's manifest knows, as the planner takes it: the apps and the boxes a holder may name.
private let estateApps: Set<String> = ["rookery", "rookery-pg", "coop", "forgejo", "hatchery-serve"]
private let estateHosts: Set<String> = ["mini", "air", "opi"]

@Suite("The plan a rotation prints before anything moves")
struct RotationPlanTests {
    @Test("rookery plans three rotations, one per declared secret")
    func rookeryPlansThree() throws {
        let plans = try RotationPlanner.plans(
            service: "rookery",
            keys: [],
            in: try recordedKind("rookery.kind.json"),
            apps: estateApps,
            hosts: estateHosts)

        #expect(plans.map(\.keys) == [["DATABASE_URL"], ["ROOKERY_TOKEN"], ["VAULT_APP_KEY"]])
    }

    @Test("the plan prints the issuer, then the holders in order, then the restarts")
    func planPrintsTheRuledOrder() throws {
        let plans = try RotationPlanner.plans(
            service: "rookery",
            keys: ["ROOKERY_TOKEN"],
            in: try recordedKind("rookery.kind.json"),
            apps: estateApps,
            hosts: estateHosts)

        #expect(
            plans.flatMap { $0.lines() } == [
                "  ROOKERY_TOKEN",
                "    issues   hatchery mints 32 random bytes",
                "    holds    ROOKERY_TOKEN in the config of rookery, rolling deploy",
                "    holds    ROOKERY_TOKEN in the config of coop, rolling deploy",
                "    restarts rookery, rolling deploy",
                "    restarts coop, rolling deploy",
            ])
    }

    @Test("the database password names the role as its issuer, and the app as its one holder")
    func databaseRoleIsTheIssuer() throws {
        let plans = try RotationPlanner.plans(
            service: "rookery",
            keys: ["DATABASE_URL"],
            in: try recordedKind("rookery.kind.json"),
            apps: estateApps,
            hosts: estateHosts)

        #expect(
            plans.flatMap { $0.lines() } == [
                "  DATABASE_URL",
                "    issues   a new password for role rookery on rookery-pg, by ALTER ROLE",
                "    holds    DATABASE_URL in the config of rookery, rolling deploy",
                "    restarts rookery, rolling deploy",
            ])
    }

    @Test("naming one half of the forge's S3 key plans the pair, because one issuer answers for both")
    func namingOneHalfPlansThePair() throws {
        let plans = try RotationPlanner.plans(
            service: "forgejo",
            keys: ["FORGEJO__storage__MINIO_SECRET_ACCESS_KEY"],
            in: try recordedKind("forgejo.kind.json"),
            apps: estateApps,
            hosts: estateHosts)

        #expect(plans.count == 1)
        #expect(
            plans[0].keys == [
                "FORGEJO__storage__MINIO_ACCESS_KEY_ID",
                "FORGEJO__storage__MINIO_SECRET_ACCESS_KEY",
            ])
        #expect(plans[0].lines().contains("    restarts forgejo, stop then start"))
    }

    @Test("serve's token restarts vault's reader and the coop, and the two roostrc files restart nothing")
    func roostrcHoldersRestartNothing() throws {
        let plans = try RotationPlanner.plans(
            service: "hatchery-serve",
            keys: [],
            in: try recordedKind("hatchery-serve.kind.json"),
            apps: estateApps,
            hosts: estateHosts)

        #expect(
            plans.flatMap { $0.lines() } == [
                "  HATCHERY_SERVE_TOKEN",
                "    issues   hatchery mints a value, and vault stores it as HATCHERY_SERVE_TOKEN on hatchery",
                "    holds    HATCHERY_SERVE_TOKEN read from vault at boot by hatchery",
                "    holds    ROOST_HATCHERY_TOKEN in ~/.roostrc on mini",
                "    holds    ROOST_HATCHERY_TOKEN in ~/.roostrc on air",
                "    holds    HATCHERY_TOKEN in the config of coop, rolling deploy",
                "    restarts hatchery, so it reads the new value from vault",
                "    restarts coop, rolling deploy",
            ])
    }
}

@Suite("What the planner refuses to plan")
struct RotationRefusalTests {
    @Test("a key issued by a person refuses the run and prints the recipe")
    func manualIssuerRefuses() throws {
        #expect {
            try RotationPlanner.plans(
                service: "forgejo",
                keys: ["FORGE_PULL_TOKEN"],
                in: try recordedKind("forgejo.kind.json"),
                apps: estateApps,
                hosts: estateHosts)
        } throws: { error in
            guard case RotationRefusal.manualIssuer(let keys, let recipe) = error else { return false }
            return keys == ["FORGE_PULL_TOKEN"] && recipe.contains("dokku registry:login")
        }
    }

    @Test("a holder naming an app the manifest does not declare refuses the run")
    func unknownAppRefuses() throws {
        #expect {
            try RotationPlanner.plans(
                service: "rookery",
                keys: ["ROOKERY_TOKEN"],
                in: try recordedKind("rookery.kind.json"),
                apps: ["rookery"],
                hosts: estateHosts)
        } throws: { error in
            guard case RotationRefusal.unknownHolder(_, _, let missing) = error else { return false }
            return missing == "the app coop"
        }
    }

    @Test("a holder naming a box the manifest does not know refuses the run")
    func unknownHostRefuses() throws {
        #expect {
            try RotationPlanner.plans(
                service: "hatchery-serve",
                keys: [],
                in: try recordedKind("hatchery-serve.kind.json"),
                apps: estateApps,
                hosts: ["mini"])
        } throws: { error in
            guard case RotationRefusal.unknownHolder(_, _, let missing) = error else { return false }
            return missing == "the host air"
        }
    }

    @Test("a key the service does not declare a rotation for is refused, and the answer lists the ones it does")
    func unknownKeyRefuses() throws {
        #expect {
            try RotationPlanner.plans(
                service: "rookery",
                keys: ["ROOKERY_PORT"],
                in: try recordedKind("rookery.kind.json"),
                apps: estateApps,
                hosts: estateHosts)
        } throws: { error in
            guard case RotationRefusal.notRotatable(let key, _, let rotatable) = error else { return false }
            return key == "ROOKERY_PORT"
                && rotatable == ["DATABASE_URL", "ROOKERY_TOKEN", "VAULT_APP_KEY"]
        }
    }

    @Test("a service that declares no rotation at all is refused before any key is looked up")
    func serviceWithoutRotationsRefuses() throws {
        let kind = KindFile(kind: "coop", environment: ["COOP_TOKEN": .init(secret: true)])

        #expect(throws: RotationRefusal.nothingRotatable(service: "coop")) {
            try RotationPlanner.plans(
                service: "coop", keys: [], in: kind, apps: estateApps, hosts: estateHosts)
        }
    }
}

@Suite("The vault session, read from the environment and nowhere else")
struct VaultSessionTests {
    @Test("the session is the environment's value, trimmed")
    func sessionComesFromTheEnvironment() {
        #expect(VaultSession.read(from: ["VAULT_SESSION": " abc123\n"]) == "abc123")
    }

    @Test("an absent or empty session is no session")
    func absentSessionIsNil() {
        #expect(VaultSession.read(from: [:]) == nil)
        #expect(VaultSession.read(from: ["VAULT_SESSION": "   "]) == nil)
    }

    @Test("the refusal for a missing session carries the browser recipe")
    func refusalCarriesTheRecipe() {
        let text = RotationRefusal.noVaultSession.description

        #expect(text.contains("VAULT_SESSION"))
        #expect(text.contains("devtools > Application > Cookies > vault_session"))
    }

    @Test("only the vault issuers need a session")
    func onlyVaultIssuersNeedASession() {
        #expect(KindFile.Issuer.vaultAppKey.needsVaultSession)
        #expect(KindFile.Issuer.vaultS3Key(app: "forgejo").needsVaultSession)
        #expect(KindFile.Issuer.vaultSecret(app: "hatchery", name: "T").needsVaultSession)
        #expect(!KindFile.Issuer.random(bytes: 32).needsVaultSession)
        #expect(!KindFile.Issuer.postgresRole(server: "rookery-pg", role: "rookery").needsVaultSession)
        #expect(!KindFile.Issuer.manual(recipe: "by hand").needsVaultSession)
    }
}

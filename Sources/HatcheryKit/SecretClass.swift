import Foundation

/// What kind of value a secret is, which decides the check a rotation makes before it mints and the shape of the run.
///
/// Jimmy ruled the five classes on 2026-09-30, house#56, after a mint of vault's `SESSION_SECRET` locked every sealed document.
/// The issuer still says who mints. A class and an issuer that do not fit fail validation, and a secret with no class cannot run.
///
/// - `token`: an issuer hands it out and can take it back. The issuer must answer first.
///   The run mints, places, checks the new value works, and revokes the old.
/// - `sharedKey`: one value that every holder carries and nobody issues. Every holder's host must answer first.
///   The run puts one value onto every holder and restarts each.
/// - `sealingKey`: other values are sealed under it, so a new value locks them.
///   It runs only through a declared re-seal route, `vaultReseal`, never a mint and place.
/// - `password`: a database role's password, and a URL that always carries it. The database must answer first.
///   The run changes the role, then every holder.
/// - `address`: a name that works as a secret, such as an ntfy topic. It is never run.
///   A person renames it on the device by the recipe.
public enum SecretClass: String, Codable, Sendable, Equatable, CaseIterable {
    case token
    case sharedKey
    case sealingKey
    case password
    case address
}

// MARK: - The fit with the issuer

extension SecretClass {
    /// Whether this class can be minted by this issuer.
    ///
    /// A mint issuer (`random` or `vaultSecret`) makes a value nobody can take back, so it fits only a shared key.
    /// A sealing key never fits a plain mint, because a minted value locks everything sealed under the old one.
    /// It fits `vaultReseal`, which re-seals everything under the new value before any holder takes it, house#45.
    public func fits(_ issuer: KindFile.Issuer) -> Bool {
        switch (self, issuer) {
        case (.token, .vaultAppKey), (.token, .vaultS3Key), (.token, .manual):
            return true

        case (.sharedKey, .random), (.sharedKey, .vaultSecret), (.sharedKey, .manual):
            return true

        case (.sealingKey, .vaultReseal), (.sealingKey, .manual):
            return true

        case (.password, .postgresRole), (.password, .manual):
            return true

        case (.address, .manual):
            return true

        default:
            return false
        }
    }

    /// The issuer types this class fits, in the words a kind file uses, for a refusal to name.
    public var fittingIssuers: [String] {
        switch self {
        case .token: return ["vaultAppKey", "vaultS3Key", "manual"]
        case .sharedKey: return ["vaultSecret", "random", "manual"]
        case .sealingKey: return ["vaultReseal", "manual"]
        case .password: return ["postgresRole", "manual"]
        case .address: return ["manual"]
        }
    }
}

// MARK: - The words a plan is printed in

extension SecretClass {
    /// The check this class makes before anything is minted, for a person reading the plan.
    public var checkLabel: String {
        switch self {
        case .token: return "the issuer answers"
        case .sharedKey: return "every holder's host answers"
        case .sealingKey: return "a re-seal route is declared, the operator token works, and every holder is running"
        case .password: return "the database answers"
        case .address: return "none"
        }
    }

    /// The fixed shape of the run for this class, for a person reading the plan.
    public var runLabel: String {
        switch self {
        case .token: return "mint, place, check the new value works, revoke the old"
        case .sharedKey: return "one value onto every holder, restart each"
        case .sealingKey: return "mint, re-seal every document under the value, every holder, every restart, then vault opens every document"
        case .password: return "the role change first, then every holder"
        case .address: return "refused; a person renames it on the device"
        }
    }
}

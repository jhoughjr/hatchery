import Foundation

/// What happens to one config key when a stack is cloned.
///
/// The classification is the whole feature. A clone that copies everything is a footgun — it
/// points the new environment at the old one's database and hands it the old one's credentials.
/// A clone that copies nothing is the blank editor you already had.
public enum CloneDisposition: Sendable, Equatable {
    /// Copied unchanged. Log levels, feature flags, anything environment-agnostic.
    case carried
    /// Copied with the source stack's name or domain swapped for the target's.
    case rewritten(from: String, to: String)
    /// Deliberately regenerated, because the source's value would grant the clone the source's
    /// authority. Sharing a gateway token means staging can act as production.
    case minted(String)
    /// Refused, with the reason. These point at something that exists in the source
    /// environment and nowhere else.
    case refused(String)

    /// Whether a person has to do something before the clone will boot.
    public var needsPerson: Bool {
        if case .refused = self { return true }
        return false
    }
}

public struct ClonedKey: Sendable, Equatable {
    public let key: String
    public let disposition: CloneDisposition
    /// The value to write, or nil when nothing should be written for this key.
    public let value: String?
    /// True when the value is secret and must not be shown or logged.
    public let secret: Bool

    public init(key: String, disposition: CloneDisposition, value: String?, secret: Bool) {
        self.key = key
        self.disposition = disposition
        self.value = value
        self.secret = secret
    }
}

public struct ClonedService: Sendable, Equatable {
    public let name: String
    public let kind: ServiceKind
    public let image: String
    public let domains: [String]
    public let keys: [ClonedKey]

    /// Keys a person still has to supply. These are the whole point of the report.
    public var unresolved: [ClonedKey] {
        keys.filter { $0.disposition.needsPerson }
    }

    /// What the clone can write without asking anyone.
    public var values: [String: String] {
        var out: [String: String] = [:]
        for key in keys where !key.disposition.needsPerson {
            if let value = key.value, !value.isEmpty { out[key.key] = value }
        }
        return out
    }
}

public struct ClonePlan: Sendable, Equatable {
    public let source: String
    public let target: String
    public let environment: Environment
    public let services: [ClonedService]

    public var unresolvedCount: Int {
        services.reduce(0) { $0 + $1.unresolved.count }
    }

    /// How much typing the clone saved, which is the reason it exists.
    public var carriedCount: Int {
        services.reduce(0) { $0 + $1.keys.filter { !$0.disposition.needsPerson }.count }
    }
}

/// Builds a new stack from an existing one, carrying config forward.
///
/// `mwlab-2` was assembled by hand and shipped with nine required keys unset, which is what this
/// exists to prevent. The values were all sitting in `mwlab` — the work was never hard, only
/// tedious, and tedious work is the kind that gets half-done.
public struct StackCloner: Sendable {
    private let minter: SecretMinter

    public init(minter: SecretMinter = SecretMinter()) {
        self.minter = minter
    }

    /// Keys whose value grants authority in the source environment.
    ///
    /// Distinct from `SecretPlanner.mustBeSupplied`, which is about values that cannot be
    /// invented. These *can* be invented and must be: copying production's gateway token into
    /// staging does not fail, which is exactly what makes it dangerous.
    static let regenerated: Set<String> = SecretPlanner.mintedTokens.union(["KEYPAIR_JWKS"])

    /// Decides what happens to every required key of one service.
    public func plan(
        service: ServiceSpec,
        from source: StackSpec,
        into targetName: String,
        environment: Environment,
        sourceConfig: [String: String],
        domains: [String]
    ) async throws -> ClonedService {
        let contract = EnvContract.contract(for: service.kind, backend: source.backend)
        let secretKeys = Set(contract?.secret ?? [])
        var keys: [ClonedKey] = []

        for key in (contract?.required ?? []).sorted() {
            let secret = secretKeys.contains(key)

            // 1. Values that exist only in the source environment. Copying DATABASE_URL is how a
            // staging stack quietly writes to the production database.
            if let reason = SecretPlanner.mustBeSupplied[key] {
                keys.append(ClonedKey(key: key, disposition: .refused(reason), value: nil, secret: secret))
                continue
            }

            // 2. Values that would grant the clone the source's authority.
            if Self.regenerated.contains(key) {
                let value = key == "KEYPAIR_JWKS"
                    ? try await minter.signingJWKS() : minter.token()
                keys.append(
                    ClonedKey(
                        key: key,
                        disposition: .minted(key == "KEYPAIR_JWKS" ? "RSA-2048, RS512" : "random token"),
                        value: value, secret: secret))
                continue
            }

            guard let value = sourceConfig[key], !value.isEmpty else {
                keys.append(
                    ClonedKey(
                        key: key, disposition: .refused("not set on \(source.name) either"),
                        value: nil, secret: secret))
                continue
            }

            // 3. Values that name the source stack, its services, or its environment.
            if let rewritten = Self.rewrite(
                value, from: source, to: targetName, environment: environment) {
                keys.append(
                    ClonedKey(
                        key: key, disposition: .rewritten(from: value, to: rewritten),
                        value: rewritten, secret: secret))
                continue
            }

            keys.append(ClonedKey(key: key, disposition: .carried, value: value, secret: secret))
        }

        return ClonedService(
            name: service.name, kind: service.kind, image: service.image,
            domains: domains, keys: keys)
    }

    /// Swaps the source stack's name for the target's inside a value.
    ///
    /// Deliberately literal. Guessing at URL structure would produce a plausible address that
    /// resolves to nothing; a name substitution is either obviously right or obviously wrong, and
    /// the plan shows both sides so it can be judged before anything is written.
    public static func rewrite(
        _ value: String,
        from source: StackSpec,
        to target: String,
        environment: Environment? = nil
    ) -> String? {
        // Each name paired with what it becomes, longest first so a service name containing the
        // stack name is not half-substituted.
        var pairs: [(name: String, replacement: String)] =
            ([source.name] + source.services.map(\.name)).map {
                ($0, $0 == source.name ? target : "\(target)-\($0)")
            }

        // The source environment's own name, when the clone is going somewhere else. `mwlab`
        // carries TEMPORAL_NAMESPACE=mwserver-dev; copying that verbatim puts the staging stack
        // in the dev namespace, which is neither an error nor what anyone meant.
        let sourceEnvironment = source.resolvedEnvironment.rawValue
        if let environment, environment.rawValue != sourceEnvironment {
            pairs.append((sourceEnvironment, environment.rawValue))
        }
        pairs.sort { $0.name.count > $1.name.count }

        // Substituted through sentinels rather than in place. Replacing `mwlab` with `mwlab-2`
        // leaves text that the next pass matches again — the first version of this produced
        // `mwlab-2-2-2` from a single value. Sentinels cannot match any later pattern, so each
        // occurrence is rewritten exactly once.
        var out = value
        var replacements: [String: String] = [:]
        for (index, pair) in pairs.enumerated() where out.contains(pair.name) {
            let sentinel = "\u{0}\(index)\u{0}"
            out = out.replacingOccurrences(of: pair.name, with: sentinel)
            replacements[sentinel] = pair.replacement
        }
        guard !replacements.isEmpty else { return nil }

        for (sentinel, replacement) in replacements {
            out = out.replacingOccurrences(of: sentinel, with: replacement)
        }
        return out == value ? nil : out
    }
}

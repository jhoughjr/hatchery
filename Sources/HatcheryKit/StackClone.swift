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
    /// Resolved by infrastructure the clone creates for itself — a fresh database on the
    /// stack's own server, mirroring the source's shape with minted credentials. The value
    /// exists only after the create step runs.
    case provisioned(String)
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
    /// Whether the contract requires this key. A refused optional key is information — the
    /// source sets it, the clone won't — not a blocker; the boot checklist filters on this.
    public let required: Bool

    public init(
        key: String, disposition: CloneDisposition, value: String?, secret: Bool,
        required: Bool = true
    ) {
        self.key = key
        self.disposition = disposition
        self.value = value
        self.secret = secret
        self.required = required
    }
}

public struct ClonedService: Sendable, Equatable {
    /// The clone-side name: the dokku app the clone will actually create. The first live
    /// clone kept the source's names, and its apply collided with the source's running apps
    /// on the same box — `App already exists`, three times.
    public let name: String
    /// What this service is called on the source, for reading source-side facts (its tofu
    /// shape, its origin line) that are keyed by the old name.
    public let sourceName: String
    public let kind: ServiceKind
    public let image: String
    public let domains: [String]
    /// The source's explicit base URL with its names rewritten, when it declared one.
    public let baseURL: String?
    /// The source's readiness path, carried so the clone probes the same route.
    public let healthPath: String?
    public let keys: [ClonedKey]
    /// The database the clone will create for this service, when its contract needs one and
    /// the source's shape could be mirrored.
    public let database: DatabaseClonePlan?

    public init(
        name: String, sourceName: String? = nil, kind: ServiceKind, image: String,
        domains: [String], baseURL: String?, healthPath: String?, keys: [ClonedKey],
        database: DatabaseClonePlan? = nil
    ) {
        self.name = name
        self.sourceName = sourceName ?? name
        self.kind = kind
        self.image = image
        self.domains = domains
        self.baseURL = baseURL
        self.healthPath = healthPath
        self.keys = keys
        self.database = database
    }

    /// Keys a person still has to supply before the clone will boot. Refused *optional* keys
    /// are excluded: the source setting one is worth reporting, but it blocks nothing.
    public var unresolved: [ClonedKey] {
        keys.filter { $0.disposition.needsPerson && $0.required }
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

    public init(
        source: String, target: String, environment: Environment, services: [ClonedService]
    ) {
        self.source = source
        self.target = target
        self.environment = environment
        self.services = services
    }

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
    public init() {}

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
        domains: [String],
        databaseMode: DatabaseCloneMode = .full
    ) async throws -> ClonedService {
        let contract = EnvContract.contract(for: service.kind, backend: source.backend)
        let secretKeys = Set(contract?.secret ?? [])
        var keys: [ClonedKey] = []

        // Whether this service gets a database of its own is the contract's call — not every
        // stack needs one — and its shape is the source's, mirrored: same server, new database
        // and roles, minted credentials. When no plan is possible the database keys fall
        // through to their old dispositions and stay with a person.
        let database = DatabaseClonePlanner.plan(
            service: service.kind, backend: source.backend, sourceConfig: sourceConfig,
            source: source, target: targetName, environment: environment, mode: databaseMode)

        for key in (contract?.required ?? []).sorted() {
            keys.append(
                classify(
                    key, required: true, secret: secretKeys.contains(key),
                    sourceConfig: sourceConfig, source: source,
                    targetName: targetName, environment: environment, database: database))
        }

        // Optional keys ride along only when the source actually sets them. An unset optional
        // key is nothing — reporting it would bury the lines that matter — but a set one is
        // part of how the source behaves, and dropping it silently made clones subtly slower,
        // quieter, or louder than the stack they were copied from.
        for key in (contract?.optional ?? []).sorted()
        where !(sourceConfig[key] ?? "").isEmpty && !(contract?.required.contains(key) ?? false) {
            keys.append(
                classify(
                    key, required: false, secret: secretKeys.contains(key),
                    sourceConfig: sourceConfig, source: source,
                    targetName: targetName, environment: environment, database: database))
        }

        // The clone-side name, through the same substitution the domains and URLs already
        // get: the service sharing its stack's name becomes the target, a sibling becomes
        // target-sibling. This is what the rewritten internal URLs were already promising —
        // `http://<target>-paylab.web.1:8080` names an app that has to exist under that name.
        let cloneName =
            Self.rewrite(service.name, from: source, to: targetName, environment: environment)
            ?? "\(targetName)-\(service.name)"

        return ClonedService(
            name: cloneName, sourceName: service.name, kind: service.kind, image: service.image,
            domains: domains,
            baseURL: service.baseURL.map {
                Self.rewrite($0, from: source, to: targetName, environment: environment) ?? $0
            },
            healthPath: service.healthPath,
            keys: keys,
            database: database)
    }

    private func classify(
        _ key: String,
        required: Bool,
        secret: Bool,
        sourceConfig: [String: String],
        source: StackSpec,
        targetName: String,
        environment: Environment,
        database: DatabaseClonePlan?
    ) -> ClonedKey {
        // 1. The stack's keypair, minted as a *pair* by the scaffolder at create. The plan
        // deliberately carries no value here: an earlier version minted a JWKS per service at
        // plan time and layered each over the scaffolder's shared one, leaving three services
        // that could not verify each other — and a demand for the private half of a key that
        // had been generated and thrown away.
        if key == "KEYPAIR_JWKS" || key == "PRIVATE_KEY_PEM" {
            return ClonedKey(
                key: key,
                disposition: .minted("a fresh keypair for the clone, shared across its services"),
                value: nil, secret: secret, required: required)
        }

        // 2. Database keys a fresh database resolves. Ahead of the refusals below: refusing
        // DATABASE_URL protects the source's database, and a database of the clone's own
        // protects it better — the clone cannot write to production through credentials that
        // never pointed there.
        if let database, database.emitted.contains(key) {
            return ClonedKey(
                key: key, disposition: .provisioned(database.summary),
                value: nil, secret: secret, required: required)
        }

        // 3. Values that exist only in the source environment. Copying DATABASE_URL is how a
        // staging stack quietly writes to the production database.
        if let reason = SecretPlanner.mustBeSupplied[key] {
            return ClonedKey(
                key: key, disposition: .refused(reason), value: nil, secret: secret,
                required: required)
        }

        // 3. Values that would grant the clone the source's authority — regenerated by the
        // scaffolder, which owns minting so that the whole stack agrees on the result.
        if Self.regenerated.contains(key) {
            return ClonedKey(
                key: key, disposition: .minted("random token, minted at create"),
                value: nil, secret: secret, required: required)
        }

        guard let value = sourceConfig[key], !value.isEmpty else {
            return ClonedKey(
                key: key, disposition: .refused("not set on \(source.name) either"),
                value: nil, secret: secret, required: required)
        }

        // 3. Values that name the source stack, its services, or its environment.
        if let rewritten = Self.rewrite(
            value, from: source, to: targetName, environment: environment) {
            return ClonedKey(
                key: key, disposition: .rewritten(from: value, to: rewritten),
                value: rewritten, secret: secret, required: required)
        }

        return ClonedKey(
            key: key, disposition: .carried, value: value, secret: secret, required: required)
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
        // stack name is not half-substituted. One pair per name: a service named after its own
        // stack (mwlab's is) must rewrite as the stack, not as a sort-order accident.
        var pairs: [(name: String, replacement: String)] = []
        for name in [source.name] + source.services.map(\.name)
        where !pairs.contains(where: { $0.name == name }) {
            pairs.append((name, name == source.name ? target : "\(target)-\(name)"))
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

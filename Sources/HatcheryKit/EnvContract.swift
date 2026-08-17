import Foundation

/// The environment keys a service needs, by backend.
///
/// This is the authoritative statement of what a service requires at boot. It exists
/// because the real contract is currently spread across a DO app-spec template, a
/// gitignored dokku config dump, and a stale README — and the three disagree.
public struct EnvContract: Sendable, Equatable {
    /// Absent or empty means the service will not boot.
    public var required: Set<String>
    /// Recognised and allowed, but not needed to boot.
    public var optional: Set<String>
    /// Values that must never be printed, logged, or committed.
    public var secret: Set<String>
    /// Keys that used to work and no longer do. Present means a latent boot failure.
    public var retired: Set<String>
    /// Injected by the platform. Not ours to declare, not drift.
    public var ignored: Set<String>
    /// Prefixes treated as `ignored`.
    public var ignoredPrefixes: [String]

    public init(
        required: Set<String> = [],
        optional: Set<String> = [],
        secret: Set<String> = [],
        retired: Set<String> = [],
        ignored: Set<String> = [],
        ignoredPrefixes: [String] = []
    ) {
        self.required = required
        self.optional = optional
        self.secret = secret
        self.retired = retired
        self.ignored = ignored
        self.ignoredPrefixes = ignoredPrefixes
    }

    public func isIgnored(_ key: String) -> Bool {
        ignored.contains(key) || ignoredPrefixes.contains { key.hasPrefix($0) }
    }

    public func isDeclared(_ key: String) -> Bool {
        required.contains(key) || optional.contains(key) || retired.contains(key)
    }

    /// Whether the contract knows this key under any heading.
    public func recognizes(_ key: String) -> Bool {
        isDeclared(key) || isIgnored(key) || secret.contains(key)
    }

    /// The keys in `updates` this contract does not know, ignoring removals: deleting a typo
    /// must not require spelling it correctly a second time.
    public func unknownKeys(in updates: [String: String]) -> [String] {
        updates.filter { !$0.value.isEmpty && !recognizes($0.key) }.map(\.key).sorted()
    }

    /// Contract keys within a small edit distance of a misspelled one, closest first.
    ///
    /// Case-blind and deliberately narrow: DATABSE_URL should find DATABASE_URL without
    /// offering the whole contract as consolation.
    public func nearest(to key: String, limit: Int = 3) -> [String] {
        let upper = key.uppercased()
        return required.union(optional).union(secret)
            .map { (name: $0, distance: Self.editDistance(upper, $0.uppercased())) }
            .filter { $0.distance <= max(2, key.count / 4) }
            .sorted { ($0.distance, $0.name) < ($1.distance, $1.name) }
            .prefix(limit)
            .map(\.name)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8)
        let b = Array(b.utf8)
        if a.isEmpty || b.isEmpty { return a.count + b.count }
        var previous = Array(0...b.count)
        for (i, characterA) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, characterB) in b.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + (characterA == characterB ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

extension EnvContract {
    /// The contract for a service kind on a backend, or `nil` if hatchery does not
    /// yet know that combination.
    public static func contract(for kind: ServiceKind, backend: Backend) -> EnvContract? {
        switch kind {
        case .mwserver: return mwserver(backend: backend)
        case .paymentGateway: return paymentGateway(backend: backend)
        case .communicationGateway: return communicationGateway(backend: backend)
        default: return nil
        }
    }

    /// Keys Dokku sets on every app.
    static let dokkuInjected: Set<String> = ["GIT_REV", "DOKKU_APP_TYPE", "DOKKU_PROXY_PORT_MAP"]

    /// The discrete connection keys retired by the 2026-07-28 connection-string cutover.
    static let discreteDatabaseKeys: Set<String> = [
        "DATABASE_HOST",
        "DATABASE_PORT",
        "DATABASE_USER",
        "DATABASE_PASSWORD",
        "DATABASE_DB",
        "DATABASE_APP_USER",
        "DATABASE_APP_PASSWORD",
    ]

    /// Keys whose absence traps at boot.
    ///
    /// Source of truth is the code, not a deploy template: `EnvironmentKeys.get(_:)` calls
    /// `fatalError` on a missing key, and `DatabaseURL.require(_:)` does the same. Every key
    /// below is read through one of those two paths on the current `dev`.
    ///
    /// `KEYPAIR_JWKS` and `PRIVATE_KEY_PEM` are the exception. They read optionally and fall
    /// back to `keypair.jwks` and `privatekey.pem` in the working directory. A deployed image
    /// carries neither file, so they are required in practice for every backend here.
    static let mwserverRequired: Set<String> = [
        "DATABASE_URL",
        "DATABASE_APP_URL",
        "APP_URL",
        "APP_ID",
        "LOG_LEVEL",
        "DATABASE_LOG_LEVEL",
        "PAYMENT_GATEWAY_URL",
        "PAYMENT_GATEWAY_TOKEN",
        "TEMPORAL_ADDRESS",
        "TEMPORAL_NAMESPACE",
        "KEYPAIR_JWKS",
        "PRIVATE_KEY_PEM",
    ]

    /// Keys the server reads but tolerates the absence of.
    ///
    /// `DATABASE_OWNER_URL` belongs here rather than with the required set: it falls back to
    /// `DATABASE_URL` where no owner pool exists, which is how local development and the tests run.
    static let mwserverOptional: Set<String> = [
        "DATABASE_OWNER_URL",
        "DATABASE_SSL_CERT",
        "DATABASE_SSL_CERT_PATH",
        "DATABASE_MAX_CONNECTIONS",
        "DATABASE_FLUENT_PER_LOOP",
        "DATABASE_PGCLIENT_MAX",
        "DATABASE_INFRA_MAX",
        "DATABASE_COMMAND_MAX_CONNECTIONS",
        "ALL_ERRORS",
        "NOISE_GATE_VALUE",
        "GSX_GATEWAY_HOST",
        "GSX_GATEWAY_PORT",
        "GSX_GATEWAY_TOKEN",
        "MAIL_OUTBOUND_DISCARD",
    ]

    static let mwserverSecret: Set<String> = [
        "DATABASE_URL",
        "DATABASE_OWNER_URL",
        "DATABASE_APP_URL",
        "DATABASE_PASSWORD",
        "DATABASE_APP_PASSWORD",
        "KEYPAIR_JWKS",
        "PRIVATE_KEY_PEM",
        "PAYMENT_GATEWAY_TOKEN",
        "GSX_GATEWAY_TOKEN",
    ]

    /// The contract tracks the current `dev` code for both backends, because the code decides
    /// what traps at boot and the code is the same wherever the image runs.
    ///
    /// The backends differ only in how they treat the discrete connection keys. On App Platform
    /// they are retired and their presence is a latent failure. On the self-hosted lab they are
    /// tolerated, because the box runs older images that still read them and removing them from
    /// a running app buys nothing.
    ///
    /// Validating an older lab config against this contract reports the keys that image never
    /// needed, such as the temporal pair. That is a true statement about the lab being behind,
    /// and it is the drift worth seeing rather than noise worth hiding.
    static func mwserver(backend: Backend) -> EnvContract {
        // MWServer opts into object storage. No other kind does yet, so no other kind may set its keys.
        EnvContract(
            required: mwserverRequired,
            optional: backend == .dokku
                ? mwserverOptional.union(discreteDatabaseKeys)
                : mwserverOptional,
            secret: mwserverSecret,
            retired: backend == .dokku ? [] : discreteDatabaseKeys,
            ignored: dokkuInjected
        )
        .uses(.vault)
    }

    static func paymentGateway(backend: Backend) -> EnvContract {
        // PaymentGateway fatals at boot without KEYPAIR_JWKS — verified on the lab box.
        var contract = EnvContract(
            required: ["KEYPAIR_JWKS", "APP_URL", "GATEWAY_ADMIN_TOKEN"],
            optional: ["APP_DOMAIN", "LOG_LEVEL", "STRIPE_API_KEY", "STRIPE_WEBHOOK_SECRET"],
            secret: [
                "KEYPAIR_JWKS", "GATEWAY_ADMIN_TOKEN",
                "STRIPE_API_KEY", "STRIPE_WEBHOOK_SECRET", "DATABASE_PASSWORD",
            ],
            ignored: dokkuInjected
        )
        switch backend {
        case .appPlatform, .aws, .cloudRun:
            // Neither has a postgres on the same box to reach with discrete keys; both take a
            // connection string, so the retired set is the same.
            contract.required.insert("DATABASE_URL")
            contract.retired = discreteDatabaseKeys
        case .dokku:
            contract.required.formUnion(["DATABASE_HOST", "DATABASE_USER", "DATABASE_PASSWORD", "DATABASE_DB"])
            contract.optional.insert("DATABASE_PORT")
        }
        return contract
    }

    static func communicationGateway(backend: Backend) -> EnvContract {
        var contract = EnvContract(
            required: ["KEYPAIR_JWKS", "APP_URL"],
            optional: ["APP_DOMAIN", "LOG_LEVEL"],
            secret: ["KEYPAIR_JWKS", "DATABASE_PASSWORD"],
            ignored: dokkuInjected
        )
        switch backend {
        case .appPlatform, .aws, .cloudRun:
            // Neither has a postgres on the same box to reach with discrete keys; both take a
            // connection string, so the retired set is the same.
            contract.required.insert("DATABASE_URL")
            contract.retired = discreteDatabaseKeys
        case .dokku:
            contract.required.formUnion(["DATABASE_HOST", "DATABASE_USER", "DATABASE_PASSWORD", "DATABASE_DB"])
            contract.optional.insert("DATABASE_PORT")
        }
        return contract
    }
}

// MARK: - Capabilities

extension EnvContract {
    /// A group of keys a service takes on by choice, rather than by being a particular kind.
    ///
    /// A kind says what a service *is*. A capability says what it *does*, and several kinds can do the same thing.
    /// Keeping the keys here means every kind that opts in agrees on their names, and a kind that never opts in still refuses them, which is the whole reason the contract rejects a key it does not know.
    public struct Capability: Sendable, Equatable {
        public let required: Set<String>
        public let optional: Set<String>
        public let secret: Set<String>

        public init(required: Set<String> = [], optional: Set<String> = [], secret: Set<String> = []) {
            self.required = required
            self.optional = optional
            self.secret = secret
        }

        /// Object storage collected from vault at start.
        ///
        /// Every key is optional, because a service that stores nothing boots and serves every route as before.
        /// The app key is the root credential: it collects the S3 key, so whatever holds it reaches everything that key reaches.
        public static let vault = Capability(
            optional: ["VAULT_BASE_URL", "VAULT_APP", "VAULT_APP_KEY"],
            secret: ["VAULT_APP_KEY"]
        )
    }

    /// The same contract, with one capability's keys recognised.
    public func uses(_ capability: Capability) -> EnvContract {
        EnvContract(
            required: self.required.union(capability.required),
            optional: self.optional.union(capability.optional),
            secret: self.secret.union(capability.secret),
            retired: self.retired,
            ignored: self.ignored,
            ignoredPrefixes: self.ignoredPrefixes
        )
    }
}

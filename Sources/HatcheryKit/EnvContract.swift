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

    static func mwserver(backend: Backend) -> EnvContract {
        switch backend {
        case .appPlatform:
            // Source of truth: MacWorkStack-infra deploy/tenant-template.yaml.
            // Connection strings are the only wire format; the app fails at boot
            // without DATABASE_URL.
            return EnvContract(
                required: [
                    "DATABASE_URL", "DATABASE_OWNER_URL", "DATABASE_APP_URL",
                    "KEYPAIR_JWKS", "PRIVATE_KEY_PEM",
                    "APP_URL", "APP_ID",
                    "PAYMENT_GATEWAY_URL", "PAYMENT_GATEWAY_TOKEN",
                ],
                optional: [
                    "DATABASE_SSL_CERT", "ALL_ERRORS", "LOG_LEVEL", "DATABASE_LOG_LEVEL",
                    "TEMPORAL_ADDRESS", "TEMPORAL_NAMESPACE",
                ],
                secret: [
                    "DATABASE_OWNER_URL", "DATABASE_APP_URL",
                    "KEYPAIR_JWKS", "PRIVATE_KEY_PEM", "PAYMENT_GATEWAY_TOKEN",
                ],
                retired: discreteDatabaseKeys,
                ignored: dokkuInjected
            )

        case .dokku:
            // The lab still runs pre-cutover images, so the discrete keys remain
            // legal here. They are optional, not retired.
            return EnvContract(
                required: [
                    "DATABASE_URL",
                    "KEYPAIR_JWKS", "PRIVATE_KEY_PEM",
                    "APP_URL", "APP_ID",
                    "PAYMENT_GATEWAY_URL", "PAYMENT_GATEWAY_TOKEN",
                ],
                optional: discreteDatabaseKeys.union([
                    "DATABASE_APP_URL", "DATABASE_SSL_CERT",
                    "ALL_ERRORS", "LOG_LEVEL", "DATABASE_LOG_LEVEL",
                ]),
                secret: [
                    "DATABASE_URL", "DATABASE_APP_URL",
                    "DATABASE_PASSWORD", "DATABASE_APP_PASSWORD",
                    "KEYPAIR_JWKS", "PRIVATE_KEY_PEM", "PAYMENT_GATEWAY_TOKEN",
                ],
                ignored: dokkuInjected
            )
        }
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
        case .appPlatform:
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
        case .appPlatform:
            contract.required.insert("DATABASE_URL")
            contract.retired = discreteDatabaseKeys
        case .dokku:
            contract.required.formUnion(["DATABASE_HOST", "DATABASE_USER", "DATABASE_PASSWORD", "DATABASE_DB"])
            contract.optional.insert("DATABASE_PORT")
        }
        return contract
    }
}

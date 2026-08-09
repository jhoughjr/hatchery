import Foundation

/// One thing a backend needs to know before it can be used.
///
/// Declared by the backend rather than asked for by the CLI, the API and the wizard separately.
/// Before this, `--host` was a dokku concept that every other backend had to ignore, a region was
/// a bare parameter threaded through three call sites, and the browser carried a `needsHost` flag
/// so it could special-case one backend. Adding a provider meant editing all of them.
public struct BackendSetting: Sendable, Codable, Equatable {
    /// Where a value legitimately comes from.
    public enum Source: String, Sendable, Codable {
        /// Supplied when the stack is created, and recorded in the manifest.
        case declared
        /// Read from the environment at apply time and never stored.
        case environment
    }

    public let key: String
    public let label: String
    /// What it is for, in a sentence a person can act on.
    public let help: String
    public let required: Bool
    /// Secrets are never written to the manifest, and never echoed back.
    public let secret: Bool
    public let defaultValue: String?
    public let source: Source
    /// The environment variable a value is read from, when the source is the environment.
    public let environmentKey: String?

    public init(
        key: String,
        label: String,
        help: String,
        required: Bool = true,
        secret: Bool = false,
        defaultValue: String? = nil,
        source: Source = .declared,
        environmentKey: String? = nil
    ) {
        self.key = key
        self.label = label
        self.help = help
        self.required = required
        self.secret = secret
        self.defaultValue = defaultValue
        self.source = source
        self.environmentKey = environmentKey
    }
}

extension Array where Element == BackendSetting {
    /// The values a caller has to supply, with defaults filled in.
    public func resolving(_ given: [String: String]) -> [String: String] {
        var values = given
        for setting in self where setting.source == .declared {
            if (values[setting.key] ?? "").isEmpty, let fallback = setting.defaultValue {
                values[setting.key] = fallback
            }
        }
        return values
    }

    /// What is still missing once defaults and the environment are taken into account.
    public func missing(
        from given: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [BackendSetting] {
        let resolved = resolving(given)
        return filter { setting in
            guard setting.required else { return false }
            switch setting.source {
            case .declared:
                return (resolved[setting.key] ?? "").isEmpty
            case .environment:
                guard let name = setting.environmentKey else { return false }
                return (environment[name] ?? "").isEmpty
            }
        }
    }

    /// The subset safe to record in a manifest: declared, and not secret.
    public func storable(_ values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for setting in self where setting.source == .declared && !setting.secret {
            if let value = values[setting.key], !value.isEmpty {
                result[setting.key] = value
            }
        }
        return result
    }

    public func setting(_ key: String) -> BackendSetting? {
        first { $0.key == key }
    }
}

/// Settings every dokku-like backend shares.
extension BackendSetting {
    public static let sshHost = BackendSetting(
        key: "host",
        label: "SSH target",
        help: """
            How hatchery reaches the box, as user@host. The user must be `dokku` — that account \
            turns an SSH command into a dokku command, and any other lands in a plain shell. \
            Given a bare address, hatchery adds `dokku@` for you; given a different user, it \
            tells you rather than rewriting what you typed.
            """,
        defaultValue: nil)

    public static let sshKey = BackendSetting(
        key: "ssh_key",
        label: "SSH private key",
        help: "The key authorized for the dokku user on that box.",
        required: false,
        defaultValue: "~/.ssh/id_rsa")

    public static let exposure = BackendSetting(
        key: "exposure",
        label: "Exposure provider",
        help: """
            How this stack's domains become reachable: none (say so on every plan), or \
            platform. Tunnel and LAN-DNS providers land in their own slices — see \
            docs/exposure-design.md.
            """,
        required: false)

    public static let dbAdmin = BackendSetting(
        key: "db_admin",
        label: "Database admin SSH target",
        help: """
            A shell account that can `docker exec` the database container, as user@host — only \
            needed when the stack's postgres is not a dokku app, because the dokku account \
            cannot reach a container dokku does not manage. Optional: without it, database \
            provisioning works only for dokku-app databases.
            """,
        required: false)

    public static func region(default value: String, help: String) -> BackendSetting {
        BackendSetting(key: "region", label: "Region", help: help, defaultValue: value)
    }
}

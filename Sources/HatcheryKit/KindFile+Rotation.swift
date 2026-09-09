import Foundation

// MARK: - Rotation

extension KindFile {
    /// How one secret is replaced: what issues the new value, and who holds it afterwards.
    ///
    /// A rotation is a declaration, not a runbook. `hatchery secrets rotate` reads this and executes it in the
    /// ruled order: the issuer first, then every holder's config, then every restart.
    public struct Rotation: Codable, Sendable, Equatable {
        public var issuer: Issuer
        public var holders: [Holder]

        public init(issuer: Issuer, holders: [Holder] = []) {
            self.issuer = issuer
            self.holders = holders
        }
    }

    /// What produces the new value for a secret.
    ///
    /// - `vaultAppKey`: vault mints a new app key for the service's own vault app, and answers it once.
    /// - `vaultS3Key`: vault rotates the app's S3 key pair, and answers both halves once.
    /// - `vaultSecret`: hatchery mints a value, and vault stores it under that name on that app.
    /// - `postgresRole`: a new password by `ALTER ROLE` on the named server's role.
    /// - `random`: hatchery mints this many bytes, because nothing else holds a claim on the value.
    /// - `manual`: a person issues it. The recipe is printed, and the run refuses to go on.
    ///
    /// `vaultAppKey` names no app, because the app is the service's own vault app and the service already
    /// names itself. Every other vault issuer names the app, so a service can rotate a value another app owns.
    public enum Issuer: Codable, Sendable, Equatable {
        case vaultAppKey
        case vaultS3Key(app: String)
        case vaultSecret(app: String, name: String)
        case postgresRole(server: String, role: String)
        case random(bytes: Int)
        case manual(recipe: String)

        private enum CodingKeys: String, CodingKey {
            case type, app, name, server, role, bytes, recipe
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "vaultAppKey":
                self = .vaultAppKey

            case "vaultS3Key":
                self = .vaultS3Key(app: try container.decode(String.self, forKey: .app))

            case "vaultSecret":
                self = .vaultSecret(
                    app: try container.decode(String.self, forKey: .app),
                    name: try container.decode(String.self, forKey: .name))

            case "postgresRole":
                self = .postgresRole(
                    server: try container.decode(String.self, forKey: .server),
                    role: try container.decode(String.self, forKey: .role))

            case "random":
                self = .random(bytes: try container.decodeIfPresent(Int.self, forKey: .bytes) ?? 32)

            case "manual":
                self = .manual(recipe: try container.decode(String.self, forKey: .recipe))

            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "'\(type)' is not an issuer hatchery knows")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .vaultAppKey:
                try container.encode("vaultAppKey", forKey: .type)

            case .vaultS3Key(let app):
                try container.encode("vaultS3Key", forKey: .type)
                try container.encode(app, forKey: .app)

            case .vaultSecret(let app, let name):
                try container.encode("vaultSecret", forKey: .type)
                try container.encode(app, forKey: .app)
                try container.encode(name, forKey: .name)

            case .postgresRole(let server, let role):
                try container.encode("postgresRole", forKey: .type)
                try container.encode(server, forKey: .server)
                try container.encode(role, forKey: .role)

            case .random(let bytes):
                try container.encode("random", forKey: .type)
                try container.encode(bytes, forKey: .bytes)

            case .manual(let recipe):
                try container.encode("manual", forKey: .type)
                try container.encode(recipe, forKey: .recipe)
            }
        }
    }

    /// Who carries the value after the issuer answers, and how that holder takes a new one.
    ///
    /// - `dokkuConfig`: a key in a dokku app's config, and the restart that key needs.
    /// - `roostrc`: a key in `~/.roostrc` on a host, over ssh.
    /// - `launchdEnvironment`: a key in a launchd plist's `EnvironmentVariables`, with the agent bootstrapped again.
    /// - `systemdEnvironment`: a key in a systemd unit's environment, with the unit started again.
    /// - `vaultSecret`: a holder that reads the value from vault at boot, so it takes no write and only restarts.
    ///
    /// A shared value has several holders, and every one of them is named here. A bearer invalidates every
    /// holder at once, so a holder this list forgets is the outage the declaration promised would not happen.
    public enum Holder: Codable, Sendable, Equatable {
        case dokkuConfig(app: String, key: String, restart: Restart)
        case roostrc(host: String, key: String)
        case launchdEnvironment(host: String, label: String, key: String)
        case systemdEnvironment(host: String, unit: String, key: String)
        case vaultSecret(app: String, name: String)

        private enum CodingKeys: String, CodingKey {
            case type, app, key, restart, host, label, unit, name
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "dokkuConfig":
                self = .dokkuConfig(
                    app: try container.decode(String.self, forKey: .app),
                    key: try container.decode(String.self, forKey: .key),
                    restart: try container.decodeIfPresent(Restart.self, forKey: .restart) ?? .rolling)

            case "roostrc":
                self = .roostrc(
                    host: try container.decode(String.self, forKey: .host),
                    key: try container.decode(String.self, forKey: .key))

            case "launchdEnvironment":
                self = .launchdEnvironment(
                    host: try container.decode(String.self, forKey: .host),
                    label: try container.decode(String.self, forKey: .label),
                    key: try container.decode(String.self, forKey: .key))

            case "systemdEnvironment":
                self = .systemdEnvironment(
                    host: try container.decode(String.self, forKey: .host),
                    unit: try container.decode(String.self, forKey: .unit),
                    key: try container.decode(String.self, forKey: .key))

            case "vaultSecret":
                self = .vaultSecret(
                    app: try container.decode(String.self, forKey: .app),
                    name: try container.decode(String.self, forKey: .name))

            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "'\(type)' is not a holder hatchery knows")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .dokkuConfig(let app, let key, let restart):
                try container.encode("dokkuConfig", forKey: .type)
                try container.encode(app, forKey: .app)
                try container.encode(key, forKey: .key)
                try container.encode(restart, forKey: .restart)

            case .roostrc(let host, let key):
                try container.encode("roostrc", forKey: .type)
                try container.encode(host, forKey: .host)
                try container.encode(key, forKey: .key)

            case .launchdEnvironment(let host, let label, let key):
                try container.encode("launchdEnvironment", forKey: .type)
                try container.encode(host, forKey: .host)
                try container.encode(label, forKey: .label)
                try container.encode(key, forKey: .key)

            case .systemdEnvironment(let host, let unit, let key):
                try container.encode("systemdEnvironment", forKey: .type)
                try container.encode(host, forKey: .host)
                try container.encode(unit, forKey: .unit)
                try container.encode(key, forKey: .key)

            case .vaultSecret(let app, let name):
                try container.encode("vaultSecret", forKey: .type)
                try container.encode(app, forKey: .app)
                try container.encode(name, forKey: .name)
            }
        }
    }

    /// How a dokku holder takes the new value.
    ///
    /// - `rolling`: `config:set` alone, which dokku follows with a rolling deploy.
    /// - `stopStart`: `config:set --no-restart`, then `ps:stop`, then `ps:start`.
    ///
    /// The forge needs `stopStart`. A rolling deploy leaves two forge containers alive at once, and the second
    /// one blocks on the database lock the first still holds.
    public enum Restart: String, Codable, Sendable, Equatable {
        case rolling
        case stopStart
    }
}

// MARK: - Reading the rotations a kind file declares

extension KindFile {
    /// Every key marked secret, sorted by name, with the rotation it declares.
    ///
    /// A secret with no rotation is listed too, with `nil`. That pair is what the audit reports and what the
    /// published counts count, so leaving it out would hide the gap this exists to show.
    public func secretRotations() -> [(key: String, rotation: Rotation?)] {
        self.environment
            .filter { $0.value.secret == true }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, rotation: $0.value.rotation) }
    }

    /// The keys `hatchery secrets rotate` can act on, sorted by name.
    public func rotatableKeys() -> [String] {
        self.secretRotations().filter { $0.rotation != nil }.map(\.key)
    }

    /// The rotation declared for one key, or `nil` when the key is not a secret or declares none.
    public func rotation(forKey key: String) -> Rotation? {
        self.environment[key]?.rotation
    }

    /// The rotatable keys grouped by the rotation they declare, in key order.
    ///
    /// The forge's S3 pair is why this exists. One issuer answers for both halves, so both keys declare the
    /// same rotation, and running that rotation once replaces the pair. Running it twice would mint a second
    /// pair and restart the forge a second time to reach the same place.
    public func rotationGroups() -> [(keys: [String], rotation: Rotation)] {
        var groups: [(keys: [String], rotation: Rotation)] = []
        for entry in self.secretRotations() {
            guard let rotation = entry.rotation else { continue }
            if let index = groups.firstIndex(where: { $0.rotation == rotation }) {
                groups[index].keys.append(entry.key)
            } else {
                groups.append((keys: [entry.key], rotation: rotation))
            }
        }
        return groups
    }
}

import Foundation

/// A service's own declaration: its kind, its health path, its port, and the environment keys
/// it reads. `KindRegistry` collects these beside the manifest, so adopt reads a service's word
/// instead of guessing from its image.
public struct KindFile: Codable, Sendable, Equatable {
    public var kind: String
    public var summary: String?
    public var image: String?
    public var port: Int?
    /// The proxy map dokku must hold for this service, in dokku's own `scheme:host:container` words.
    ///
    /// `port` is the port inside the container. This is the whole map, and the two are different facts: a deploy from an image re-detects the map from the image's `EXPOSE` and overwrites it, which leaves the app healthy and unreachable at its own name.
    /// Declaring it here is what lets the audit say the box has moved off the map. Absent means the service makes no claim, and nothing is compared.
    public var portMap: [String]?
    public var healthcheck: String?
    /// The names a resolver must answer, and the address each answer must carry.
    ///
    /// A `healthcheck` is an HTTP path, and a service that answers DNS cannot say anything about itself in that form.
    /// This is the same promise in the words its own protocol uses, and the audit asks the box's LAN address rather than its loopback: dnsmasq answering on loopback while binding nothing else is the exact fault this exists to catch.
    public var resolves: [Resolution]?
    public var notes: [String]?
    public var storage: [Mount]?
    public var environment: [String: EnvEntry]
    public var runner: [String: JSONValue]?
    public var bootstrap: [String]?
    /// The house services this kind asks hatchery to wire it into, `vault` being the one that exists.
    /// Absent on every kind file written before it, which is why nothing here is required to carry it.
    public var capabilities: [String]?

    /// One name a resolver must answer, and what it must answer with.
    ///
    /// - `name`: the name to ask for.
    /// - `answer`: the address the reply must carry. Absent asks only that a reply comes back, which is the weaker question of whether the resolver is alive at all.
    public struct Resolution: Codable, Sendable, Equatable {
        public var name: String
        public var answer: String?

        public init(name: String, answer: String? = nil) {
            self.name = name
            self.answer = answer
        }
    }

    /// A path the service persists across a redeploy, and the reason it must.
    public struct Mount: Codable, Sendable, Equatable {
        public var mount: String
        public var why: String?

        public init(mount: String, why: String? = nil) {
            self.mount = mount
            self.why = why
        }
    }

    /// One environment key, as the owning service asks it to be treated: its default, its
    /// deployed value, whether it is required, whether it is a secret, and how it rotates.
    public struct EnvEntry: Codable, Sendable, Equatable {
        public var `default`: String?
        public var deployed: String?
        public var example: String?
        public var required: Bool?
        public var secret: Bool?
        public var why: String?
        /// What issues a new value for this key, and who holds it.
        /// Absent on a key that is not a secret, and absent on a secret whose rotation nobody has declared,
        /// which is the `secret-no-rotation` finding. Optional, so every kind file written before it still reads.
        public var rotation: Rotation?

        public init(
            default: String? = nil, deployed: String? = nil, example: String? = nil,
            required: Bool? = nil, secret: Bool? = nil, why: String? = nil,
            rotation: Rotation? = nil
        ) {
            self.default = `default`
            self.deployed = deployed
            self.example = example
            self.required = required
            self.secret = secret
            self.why = why
            self.rotation = rotation
        }
    }

    public init(
        kind: String,
        summary: String? = nil,
        image: String? = nil,
        port: Int? = nil,
        portMap: [String]? = nil,
        healthcheck: String? = nil,
        resolves: [Resolution]? = nil,
        notes: [String]? = nil,
        storage: [Mount]? = nil,
        environment: [String: EnvEntry] = [:],
        runner: [String: JSONValue]? = nil,
        bootstrap: [String]? = nil,
        capabilities: [String]? = nil
    ) {
        self.kind = kind
        self.summary = summary
        self.image = image
        self.port = port
        self.portMap = portMap
        self.healthcheck = healthcheck
        self.resolves = resolves
        self.notes = notes
        self.storage = storage
        self.environment = environment
        self.runner = runner
        self.bootstrap = bootstrap
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case kind, summary, image, port, healthcheck, notes, storage, environment, runner, bootstrap
        case capabilities, portMap, resolves
    }

    /// `notes` decodes a single string or a list, so a one-line declaration needs no array wrapper.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(String.self, forKey: .kind)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.image = try container.decodeIfPresent(String.self, forKey: .image)
        self.port = try container.decodeIfPresent(Int.self, forKey: .port)
        self.portMap = try container.decodeIfPresent([String].self, forKey: .portMap)
        self.healthcheck = try container.decodeIfPresent(String.self, forKey: .healthcheck)
        self.resolves = try container.decodeIfPresent([Resolution].self, forKey: .resolves)
        self.storage = try container.decodeIfPresent([Mount].self, forKey: .storage)
        self.environment =
            try container.decodeIfPresent([String: EnvEntry].self, forKey: .environment) ?? [:]
        self.runner = try container.decodeIfPresent([String: JSONValue].self, forKey: .runner)
        self.bootstrap = try container.decodeIfPresent([String].self, forKey: .bootstrap)
        self.capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)

        if let single = try? container.decode(String.self, forKey: .notes) {
            self.notes = [single]
        } else {
            self.notes = try container.decodeIfPresent([String].self, forKey: .notes)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encodeIfPresent(portMap, forKey: .portMap)
        try container.encodeIfPresent(healthcheck, forKey: .healthcheck)
        try container.encodeIfPresent(resolves, forKey: .resolves)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(storage, forKey: .storage)
        try container.encode(environment, forKey: .environment)
        try container.encodeIfPresent(runner, forKey: .runner)
        try container.encodeIfPresent(bootstrap, forKey: .bootstrap)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
    }
}

/// The way a kind file fails to load.
///
/// - `invalidKind`: the file's `kind` is not lower-case letters, digits, and hyphens.
public enum KindFileError: Error, CustomStringConvertible, Equatable {
    case invalidKind(file: String, kind: String)

    public var description: String {
        switch self {
        case .invalidKind(let file, let kind):
            return "\(file) declares kind '\(kind)', which must be lower-case letters, digits, and hyphens"
        }
    }
}

extension KindFile {
    /// Lower-case letters, digits, and hyphens: the same set `DokkuProvider.identifier` folds
    /// a name into, so a kind that fails here would fail there too.
    static func isUsableKind(_ kind: String) -> Bool {
        guard !kind.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return kind.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Reads and decodes a kind file, refusing one whose `kind` is not a usable service name.
    public static func load(atPath path: String) throws -> KindFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let file = try JSONDecoder().decode(KindFile.self, from: data)
        guard isUsableKind(file.kind) else {
            throw KindFileError.invalidKind(file: path, kind: file.kind)
        }
        return file
    }

    /// The environment contract this file declares, in the shape the built-in kinds carry.
    ///
    /// A key is `required` when the file says so directly, or when it names a `deployed` value
    /// with no `default`, a key with nothing to fall back to. `secret` is read the same
    /// direct way; `optional` is everything else. No kind file declares a retired or an
    /// ignored key yet.
    public func contract(backend: Backend) -> EnvContract {
        var required: Set<String> = []
        var secret: Set<String> = []
        for (key, entry) in environment {
            if entry.required == true || (entry.deployed != nil && entry.default == nil) {
                required.insert(key)
            }
            if entry.secret == true {
                secret.insert(key)
            }
        }
        let optional = Set(environment.keys).subtracting(required)
        return EnvContract(
            required: required, optional: optional, secret: secret,
            capabilities: Set(self.capabilities ?? []))
    }
}

/// A JSON value with no assumed shape, so a loosely-shaped section like `runner` round-trips
/// without hatchery knowing its fields.
///
/// - `string`, `number`, `bool`, `null`: a JSON scalar.
/// - `object`: a JSON object, keyed the same way it decoded.
/// - `array`: a JSON array, in its decoded order.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unrecognised JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

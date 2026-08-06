import Foundation

/// Whether a service's declared config would let it boot.
public struct ConfigStatus: Sendable, Equatable, Codable {
    public let service: String
    /// Required keys with no value. These are why a service will not start.
    public let missing: [String]
    /// Keys present but not in the contract. Worth seeing, not worth blocking on.
    public let unexpected: [String]
    /// False when the declared file could not be read at all.
    public let found: Bool

    public init(service: String, missing: [String], unexpected: [String], found: Bool) {
        self.service = service
        self.missing = missing
        self.unexpected = unexpected
        self.found = found
    }

    /// Nothing would stop it booting.
    public var complete: Bool {
        found && missing.isEmpty
    }

    /// `complete` and `summary` are computed, and a computed property is not encoded — so the
    /// browser received neither and read every service as incomplete. They are written out
    /// explicitly rather than recomputed in JavaScript, so one definition decides it.
    private enum CodingKeys: String, CodingKey {
        case service, missing, unexpected, found, complete, summary
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(service, forKey: .service)
        try container.encode(missing, forKey: .missing)
        try container.encode(unexpected, forKey: .unexpected)
        try container.encode(found, forKey: .found)
        try container.encode(complete, forKey: .complete)
        try container.encodeIfPresent(summary, forKey: .summary)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        service = try container.decode(String.self, forKey: .service)
        missing = try container.decode([String].self, forKey: .missing)
        unexpected = try container.decode([String].self, forKey: .unexpected)
        found = try container.decode(Bool.self, forKey: .found)
    }

    /// What to show next to the service.
    public var summary: String? {
        if !found { return "no config file" }
        if missing.isEmpty { return nil }
        return missing.count == 1
            ? "1 required key missing" : "\(missing.count) required keys missing"
    }
}

/// Reads what a service declares and says whether it is enough.
///
/// The *declared* file rather than the running config, deliberately: this answers "would this
/// boot if applied", which is a local read and cheap enough to do on every poll. Asking the box
/// would mean an SSH round trip per service every ten seconds, to answer a different question —
/// `config audit` already asks that one.
public enum ConfigCompleteness {
    public static func check(
        service: ServiceSpec,
        in stack: StackSpec,
        manifestPath: String,
        read: (URL) throws -> [String: String] = { try ConfigSync.readDeclared(at: $0) }
    ) -> ConfigStatus {
        guard let contract = EnvContract.contract(for: service.kind, backend: stack.backend) else {
            return ConfigStatus(service: service.name, missing: [], unexpected: [], found: true)
        }
        let url = ConfigSync.configURL(for: service, in: stack, manifestPath: manifestPath)
        guard let declared = try? read(url) else {
            return ConfigStatus(
                service: service.name, missing: contract.required.sorted(),
                unexpected: [], found: false)
        }

        let missing = contract.required
            .filter { !contract.isIgnored($0) && (declared[$0] ?? "").isEmpty }
            .sorted()
        let unexpected = declared.keys
            .filter { !contract.isDeclared($0) && !contract.isIgnored($0) }
            .sorted()
        return ConfigStatus(
            service: service.name, missing: missing, unexpected: unexpected, found: true)
    }
}

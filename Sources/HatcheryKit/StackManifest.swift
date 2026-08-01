import Foundation

/// A service instance within a stack.
///
/// `configFile` points at a sidecar holding the resolved environment. The sidecar is
/// never committed — the manifest records *where* config lives, not what it contains.
public struct ServiceSpec: Codable, Sendable, Equatable {
    public var name: String
    public var kind: ServiceKind
    public var image: String
    public var domains: [String]
    public var configFile: String
    /// An explicit base URL, which overrides the address derived from `domains`.
    /// Both this and ``healthPath`` are optional, so a manifest written before them still reads.
    public var baseURL: String?
    /// The readiness path, which defaults to the path for this service kind.
    public var healthPath: String?
    /// The registry's identifier for this deployment, once one exists.
    ///
    /// hatchery never mints this. The administration tier is the identity mint, and its
    /// identifiers carry a `dep-` prefix. Carrying the value lets a report name the row the
    /// tier already knows about, rather than inventing a second name for the same thing.
    public var deploymentID: String?

    public init(
        name: String,
        kind: ServiceKind,
        image: String,
        domains: [String] = [],
        configFile: String,
        baseURL: String? = nil,
        healthPath: String? = nil,
        deploymentID: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.image = image
        self.domains = domains
        self.configFile = configFile
        self.baseURL = baseURL
        self.healthPath = healthPath

        self.deploymentID = deploymentID
    }
}

extension StackSpec {
    /// The address of the box, with any SSH user stripped.
    public var hostAddress: String? {
        guard let host, !host.isEmpty else { return nil }
        return host.split(separator: "@").last.map(String.init)
    }
}

extension ServiceSpec {
    /// Where to probe this service, or `nil` when nothing names an address.
    ///
    /// A dokku service is reached at the box rather than through its name, because a lab
    /// vhost usually has no public DNS record and the proxy routes on the `Host` header.
    /// Passing no stack falls back to the published name.
    public func healthRequest(in stack: StackSpec? = nil) -> HealthRequest? {
        let path = healthPath ?? kind.defaultHealthPath

        if let baseURL,
           let base = URL(string: baseURL),
           let url = URL(string: path, relativeTo: base)?.absoluteURL {
            return HealthRequest(url: url)
        }

        guard let vhost = domains.first, !vhost.isEmpty else { return nil }

        if let stack, stack.backend == .dokku, let address = stack.hostAddress,
           let url = URL(string: "http://\(address)\(path)") {
            return HealthRequest(url: url, hostHeader: vhost)
        }

        guard let url = URL(string: "\(Self.scheme(forHost: vhost))://\(vhost)\(path)") else {
            return nil
        }
        return HealthRequest(url: url)
    }

    /// The published address, ignoring any box-level routing.
    public func healthURL() -> URL? {
        healthRequest()?.url
    }

    /// A public name gets TLS. A single-label or lab-suffixed name is a LAN address that no
    /// tunnel fronts, so it stays plain HTTP and a probe does not fail on a certificate.
    static func scheme(forHost host: String) -> String {
        let lanSuffixes = [".opi", ".local", ".internal", ".lan"]
        guard host.contains(".") else { return "http" }
        return lanSuffixes.contains(where: { host.hasSuffix($0) }) ? "http" : "https"
    }
}

/// Which environment a stack belongs to.
///
/// This is deliberately separate from ``Backend``. The backend says where a service runs;
/// the environment says what it is for. The administration tier's registry treats environments
/// as first-class rows with an `is_prod` flag, so the names here match the ones it seeds.
public struct Environment: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let prod = Environment(rawValue: "prod")
    public static let staging = Environment(rawValue: "staging")
    public static let dev = Environment(rawValue: "dev")

    /// Whether an action against this environment deserves a confirmation.
    public var isProduction: Bool {
        self == .prod
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One deployable stack: a set of services on a single backend.
public struct StackSpec: Codable, Sendable, Equatable {
    public var name: String
    public var backend: Backend
    /// Defaults to `dev`, because an unlabelled stack is not production.
    public var environment: Environment?
    /// SSH target for `dokku`; ignored for App Platform.
    public var host: String?
    public var services: [ServiceSpec]

    public init(
        name: String,
        backend: Backend,
        environment: Environment? = nil,
        host: String? = nil,
        services: [ServiceSpec] = []
    ) {
        self.name = name
        self.backend = backend
        self.environment = environment
        self.host = host
        self.services = services
    }

    /// An unlabelled stack reads as `dev`. Guessing `prod` would arm a confirmation prompt that
    /// nobody asked for; guessing `dev` only ever errs toward doing what was asked.
    public var resolvedEnvironment: Environment {
        environment ?? .dev
    }
}

/// The declaration hatchery owns and commits.
///
/// This is intentionally *not* live state. It records what should exist; what is
/// actually running is queried from the backend on demand. Keeping the two apart
/// avoids the failure mode where a lost local state file orphans running apps.
public struct StackManifest: Codable, Sendable, Equatable {
    public var version: Int
    public var stacks: [StackSpec]

    public init(version: Int = 1, stacks: [StackSpec] = []) {
        self.version = version
        self.stacks = stacks
    }

    public func stack(named name: String) -> StackSpec? {
        stacks.first { $0.name == name }
    }
}

public enum ManifestError: Error, CustomStringConvertible, Equatable {
    case unsupportedVersion(Int)
    case invalidStackName(String)
    case duplicateStack(String)
    case missingHost(stack: String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "manifest version \(version) is not supported by this build of hatchery"
        case .invalidStackName(let name):
            return "stack name '\(name)' is invalid; expected ^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$"
        case .duplicateStack(let name):
            return "stack '\(name)' is declared more than once"
        case .missingHost(let stack):
            return "stack '\(stack)' targets dokku but declares no host"
        }
    }
}

extension StackManifest {
    public static let currentVersion = 1

    public static func decode(from data: Data) throws -> StackManifest {
        let manifest = try JSONDecoder().decode(StackManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw ManifestError.unsupportedVersion(version)
        }
        var seen = Set<String>()
        for stack in stacks {
            guard StackName.isValid(stack.name) else {
                throw ManifestError.invalidStackName(stack.name)
            }
            guard seen.insert(stack.name).inserted else {
                throw ManifestError.duplicateStack(stack.name)
            }
            if stack.backend == .dokku, (stack.host ?? "").isEmpty {
                throw ManifestError.missingHost(stack: stack.name)
            }
        }
    }
}

import Foundation

/// How the box runs one container: the shape `docker inspect` reports and `docker_container` declares.
///
/// This exists because a bare container carries its whole contract in its run arguments, where a dokku app
/// carries it in dokku's own state.
/// Nothing here is a secret: the environment stays in the sidecar and the secrets file, as it does for every other service.
public struct ContainerSpec: Codable, Sendable, Equatable {
    /// One path the container reads or writes, from a bind path or a named volume on the box.
    public struct Mount: Codable, Sendable, Equatable {
        /// A host path, or the name of a docker volume.
        public var source: String
        public var target: String
        public var readOnly: Bool

        public init(source: String, target: String, readOnly: Bool = false) {
            self.source = source
            self.target = target
            self.readOnly = readOnly
        }
    }

    /// One published port. `host` is the port on the box, and `container` the port inside it.
    public struct PortMap: Codable, Sendable, Equatable {
        public var host: Int
        public var container: Int
        public var `protocol`: String

        public init(host: Int, container: Int, protocol proto: String = "tcp") {
            self.host = host
            self.container = container
            self.protocol = proto
        }
    }

    public var image: String
    /// `host`, `bridge`, or the name of a docker network. Absent means the daemon's default.
    public var network: String?
    public var mounts: [Mount]
    public var ports: [PortMap]
    /// `unless-stopped`, `always`, `no`, or `on-failure`.
    public var restart: String
    /// The command, when it overrides the image's own. Absent means the image decides.
    public var command: [String]?
    public var privileged: Bool
    /// Extra `host:address` lines the container resolves, as `--add-host` writes them.
    public var extraHosts: [String]

    public init(
        image: String,
        network: String? = nil,
        mounts: [Mount] = [],
        ports: [PortMap] = [],
        restart: String = "unless-stopped",
        command: [String]? = nil,
        privileged: Bool = false,
        extraHosts: [String] = []
    ) {
        self.image = image
        self.network = network
        self.mounts = mounts
        self.ports = ports
        self.restart = restart
        self.command = command
        self.privileged = privileged
        self.extraHosts = extraHosts
    }
}

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
    /// Where this service's secret keys live, split out from `configFile`.
    ///
    /// Absent from most manifests. When absent, `ConfigSync.secretsURL(...)` derives the name
    /// by replacing `.config.json` with `.secrets.json`.
    public var secretsFile: String?
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
    /// The tofu variable whose default carries this service's image, when tofu owns the deploy.
    ///
    /// A service without one cannot be deployed by hatchery. That is the honest answer rather
    /// than a limitation: if nothing declares which variable moves, there is no way to change
    /// the image without going around the declaration that owns it.
    public var imageVariable: String?
    /// How the box runs this service as a container, for a service on the `host` backend.
    ///
    /// Absent for every other backend, and left out of the encoded manifest when absent.
    /// A manifest written before this therefore still reads, and a dokku manifest gains no empty field.
    public var container: ContainerSpec?

    public init(
        name: String,
        kind: ServiceKind,
        image: String,
        domains: [String] = [],
        configFile: String,
        secretsFile: String? = nil,
        baseURL: String? = nil,
        healthPath: String? = nil,
        deploymentID: String? = nil,
        imageVariable: String? = nil,
        container: ContainerSpec? = nil
    ) {
        self.name = name
        self.kind = kind
        self.image = image
        self.domains = domains
        self.configFile = configFile
        self.secretsFile = secretsFile
        self.baseURL = baseURL
        self.healthPath = healthPath

        self.deploymentID = deploymentID
        self.imageVariable = imageVariable
        self.container = container
    }
}

/// Where the OpenTofu configuration that owns a stack lives.
///
/// hatchery writes into this configuration and asks tofu what the write would do. It does not
/// reach past it to the backend, because the image is a declared attribute: setting it directly
/// would put two owners on one field and leave `tofu plan` permanently dirty.
public struct TofuBinding: Codable, Sendable, Equatable {
    /// The directory holding the configuration; `~` is expanded.
    public var directory: String
    /// The file declaring the image variables. Defaults to `variables.tf`.
    public var variablesFile: String?

    public init(directory: String, variablesFile: String? = nil) {
        self.directory = directory
        self.variablesFile = variablesFile
    }

    public var resolvedVariablesFile: String {
        variablesFile ?? "variables.tf"
    }

    public var variablesPath: String {
        Paths.join(Paths.expanded(directory), resolvedVariablesFile)
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

    /// The secrets sidecar name this service would use by convention.
    ///
    /// `nil` when `configFile` does not end in `.config.json`, the one name the sealing rule
    /// keys on. `ConfigSync.secretsURL(...)` uses this when `secretsFile` is not set explicitly.
    var conventionalSecretsFile: String? {
        guard configFile.hasSuffix(".config.json") else { return nil }
        return String(configFile.dropLast(".config.json".count)) + ".secrets.json"
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
    /// The OpenTofu configuration that owns this stack, when one does.
    public var tofu: TofuBinding?
    /// What the backend needed to know, as it declared it.
    ///
    /// Only declared, non-secret values live here. A token or a key is read from the environment
    /// at apply time, so a manifest can be committed without redacting anything.
    public var settings: [String: String]?
    public var services: [ServiceSpec]

    public init(
        name: String,
        backend: Backend,
        environment: Environment? = nil,
        host: String? = nil,
        tofu: TofuBinding? = nil,
        settings: [String: String]? = nil,
        services: [ServiceSpec] = []
    ) {
        self.name = name
        self.backend = backend
        self.environment = environment
        self.host = host
        self.tofu = tofu
        self.settings = settings
        self.services = services
    }

    public func service(named name: String) -> ServiceSpec? {
        services.first { $0.name == name }
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
    /// SSH targets saved by name, so a box is written once and referred to afterwards.
    public var hosts: [String: String]?
    /// Where this manifest publishes its declaration when it is written, as a pulse base URL.
    /// Absent means the declaration is read by hand with `hatchery declared`.
    public var publish: String?

    public init(version: Int = 1, stacks: [StackSpec] = [], hosts: [String: String]? = nil) {
        self.version = version
        self.stacks = stacks
        self.hosts = hosts
        self.publish = nil
    }

    public init(version: Int = 1, stacks: [StackSpec] = [], hosts: [String: String]? = nil, publish: String?) {
        self.version = version
        self.stacks = stacks
        self.hosts = hosts
        self.publish = publish
    }

    /// The one door that writes a manifest to disk.
    /// When the manifest names a publish target, the declaration goes there as the write finishes, so the declared reading is true by construction.
    /// A publish that fails prints one line and never fails the write, because the manifest on disk is the record and pulse is the copy.
    public func write(to path: String) throws {
        try self.encoded().write(to: URL(fileURLWithPath: path))
        guard let target = self.publish, !target.isEmpty else { return }
        let document = Declaration(manifests: [(manifest: self, path: path)])
        if let reason = Declaration.publishSync(document, to: target) {
            FileHandle.standardError.write(Data("  publish: pulse did not take the declaration (\(reason))\n".utf8))
        } else {
            FileHandle.standardError.write(Data("  published the declaration to \(target)\n".utf8))
        }
    }

    public func stack(named name: String) -> StackSpec? {
        stacks.first { $0.name == name }
    }

    /// The same manifest without the named stack.
    ///
    /// The tofu directory and the config files are deliberately left on disk: they hold the
    /// state file and real secrets, and a command that removes a declaration should not also
    /// delete the only record of what was there.
    public func removing(stack name: String) -> StackManifest {
        var copy = self
        copy.stacks.removeAll { $0.name == name }
        return copy
    }

    /// The same manifest with one service's declared image changed.
    ///
    /// The manifest is the source of truth for what a service should run. A deploy that moved
    /// only the tofu variable would leave the declaration saying something that is no longer
    /// true, and the next `hatchery status` would report drift hatchery itself created.
    public func settingImage(stack stackName: String, service serviceName: String, to image: String) -> StackManifest {
        var copy = self
        for stackIndex in copy.stacks.indices where copy.stacks[stackIndex].name == stackName {
            for serviceIndex in copy.stacks[stackIndex].services.indices
            where copy.stacks[stackIndex].services[serviceIndex].name == serviceName {
                copy.stacks[stackIndex].services[serviceIndex].image = image
            }
        }
        return copy
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

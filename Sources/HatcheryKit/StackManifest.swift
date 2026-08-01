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

    public init(
        name: String,
        kind: ServiceKind,
        image: String,
        domains: [String] = [],
        configFile: String
    ) {
        self.name = name
        self.kind = kind
        self.image = image
        self.domains = domains
        self.configFile = configFile
    }
}

/// One deployable stack: a set of services on a single backend.
public struct StackSpec: Codable, Sendable, Equatable {
    public var name: String
    public var backend: Backend
    /// SSH target for `dokku`; ignored for App Platform.
    public var host: String?
    public var services: [ServiceSpec]

    public init(name: String, backend: Backend, host: String? = nil, services: [ServiceSpec] = []) {
        self.name = name
        self.backend = backend
        self.host = host
        self.services = services
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

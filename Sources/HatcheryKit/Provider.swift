import Foundation

public enum ProviderError: Error, CustomStringConvertible, Equatable {
    case noProvider(Backend)
    case missingDetail(String)

    public var description: String {
        switch self {
        case .noProvider(let backend):
            return "hatchery cannot author a service for \(backend.rawValue) yet"
        case .missingDetail(let detail):
            return "cannot author this service without \(detail)"
        }
    }
}

/// A file hatchery would write, and whether something is already there.
public struct GeneratedFile: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// The backend's declaration of the service.
        case declaration
        /// The service's environment, which is never committed.
        case config
        /// An addition to the variables file rather than a whole file.
        case variableAppend
    }

    public let path: String
    public let contents: String
    public let role: Role

    public init(path: String, contents: String, role: Role) {
        self.path = path
        self.contents = contents
        self.role = role
    }
}

/// Everything a provider needs to author one service.
public struct ScaffoldRequest: Sendable, Equatable {
    public var stack: StackSpec
    public var service: ServiceSpec
    /// The port the container listens on.
    public var containerPort: Int
    /// A docker network the app must join to reach its database, when the backend has one.
    public var network: String?
    /// Whether the declaration is gated behind an `enable_<name>` variable, as the lab's are.
    public var gated: Bool

    public init(
        stack: StackSpec,
        service: ServiceSpec,
        containerPort: Int = 8080,
        network: String? = nil,
        gated: Bool = false
    ) {
        self.stack = stack
        self.service = service
        self.containerPort = containerPort
        self.network = network
        self.gated = gated
    }
}

/// What a backend must supply for hatchery to author a service into it.
///
/// This is the seam a new provider arrives through. Adding AWS or App Platform means adding a
/// type that conforms here, rather than adding a `switch` arm inside every verb — which is the
/// shape the dokku-only verbs currently have and the reason they each throw `unsupportedBackend`.
public protocol ServiceProvider: Sendable {
    var backend: Backend { get }

    /// The files that declare this service to the backend.
    func declaration(for request: ScaffoldRequest) throws -> [GeneratedFile]

    /// The variable that carries the image, when the backend routes deploys through one.
    func imageVariable(for request: ScaffoldRequest) -> String?

    /// The name of the variable above, so the manifest can record it.
    func imageVariableName(for request: ScaffoldRequest) -> String?
}

public enum Providers {
    /// Every backend hatchery can author into today.
    public static func provider(for backend: Backend) throws -> any ServiceProvider {
        switch backend {
        case .dokku:
            return DokkuProvider()
        case .appPlatform:
            // App Platform is a real config contract but not yet an action backend. Throwing
            // here is the honest answer; a half-written spec would be worse than none.
            throw ProviderError.noProvider(.appPlatform)
        }
    }
}

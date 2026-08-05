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

    /// A name for a person rather than the raw value.
    var displayName: String { get }

    /// Whether hatchery can create a stack on this backend today.
    ///
    /// A backend can be known — its config contract understood, its live state readable — long
    /// before hatchery can author one from nothing. Saying which is which stops the UI offering
    /// a menu entry that fails after the form is filled in.
    var authorable: Bool { get }

    /// How to get this backend working from nothing, on the machine and wherever it runs.
    var setupSteps: [SetupStep] { get }

    /// Whether *this* machine is configured to use the backend.
    ///
    /// Each backend answers for itself: dokku needs a reachable box and an authorized key, AWS
    /// needs credentials and a region. Asking a single hardcoded checker would mean it knew
    /// about every backend, which is the shape this protocol exists to avoid.
    func readiness(host: String?, execute: @escaping CommandExecutor) async -> [PreflightCheck]

    /// The files that declare this service to the backend.
    func declaration(for request: ScaffoldRequest) throws -> [GeneratedFile]

    /// The variable that carries the image, when the backend routes deploys through one.
    func imageVariable(for request: ScaffoldRequest) -> String?

    /// The name of the variable above, so the manifest can record it.
    func imageVariableName(for request: ScaffoldRequest) -> String?

    /// The tofu configuration a stack on this backend starts from.
    func bootstrapFiles(host: String, sshKeyPath: String, region: String?) -> [GeneratedFile]
}

extension ServiceProvider {
    public var displayName: String { backend.rawValue }
}

public enum Providers {
    /// One support type per backend, whether or not it can be authored yet.
    ///
    /// Every backend has an entry, because "can I use this here?" and "can hatchery create one?"
    /// are different questions and only the second has a negative answer for App Platform.
    public static func support(for backend: Backend) -> any ServiceProvider {
        switch backend {
        case .dokku: return DokkuProvider()
        case .aws: return AWSProvider()
        case .cloudRun: return CloudRunProvider()
        case .appPlatform: return AppPlatformProvider()
        }
    }

    public static var all: [any ServiceProvider] {
        Backend.allCases.map(support(for:))
    }

    /// The provider to author with, or an error naming the backend that cannot.
    public static func provider(for backend: Backend) throws -> any ServiceProvider {
        let support = support(for: backend)
        guard support.authorable else { throw ProviderError.noProvider(backend) }
        return support
    }
}

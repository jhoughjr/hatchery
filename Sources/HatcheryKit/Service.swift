import Foundation

/// A kind of deployable service.
///
/// Deliberately not an enum: hatchery targets MWServer stacks first, but the model
/// stays open so other services drop in without editing this type.
public struct ServiceKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let mwserver = ServiceKind(rawValue: "mwserver")
    public static let paymentGateway = ServiceKind(rawValue: "payment-gateway")
    public static let communicationGateway = ServiceKind(rawValue: "communication-gateway")

    /// Kinds hatchery ships a contract for today.
    public static let known: [ServiceKind] = [.mwserver, .paymentGateway, .communicationGateway]

    /// Where this kind answers a readiness probe.
    ///
    /// MWServer mounts its route beside the rest of its API, under `/api`. The gateways come
    /// from the shared microservice template and answer at the root. Verified against the lab:
    /// `/api/metrics` is 200 on mwserver and 404 on both gateways, and `/health` is the reverse.
    public var defaultHealthPath: String {
        switch self {
        case .mwserver: return "/api/health"
        default: return "/health"
        }
    }

    // Encode as a bare string rather than the synthesised `{"rawValue": …}` wrapper,
    // so manifests stay readable and hand-editable.
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where a stack runs.
///
/// The two planes differ in more than credentials: the App Platform tenant plane
/// dropped discrete `DATABASE_*` keys on 2026-07-28, while the self-hosted lab still
/// runs pre-cutover images. `EnvContract` encodes that difference.
public enum Backend: String, Codable, Sendable, CaseIterable {
    /// Self-hosted Dokku over SSH — the opi box and the Raspberry Pi fleet.
    case dokku
    /// DigitalOcean App Platform — the production tenant plane.
    case appPlatform
}

extension Backend {
    public var isSelfHosted: Bool {
        self == .dokku
    }
}

/// Naming rule shared with `new-tenant.sh`, so a name valid here is valid there.
public enum StackName {
    public static func isValid(_ name: String) -> Bool {
        // ^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$
        guard (3...30).contains(name.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let first = name.first, let last = name.last else { return false }
        return first != "-" && last != "-"
    }
}

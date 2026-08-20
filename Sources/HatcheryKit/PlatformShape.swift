import Foundation

/// What a value that names an address on the source's box becomes on a hosted platform.
///
/// A dokku box gives every app a docker network, so services name each other as
/// `http://paylab.web.1:8080` and a box-local service as `mwserver-temporal:7233`. App
/// Platform authors one app per service and no shared network, so neither address exists
/// there. A sibling is reachable only at the public domain its own app declares, and a
/// box-local service with no sibling behind it is reachable by nobody. The plan says which
/// is which, and refuses the second rather than carrying an address that resolves to nothing.
public enum PlatformShape {
    /// How a platform lays a stack's services out, which decides how siblings meet.
    public enum Layout: Sendable, Equatable {
        /// One platform app per service. Siblings meet at each other's public domain.
        case appPerService
        /// One platform app, one component per service. Siblings meet on the app's private
        /// network as `http://<component>:<port>`.
        case components
    }

    public enum Outcome: Equatable, Sendable {
        /// The value named a sibling, and this is the sibling's address on the platform.
        case sibling(String)
        /// The value named a host that exists only on the source's box.
        case boxLocal(host: String)
    }

    /// Domain suffixes that resolve only on a LAN, which a platform cannot serve.
    static let boxLocalSuffixes: Set<String> = ["opi", "local", "lan", "home", "internal"]

    /// Whether a domain is one a platform can serve: more than one label, and a public last one.
    public static func isPublic(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".")
        guard labels.count > 1, let last = labels.last else { return false }
        return !boxLocalSuffixes.contains(String(last).lowercased())
    }

    /// The domains a platform clone keeps: the public ones.
    public static func publicDomains(_ domains: [String]) -> [String] {
        domains.filter(isPublic)
    }

    /// What `value` becomes on the platform, or nil when it names no box address at all.
    ///
    /// `siblingDomains` maps each source service name to the clone's public domains for it,
    /// and `siblingNames` to the clone-side name of its component. The layout picks which
    /// one a sibling address is built from.
    public static func rewrite(
        _ value: String, source: StackSpec, layout: Layout,
        siblingDomains: [String: [String]], siblingNames: [String: String] = [:]
    ) -> Outcome? {
        guard let host = host(of: value) else { return nil }
        // `paylab.web.1` and `paylab` both name the paylab app.
        let app = host.hasSuffix(".web.1") ? String(host.dropLast(".web.1".count)) : host
        if source.services.contains(where: { $0.name == app }) {
            switch layout {
            case .appPerService:
                guard let domain = siblingDomains[app]?.first else {
                    return .boxLocal(host: host)
                }
                return .sibling("https://\(domain)")
            case .components:
                let component = siblingNames[app] ?? app
                let port = port(of: value).map { ":\($0)" } ?? ""
                return .sibling("http://\(component)\(port)")
            }
        }
        // A bare single-label host is a name on the box's network. Anything with a dot is
        // an address somewhere the platform can also reach.
        guard !host.contains("."), host != "localhost" else { return nil }
        return .boxLocal(host: host)
    }

    /// The port a value addresses, when it says one.
    static func port(of value: String) -> Int? {
        if value.contains("://") { return URLComponents(string: value)?.port }
        let parts = value.split(separator: ":")
        return parts.count == 2 ? Int(parts[1]) : nil
    }

    /// The host a value addresses, when it is shaped like an address: a URL, or `host:port`.
    static func host(of value: String) -> String? {
        if value.contains("://") {
            return URLComponents(string: value)?.host
        }
        let parts = value.split(separator: ":")
        guard parts.count == 2, Int(parts[1]) != nil else { return nil }
        let host = String(parts[0])
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard !host.isEmpty, host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return host
    }
}

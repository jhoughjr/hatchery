import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP exchange, so a test drives a recorded answer instead of a socket.
public typealias HTTPExchange = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// The way a vault admin route refuses or fails.
///
/// - `refused`: the session is not a signed-in admin's, or vault does not hold the app.
/// - `failed`: vault answered a status this route does not document, with whatever it said.
/// - `unreadable`: vault answered 200 without the field the route promises.
/// - `badSecretName`: a name is not `[A-Z][A-Z0-9_]{0,63}`, which vault refuses the whole call for.
public enum VaultAdminError: Error, CustomStringConvertible, Equatable {
    case refused(route: String, message: String)
    case failed(route: String, status: Int, message: String)
    case unreadable(route: String, field: String)
    case badSecretName(String)

    public var description: String {
        switch self {
        case .refused(let route, let message):
            return "vault refused \(route): \(message)"

        case .failed(let route, let status, let message):
            return "vault answered \(status) on \(route): \(message)"

        case .unreadable(let route, let field):
            return "vault answered \(route) without a \(field), which the route promises"

        case .badSecretName(let name):
            return "\(name) is not a secret name of A-Z, 0-9 and underscores that starts with a letter"
        }
    }
}

/// Vault's admin routes, which mint the values a rotation issues.
///
/// Every route here answers its value once. Vault stores only the sealed form, so a value not written down in
/// the same breath is a value nobody can read again, which is why the executor records before it tells a holder.
///
/// The gate is a signed-in admin's `vault_session` cookie, read from the environment by ``VaultSession``.
public struct VaultAdmin: Sendable {
    public static let defaultBaseURL = "https://vault.jimmyhoughjr.net"
    public static let sessionCookie = "vault_session"

    private let baseURL: String
    private let session: String
    private let exchange: HTTPExchange

    public init(
        baseURL: String = VaultAdmin.defaultBaseURL,
        session: String,
        exchange: @escaping HTTPExchange = VaultAdmin.live
    ) {
        self.baseURL = baseURL
        self.session = session
        self.exchange = exchange
    }

    /// Registers an app with vault, and answers the app key vault shows once.
    ///
    /// An app vault already holds is left exactly as it is, and this answers `nil` for it. Registration is
    /// the one route that both creates an app and shows a key, so a caller that gets `nil` and still needs a
    /// key asks ``rotateAppKey(app:)`` for one.
    public func registerApp(slug: String, name: String? = nil) async throws -> String? {
        let route = "/api/admin/apps"
        var payload: [String: Any] = ["slug": slug]
        if let name { payload["name"] = name }
        do {
            let answer = try await self.call(
                route, method: "POST", body: try JSONSerialization.data(withJSONObject: payload))
            guard let key = answer["app_key"] as? String, !key.isEmpty else {
                throw VaultAdminError.unreadable(route: route, field: "app_key")
            }
            return key
        } catch let error as VaultAdminError {
            // 409 is vault saying it already holds the app, which is the answer a second run wants.
            guard case .failed(_, 409, _) = error else { throw error }
            return nil
        }
    }

    /// A new app key for an app, which stops the old one at the same moment.
    public func rotateAppKey(app: String) async throws -> String {
        let route = "/api/admin/apps/\(app)/key"
        let answer = try await self.call(route, method: "POST", body: nil)
        guard let key = answer["app_key"] as? String, !key.isEmpty else {
            throw VaultAdminError.unreadable(route: route, field: "app_key")
        }
        return key
    }

    /// A new S3 key pair for an app. Vault answers both halves once, so they are replaced together.
    public func rotateS3Key(app: String) async throws -> (accessKeyID: String, secretAccessKey: String) {
        let route = "/api/admin/apps/\(app)/s3key"
        let answer = try await self.call(route, method: "POST", body: Data("{}".utf8))
        guard let identifier = answer["access_key_id"] as? String, !identifier.isEmpty else {
            throw VaultAdminError.unreadable(route: route, field: "access_key_id")
        }
        guard let secret = answer["secret_access_key"] as? String, !secret.isEmpty else {
            throw VaultAdminError.unreadable(route: route, field: "secret_access_key")
        }
        return (identifier, secret)
    }

    /// Stores a named secret on an app, which the app reads back with its app key at boot.
    public func setSecret(app: String, name: String, value: String) async throws {
        let names = try await self.setSecrets(app: app, values: [name: value])
        guard names.contains(name) else {
            throw VaultAdminError.unreadable(route: Self.secretsRoute(app), field: "names")
        }
    }

    /// Merges named secrets into an app's document, and answers every name the document then holds.
    ///
    /// A merge and not a replacement, because the document is the app's whole boot environment and a caller
    /// setting one key must not take the rest away. The names are checked before the call, so one bad name
    /// says which name it was rather than arriving as a 400 that names a route.
    @discardableResult
    public func setSecrets(app: String, values: [String: String]) async throws -> [String] {
        if let bad = values.keys.sorted().first(where: { !Self.isValidSecretName($0) }) {
            throw VaultAdminError.badSecretName(bad)
        }
        let route = Self.secretsRoute(app)
        let body = try JSONSerialization.data(withJSONObject: values)
        let answer = try await self.call(route, method: "PUT", body: body)
        guard let names = answer["names"] as? [String] else {
            throw VaultAdminError.unreadable(route: route, field: "names")
        }
        return names
    }

    static func secretsRoute(_ app: String) -> String { "/api/admin/apps/\(app)/secrets" }

    /// A legal secret name is `[A-Z][A-Z0-9_]{0,63}`, which is vault's own rule for one.
    /// The shape is an environment variable's, because that is where the value lands in the app that reads it.
    public static func isValidSecretName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.first, ("A"..."Z").contains(first) else {
            return false
        }
        return name.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// One admin call, with the session as a cookie and the answer decoded as a JSON object.
    ///
    /// The session travels as a cookie header rather than as a bearer, because that is the credential vault's
    /// admin gate reads: it verifies the signed-in admin's own browser session and knows no other admin token.
    private func call(_ route: String, method: String, body: Data?) async throws -> [String: Any] {
        guard let url = URL(string: self.baseURL + route) else {
            throw VaultAdminError.unreadable(route: route, field: "address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("\(Self.sessionCookie)=\(self.session)", forHTTPHeaderField: "Cookie")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await self.exchange(request)
        let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = (decoded["error"] as? String) ?? String(decoding: data, as: UTF8.self)
        switch response.statusCode {
        case 200:
            return decoded

        case 401, 403, 404:
            throw VaultAdminError.refused(route: route, message: message)

        default:
            throw VaultAdminError.failed(route: route, status: response.statusCode, message: message)
        }
    }

    /// The exchange that reaches the real vault.
    public static let live: HTTPExchange = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VaultAdminError.failed(
                route: request.url?.path ?? "", status: 0, message: "no HTTP response")
        }
        return (data, http)
    }
}

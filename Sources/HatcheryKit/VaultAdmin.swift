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
public enum VaultAdminError: Error, CustomStringConvertible, Equatable {
    case refused(route: String, message: String)
    case failed(route: String, status: Int, message: String)
    case unreadable(route: String, field: String)

    public var description: String {
        switch self {
        case .refused(let route, let message):
            return "vault refused \(route): \(message)"

        case .failed(let route, let status, let message):
            return "vault answered \(status) on \(route): \(message)"

        case .unreadable(let route, let field):
            return "vault answered \(route) without a \(field), which the route promises"
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
        let route = "/api/admin/apps/\(app)/secrets"
        let body = try JSONSerialization.data(withJSONObject: [name: value])
        let answer = try await self.call(route, method: "PUT", body: body)
        guard let names = answer["names"] as? [String], names.contains(name) else {
            throw VaultAdminError.unreadable(route: route, field: "names")
        }
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

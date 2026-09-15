import Foundation

/// Keeps a forge container package to its newest versions and the ones a deployment runs.
///
/// CI pushes one image a commit, and the forge keeps every one. On 2026-09-15 the opi's root disk filled to its last 551 MB, most of it the
/// rookery and vault-hb images in the registry, and an image build then failed half way through its upload.
/// The package token lives in vault's `forge` app, so this reads it the way ``ForgeSecrets`` reads a CI secret, and no value reaches the terminal.
public struct ForgePackages: Sendable {
    /// One version of a container package, as the forge lists it.
    public struct Version: Sendable, Equatable {
        public var name: String
        public var version: String
        public var created: Date

        public init(name: String, version: String, created: Date) {
            self.name = name
            self.version = version
            self.created = created
        }
    }

    /// Why a prune cannot go ahead.
    ///
    /// - `noToken`: vault's `forge` app holds no FORGE_PACKAGE_TOKEN
    /// - `refused`: the forge refused a call, with the status it gave
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noToken
        case refused(route: String, status: Int)

        public var description: String {
            switch self {
            case .noToken:
                return "vault's forge app holds no FORGE_PACKAGE_TOKEN. Store one with package scope: pbpaste | hatchery forge seed FORGE_PACKAGE_TOKEN"
            case .refused(let route, let status):
                return "the forge refused \(route) with \(status)"
            }
        }
    }

    private let secrets: ForgeSecrets
    private let forgeBaseURL: String
    private let exchange: HTTPExchange

    public init(secrets: ForgeSecrets, forgeBaseURL: String = ForgeSecrets.forgeBaseURL, exchange: @escaping HTTPExchange = VaultAdmin.live) {
        self.secrets = secrets
        self.forgeBaseURL = forgeBaseURL
        self.exchange = exchange
    }

    /// The versions to delete: everything but the newest `keep`, `latest`, and any version that starts with one of `protect`.
    ///
    /// A version named by digest is kept too, because a tag can point at it and deleting it would break an image that is kept.
    public static func plan(_ versions: [Version], keep: Int, protect: [String]) -> [Version] {
        let tagged = versions.filter { !$0.version.hasPrefix("sha256:") }.sorted { $0.created > $1.created }
        let newest = Set(tagged.prefix(max(0, keep)).map(\.version))
        return tagged.filter { version in
            !newest.contains(version.version)
                && version.version != "latest"
                && !protect.contains { !$0.isEmpty && version.version.hasPrefix($0) }
        }
    }

    /// Every version of one container package the owner holds.
    public func versions(owner: String, package: String, token: String) async throws -> [Version] {
        var found: [Version] = []
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for page in 1...200 {
            let route = "/api/v1/packages/\(owner)?type=container&q=\(package)&limit=50&page=\(page)"
            let (data, response) = try await self.exchange(self.request(route, method: "GET", token: token))
            guard response.statusCode == 200 else { throw Failure.refused(route: route, status: response.statusCode) }
            let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            if rows.isEmpty { break }
            for row in rows where row["name"] as? String == package {
                guard let version = row["version"] as? String else { continue }
                let text = row["created_at"] as? String ?? ""
                let created = stamp.date(from: text) ?? plain.date(from: text) ?? .distantPast
                found.append(Version(name: package, version: version, created: created))
            }
        }
        return found
    }

    /// Deletes one version.
    public func delete(owner: String, _ version: Version, token: String) async throws {
        let escaped = version.version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? version.version
        let route = "/api/v1/packages/\(owner)/container/\(version.name)/\(escaped)"
        let (_, response) = try await self.exchange(self.request(route, method: "DELETE", token: token))
        guard [200, 204, 404].contains(response.statusCode) else { throw Failure.refused(route: route, status: response.statusCode) }
    }

    /// The package token, read once for a run with a key rotated for it.
    public func packageToken() async throws -> String {
        guard let value = try await self.secrets.document()["FORGE_PACKAGE_TOKEN"], !value.isEmpty else { throw Failure.noToken }
        return value
    }

    private func request(_ route: String, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: self.forgeBaseURL + route)!)
        request.httpMethod = method
        request.setValue("token " + token, forHTTPHeaderField: "Authorization")
        request.setValue("hatchery-forge-packages/1", forHTTPHeaderField: "User-Agent")
        return request
    }
}

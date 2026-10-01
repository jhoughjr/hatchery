import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The forge's CI secrets, kept once in vault and set on any repository that needs them.
///
/// A repository on the forge starts with no Actions secrets, and rookery's FORGE_PACKAGE_TOKEN had been set by hand, once.
/// On 2026-09-15 vault-hb's image job could not push, and nothing in the estate could give it the token.
/// The token now lives in the vault app named `forge`, and this sets it on a repository through the forge API, so nobody pastes it again.
///
/// Vault shows an app's secrets only to that app's key, and its admin routes never read a value back.
/// Nothing but hatchery reads the `forge` app, so hatchery rotates its key at each run and reads with the new one, and stores no key.
public struct ForgeSecrets: Sendable {
    public static let vaultApp = "forge"
    public static let forgeBaseURL = "https://forgejo.jimmyhoughjr.net"
    public static let defaultNames = ["FORGE_PACKAGE_TOKEN"]
    /// The repository a token scoped to issues is shown, when the user route refuses it.
    public static let scopeProbeRepo = "jimmy/house"

    /// What a run did for one secret on one repository.
    ///
    /// - `held`: the repository already holds the name, so nothing was written
    /// - `set`: the value was written to the repository
    public enum Outcome: String, Sendable, Equatable {
        case held, set
    }

    /// Why a run cannot set a secret.
    ///
    /// - `notSeeded`: vault's `forge` app holds no value for the name yet
    /// - `refused`: the forge refused a call, with the status it gave
    /// - `notAToken`: a `FORGE_` value the forge does not take as a token, so it is not stored
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notSeeded(String)
        case refused(route: String, status: Int)
        case notAToken(String)

        public var description: String {
            switch self {
            case .notSeeded(let name):
                return "vault's forge app holds no \(name). Store it once, with the value on standard input: pbpaste | hatchery forge seed \(name)"
            case .refused(let route, let status):
                return "the forge refused \(route) with \(status)"
            case .notAToken(let name):
                return "the value for \(name) is not a token the forge accepts, so it was not stored. Check what is on the clipboard and seed again"
            }
        }
    }

    private let vault: VaultAdmin
    private let vaultBaseURL: String
    private let forgeBaseURL: String
    /// The forge credential this machine holds, read at the moment it is used.
    private let forgeToken: @Sendable () throws -> String
    private let exchange: HTTPExchange

    public init(
        vault: VaultAdmin, vaultBaseURL: String = VaultAdmin.defaultBaseURL, forgeBaseURL: String = ForgeSecrets.forgeBaseURL,
        forgeToken: @escaping @Sendable () throws -> String = { try ForgeSecrets.gitCredential(host: "forgejo.jimmyhoughjr.net") },
        exchange: @escaping HTTPExchange = VaultAdmin.live
    ) {
        self.vault = vault
        self.vaultBaseURL = vaultBaseURL
        self.forgeBaseURL = forgeBaseURL
        self.forgeToken = forgeToken
        self.exchange = exchange
    }

    /// Stores a value in vault's `forge` app, registering the app the first time.
    ///
    /// A `FORGE_` value is shown to the forge first, and one the forge does not take as a token is refused.
    /// On 2026-09-15 a clipboard held something else, and a 51-character value with a line break in it was stored as the package token.
    /// The forge answers 401 for a value that is no token, and 403 for a real token scoped away from the account, so only 401 refuses.
    /// A token scoped to issues alone answers 401 on the user route too, so a 401 there is asked again at the issues of a
    /// repository, which such a token reads; on 2026-09-29 the read-only token for `forge-issue` was refused for that.
    public func seed(name: String, value: String) async throws {
        if name.hasPrefix("FORGE_") {
            guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw Failure.notAToken(name) }
            let accepted = try await ForgeTokenIssuer.accepts(value, forgeBaseURL: self.forgeBaseURL, exchange: self.exchange)
            guard accepted else { throw Failure.notAToken(name) }
        }
        _ = try await self.vault.registerApp(slug: Self.vaultApp, name: "Forge CI")
        try await self.vault.setSecret(app: Self.vaultApp, name: name, value: value)
    }

    /// Makes a repository hold each named secret, writing only the ones it does not hold, or all of them with `replace`.
    public func apply(repo: String, names: [String] = ForgeSecrets.defaultNames, replace: Bool = false) async throws -> [(name: String, outcome: Outcome)] {
        let held = try await self.repoSecretNames(repo)
        let needed = names.filter { replace || !held.contains($0) }
        let document = needed.isEmpty ? [:] : try await self.document()
        var done: [(name: String, outcome: Outcome)] = []
        for name in names {
            guard needed.contains(name) else {
                done.append((name, .held))
                continue
            }
            guard let value = document[name], !value.isEmpty else { throw Failure.notSeeded(name) }
            try await self.putRepoSecret(repo, name: name, value: value)
            done.append((name, .set))
        }
        return done
    }

    /// Writes a value to every repository whose Actions secrets hold this name, and answers those repositories in the forge's order.
    /// A rotation of the package token uses it, because a repository that keeps the retired token fails its next image push.
    public func replaceEverywhere(name: String, value: String) async throws -> [String] {
        var replaced: [String] = []
        for repo in try await self.repositories() where try await self.repoSecretNames(repo).contains(name) {
            try await self.putRepoSecret(repo, name: name, value: value)
            replaced.append(repo)
        }
        return replaced
    }

    /// Every repository the forge credential can see, by full name, read a page of fifty at a time.
    func repositories() async throws -> [String] {
        var names: [String] = []
        for page in 1... {
            let route = "/api/v1/repos/search?limit=50&page=\(page)"
            let (data, response) = try await self.exchange(try self.forgeRequest(route, method: "GET", body: nil))
            guard response.statusCode == 200 else { throw Failure.refused(route: route, status: response.statusCode) }
            let rows = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            guard !rows.isEmpty else { break }
            names += rows.compactMap { $0["full_name"] as? String }
        }
        return names
    }

    /// The `forge` app's document, read with a key rotated for this run.
    func document() async throws -> [String: String] {
        let key: String
        if let registered = try await self.vault.registerApp(slug: Self.vaultApp, name: "Forge CI") {
            key = registered
        } else {
            key = try await self.vault.rotateAppKey(app: Self.vaultApp)
        }
        var request = URLRequest(url: URL(string: "\(self.vaultBaseURL)/api/apps/\(Self.vaultApp)/secrets")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let (data, response) = try await self.exchange(request)
        guard response.statusCode == 200 else { throw Failure.refused(route: "vault's forge document", status: response.statusCode) }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func repoSecretNames(_ repo: String) async throws -> Set<String> {
        let route = "/api/v1/repos/\(repo)/actions/secrets"
        let (data, response) = try await self.exchange(try self.forgeRequest(route, method: "GET", body: nil))
        guard response.statusCode == 200 else { throw Failure.refused(route: route, status: response.statusCode) }
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return Set(rows.compactMap { $0["name"] as? String })
    }

    func putRepoSecret(_ repo: String, name: String, value: String) async throws {
        let route = "/api/v1/repos/\(repo)/actions/secrets/\(name)"
        let body = try JSONSerialization.data(withJSONObject: ["data": value])
        let (_, response) = try await self.exchange(try self.forgeRequest(route, method: "PUT", body: body))
        guard [200, 201, 204].contains(response.statusCode) else { throw Failure.refused(route: route, status: response.statusCode) }
    }

    private func forgeRequest(_ route: String, method: String, body: Data?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: self.forgeBaseURL + route)!)
        request.httpMethod = method
        request.setValue("token " + (try self.forgeToken()), forHTTPHeaderField: "Authorization")
        // The edge refuses a client that names no agent.
        request.setValue("hatchery-forge-secrets/1", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// The token git's credential helper holds for a host, which never passes through an argument or a file.
    public static func gitCredential(host: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "credential", "fill"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("protocol=https\nhost=\(host)\n\n".utf8))
        input.fileHandleForWriting.closeFile()
        let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let token = answer.split(separator: "\n").first(where: { $0.hasPrefix("password=") })?.dropFirst("password=".count),
              !token.isEmpty
        else { throw Failure.refused(route: "git credential fill for \(host)", status: 0) }
        return String(token)
    }
}

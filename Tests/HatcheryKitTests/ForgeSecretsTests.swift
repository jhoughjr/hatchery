import Foundation
import Testing

@testable import HatcheryKit

/// The forge's CI secrets, kept once in vault and set on repositories.
///
/// On 2026-09-15 vault-hb's image job could not push, because a new repository holds no Actions secrets and nothing could give it one.
@Suite("Forge secrets")
struct ForgeSecretsTests {
    /// A forge and a vault in memory, recording each call.
    private final class Estate: @unchecked Sendable {
        private let lock = NSLock()
        var repoNames: Set<String>
        var document: [String: String]
        var puts: [(route: String, body: String)] = []
        var seeded = false

        init(repoNames: Set<String>, document: [String: String]) {
            self.repoNames = repoNames
            self.document = document
        }

        func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            self.lock.lock()
            defer { self.lock.unlock() }
            let url = request.url!
            let path = url.path
            func answer(_ status: Int, _ body: Any) -> (Data, HTTPURLResponse) {
                (try! JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            switch (request.httpMethod ?? "GET", path) {
            case ("POST", "/api/admin/apps"): return answer(409, ["error": "exists"])
            case ("POST", "/api/admin/apps/forge/key"): return answer(200, ["app_key": "fresh-key"])
            case ("GET", "/api/apps/forge/secrets"):
                return request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-key" ? answer(200, self.document) : answer(401, [:])
            case ("GET", "/api/v1/user"):
                return request.value(forHTTPHeaderField: "Authorization") == "token good-token" ? answer(403, [:]) : answer(401, [:])
            case ("PUT", "/api/admin/apps/forge/secrets"):
                self.seeded = true
                return answer(200, ["names": ["FORGE_PACKAGE_TOKEN"]])
            case ("GET", "/api/v1/repos/jimmy/vault-hb/actions/secrets"):
                return answer(200, self.repoNames.map { ["name": $0] })
            case ("PUT", "/api/v1/repos/jimmy/vault-hb/actions/secrets/FORGE_PACKAGE_TOKEN"):
                self.puts.append((path, String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
                return answer(201, [:])
            default:
                return answer(404, ["error": "no route \(path)"])
            }
        }
    }

    private func secrets(_ estate: Estate) -> ForgeSecrets {
        let exchange: HTTPExchange = { estate.handle($0) }
        return ForgeSecrets(
            vault: VaultAdmin(baseURL: "https://vault.example", credential: .bearer("op"), exchange: exchange),
            vaultBaseURL: "https://vault.example", forgeBaseURL: "https://forge.example",
            forgeToken: { "forge-token" }, exchange: exchange)
    }

    @Test("A repository that lacks the secret gets the value vault holds")
    func setsWhatIsMissing() async throws {
        let estate = Estate(repoNames: [], document: ["FORGE_PACKAGE_TOKEN": "pkg-secret"])

        let steps = try await self.secrets(estate).apply(repo: "jimmy/vault-hb")

        #expect(steps.map(\.outcome) == [.set])
        #expect(estate.puts.first?.body.contains("pkg-secret") == true)
    }

    @Test("A repository that holds the secret is left alone, and vault is not asked")
    func holdsWhatIsThere() async throws {
        let estate = Estate(repoNames: ["FORGE_PACKAGE_TOKEN"], document: [:])

        let steps = try await self.secrets(estate).apply(repo: "jimmy/vault-hb")

        #expect(steps.map(\.outcome) == [.held])
        #expect(estate.puts.isEmpty)
    }

    @Test("A value vault does not hold yet says how to store it once, and writes nothing")
    func notSeededSaysHow() async throws {
        let estate = Estate(repoNames: [], document: [:])

        await #expect(throws: ForgeSecrets.Failure.notSeeded("FORGE_PACKAGE_TOKEN")) {
            _ = try await self.secrets(estate).apply(repo: "jimmy/vault-hb")
        }
        #expect(estate.puts.isEmpty)
        #expect(ForgeSecrets.Failure.notSeeded("FORGE_PACKAGE_TOKEN").description.contains("hatchery forge seed FORGE_PACKAGE_TOKEN"))
    }

    @Test("A value the forge does not take as a token is refused, and a scoped token is stored")
    func seedChecksTheToken() async throws {
        let estate = Estate(repoNames: [], document: [:])

        await #expect(throws: ForgeSecrets.Failure.notAToken("FORGE_PACKAGE_TOKEN")) {
            try await self.secrets(estate).seed(name: "FORGE_PACKAGE_TOKEN", value: "not a token\nfrom the clipboard")
        }
        #expect(estate.seeded == false)

        try await self.secrets(estate).seed(name: "FORGE_PACKAGE_TOKEN", value: "good-token")
        #expect(estate.seeded)
    }
}

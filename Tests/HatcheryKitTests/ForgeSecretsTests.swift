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

@Suite("Pruning forge packages")
struct ForgePackagesTests {
    @Test("the newest versions, latest, digests and protected commits stay, and the rest go")
    func plan() {
        let day: TimeInterval = 86_400
        let versions = (0..<8).map { ForgePackages.Version(name: "rookery", version: "c\($0)", created: Date(timeIntervalSince1970: Double($0) * day)) }
            + [ForgePackages.Version(name: "rookery", version: "latest", created: .distantPast),
               ForgePackages.Version(name: "rookery", version: "sha256:abc", created: .distantPast)]
        let doomed = ForgePackages.plan(versions, keep: 3, protect: ["c1"]).map(\.version)
        #expect(Set(doomed) == ["c0", "c2", "c3", "c4"])
    }

    @Test("the deployed tag is read from dokku's git report, and a report without an image names none")
    func deployedTag() {
        let report = """
            =====> rookery git information
                   Git deploy branch:             master
                   Git source image:              forgejo.jimmyhoughjr.net/jimmy/rookery:4c8397fe5b26
            """
        #expect(ForgePackages.sourceImageTag(inReport: report) == "4c8397fe5b26")
        #expect(ForgePackages.sourceImageTag(inReport: "Git source image:              ") == nil)
        #expect(ForgePackages.sourceImageTag(inReport: "Git source image: localhost:5000/rookery") == nil)
    }
}

@Suite("Images on a box")
struct BoxImagesTests {
    static let listing = """
    aaa 2026-09-16 10:00:00 -0500 CDT
    bbb 2026-09-16 09:00:00 -0500 CDT
    ccc 2026-09-15 22:00:00 -0500 CDT
    latest 2026-09-16 10:00:00 -0500 CDT
    <none> 2026-09-10 08:00:00 -0500 CDT
    """

    @Test("the newest, latest, and whatever the box runs are kept, and the rest go")
    func whatStays() {
        let kept = BoxImages.keeping(Self.listing, keep: 2, running: ["ccc"])
        #expect(kept.contains("aaa"))
        #expect(kept.contains("latest"))
        // The deployed one is kept even when it is not among the newest.
        #expect(kept.contains("ccc"))
        #expect(!kept.contains("<none>"))
    }

    @Test("a box that answers nothing removes nothing, rather than guessing")
    func aSilentBox() {
        let outcome = BoxImages.prune(box: "nowhere", repository: "r", keep: 2, running: []) { _, _ in (1, "") }
        #expect(outcome == nil)
    }

    @Test("only the images the box does not need are removed, and only of that one repository")
    func removesTheRest() {
        var asked: [String] = []
        let outcome = BoxImages.prune(box: "box", repository: "forge/x", keep: 1, running: []) { _, arguments in
            let command = arguments.last ?? ""
            asked.append(command)
            if command.hasPrefix("docker images") { return (0, Self.listing) }
            if command.hasPrefix("df") { return (0, "/dev/root 230G 100G 130G 44% /") }
            return (0, "done")
        }
        #expect(outcome?.removed.sorted() == ["bbb", "ccc"])
        #expect(asked.contains { $0.contains("docker rmi -f forge/x:") })
        #expect(!asked.contains { $0.contains("mwserver") })
        #expect(outcome?.freeAfter.contains("44%") == true)
    }
}

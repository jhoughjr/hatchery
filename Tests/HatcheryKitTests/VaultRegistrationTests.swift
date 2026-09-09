import Foundation
import Testing

@testable import HatcheryKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Vault's admin routes in memory, with one log of every call in the order it arrived.
///
/// One log rather than a per-route counter is the point. Registration decides whether a key is asked for at
/// all, so a suite that could not see the order could not tell a minted key from a replaced one.
private final class Console: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    /// The apps this vault already holds, which registration answers 409 for.
    private let known: Set<String>
    /// The status every route answers instead of its own, or zero when they answer normally.
    private let refusing: Int

    init(known: Set<String> = [], refusing: Int = 0) {
        self.known = known
        self.refusing = refusing
    }

    var happened: [String] { self.lock.withLock { self.log } }

    func exchange(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""
        let sent = request.httpBody.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        } ?? [:]
        self.lock.withLock { self.log.append("\(method) \(path) \(sent.keys.sorted().joined(separator: ","))") }

        if self.refusing != 0 {
            return try Self.answer(["error": "admin only"], status: self.refusing, to: request)
        }

        switch (method, path) {
        case ("POST", "/api/admin/apps"):
            let slug = sent["slug"] as? String ?? ""
            guard !self.known.contains(slug) else {
                return try Self.answer(["error": "\(slug) is already registered"], status: 409, to: request)
            }
            return try Self.answer(["ok": true, "slug": slug, "app_key": "sk_live_new"], to: request)

        case ("POST", "/api/admin/apps/rookery/key"):
            return try Self.answer(["ok": true, "app_key": "sk_live_replaced"], to: request)

        case ("PUT", "/api/admin/apps/rookery/secrets"):
            let names = (sent as? [String: String]).map { Array($0.keys).sorted() } ?? []
            return try Self.answer(["ok": true, "app": "rookery", "names": names], to: request)

        default:
            return try Self.answer(["error": "no such route"], status: 404, to: request)
        }
    }

    private static func answer(
        _ body: [String: Any], status: Int = 200, to request: URLRequest
    ) throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}

private func registrar(_ console: Console) -> VaultRegistrar {
    VaultRegistrar(
        vault: VaultAdmin(
            baseURL: "https://vault.example", session: "cookie",
            exchange: { try console.exchange($0) }),
        baseURL: "https://vault.example")
}

@Suite("Registering a declared service with vault")
struct VaultRegistrationTests {
    @Test("a new app is registered, and the key registration shows once lands in the config")
    func registersAndMints() async throws {
        let console = Console()
        let registration = try await registrar(console).register(app: "rookery")

        #expect(registration.registered)
        #expect(registration.mintedKey)
        #expect(registration.keys[VaultRegistrar.appKeyKey] == "sk_live_new")
        #expect(registration.keys[VaultRegistrar.urlKey] == "https://vault.example")
        #expect(registration.keys[VaultRegistrar.appNameKey] == "rookery")
        // Registration answered the key, so the replacement route was never reached.
        #expect(console.happened == ["POST /api/admin/apps slug"])
    }

    @Test("an app vault already holds is left as it is")
    func existingAppIsLeftAlone() async throws {
        let console = Console(known: ["rookery"])
        let registration = try await registrar(console).register(app: "rookery", holding: "sk_live_held")

        #expect(!registration.registered)
        #expect(!registration.mintedKey)
        #expect(registration.keys[VaultRegistrar.appKeyKey] == nil)
        #expect(console.happened == ["POST /api/admin/apps slug"])
    }

    @Test("an app vault holds with no key in the config gets one from the replacement route")
    func existingAppWithoutAKey() async throws {
        let console = Console(known: ["rookery"])
        let registration = try await registrar(console).register(app: "rookery")

        #expect(!registration.registered)
        #expect(registration.mintedKey)
        #expect(registration.keys[VaultRegistrar.appKeyKey] == "sk_live_replaced")
        #expect(console.happened.last == "POST /api/admin/apps/rookery/key ")
    }

    @Test("the secrets reach the document, and the report names them without a value")
    func setsSecrets() async throws {
        let console = Console()
        let registration = try await registrar(console).register(
            app: "rookery", secrets: ["FORGE_TOKEN": "tok", "DATABASE_URL": "postgres://x"])

        #expect(registration.secretNames == ["DATABASE_URL", "FORGE_TOKEN"])
        #expect(console.happened.contains("PUT /api/admin/apps/rookery/secrets DATABASE_URL,FORGE_TOKEN"))
        let printed = registration.lines().joined(separator: "\n")
        #expect(printed.contains("DATABASE_URL + FORGE_TOKEN"))
        #expect(!printed.contains("tok"))
        #expect(!printed.contains("sk_live_new"))
    }

    @Test("a refused session refuses the run and names the route")
    func refusedSession() async throws {
        let console = Console(refusing: 403)
        await #expect(throws: VaultAdminError.self) {
            _ = try await registrar(console).register(app: "rookery")
        }
    }

    @Test("a name outside vault's shape refuses the whole call before anything is sent")
    func badSecretName() async throws {
        let console = Console()
        await #expect(throws: VaultAdminError.badSecretName("forge-token")) {
            _ = try await registrar(console).register(app: "rookery", secrets: ["forge-token": "tok"])
        }
        #expect(!console.happened.contains { $0.hasPrefix("PUT") })
    }

    @Test("the document takes the secret-marked keys, and never the three vault keys")
    func documentSecretsLeavesTheVaultKeysOut() {
        let contract = EnvContract(
            required: ["PORT"],
            secret: ["FORGE_TOKEN", "DATABASE_URL", VaultRegistrar.appKeyKey])
        let values = VaultRegistrar.documentSecrets(
            in: [
                "PORT": "8080", "FORGE_TOKEN": "tok", "DATABASE_URL": "",
                VaultRegistrar.appKeyKey: "sk_live_held", VaultRegistrar.urlKey: "https://vault.example",
            ],
            contract: contract)

        // DATABASE_URL is declared and empty, which is a key waiting for a value and not a secret to store.
        #expect(values == ["FORGE_TOKEN": "tok"])
    }

    @Test("a kind file's vault capability is what asks adopt to register the service")
    func theCapabilityIsDeclared() throws {
        let declared = """
            {"kind": "rookery", "capabilities": ["vault"],
             "environment": {"FORGE_TOKEN": {"secret": true}}}
            """
        let file = try JSONDecoder().decode(KindFile.self, from: Data(declared.utf8))

        #expect(file.capabilities == ["vault"])
        #expect(file.contract(backend: .dokku).declaresVault)
        #expect(!KindFile(kind: "plain").contract(backend: .dokku).declaresVault)
    }
}

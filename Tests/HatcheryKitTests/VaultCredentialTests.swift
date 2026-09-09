import Foundation
import Testing

@testable import HatcheryKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A vault that records the header of every call, so a test reads what reached the request.
///
/// The whole point of this suite is the header, so the recorder keeps the header and not the body.
private final class HeaderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: String] = [:]

    var headers: [String: String] { self.lock.withLock { self.seen } }

    func exchange(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.lock.withLock { self.seen = request.allHTTPHeaderFields ?? [:] }
        let body: [String: Any] = [
            "ok": true,
            "app_key": "sk_live_new",
            "email": "jimmy@example.com",
            "token_name": "the mini",
        ]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}

/// A store rooted in a fresh temporary directory, so no test reads or writes the real one.
private func temporaryStore() -> VaultTokenStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hatchery-vault-\(UUID().uuidString)")
    return VaultTokenStore(directory: root.path)
}

@Suite("The credential vault's admin routes take")
struct VaultAdminCredentialTests {
    @Test("the operator variable is the first door")
    func operatorVariableWins() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        try store.write("vop_file", vault: "https://vault.example")

        let credential = VaultAdminCredential.resolve(
            vault: "https://vault.example",
            environment: [
                VaultAdminCredential.operatorVariable: " vop_environment\n",
                VaultSession.variable: "cookie",
            ],
            store: store)

        #expect(credential?.source == .operatorVariable)
        #expect(credential?.headerName == "Authorization")
        #expect(credential?.headerValue == "Bearer vop_environment")
    }

    @Test("the token file answers when the environment carries no token")
    func fileIsSecond() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        try store.write("vop_file", vault: "https://vault.example")

        let credential = VaultAdminCredential.resolve(
            vault: "https://vault.example",
            environment: [VaultSession.variable: "cookie"],
            store: store)

        #expect(credential?.source == .tokenFile)
        #expect(credential?.headerValue == "Bearer vop_file")
    }

    @Test("the session is the last door, and it travels as a cookie")
    func sessionIsLast() {
        let store = temporaryStore()
        let credential = VaultAdminCredential.resolve(
            vault: "https://vault.example",
            environment: [VaultSession.variable: "cookie"],
            store: store)

        #expect(credential?.source == .sessionVariable)
        #expect(credential?.headerName == "Cookie")
        #expect(credential?.headerValue == "vault_session=cookie")
    }

    @Test("no credential at all answers nothing, and the refusal carries the recipe")
    func noneAtAll() {
        let store = temporaryStore()
        let credential = VaultAdminCredential.resolve(
            vault: "https://vault.example", environment: [:], store: store)

        #expect(credential == nil)
        #expect(RotationRefusal.noVaultSession.description.contains("hatchery vault login"))
    }

    @Test("a token file for one vault host is not read for another")
    func oneFilePerHost() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        try store.write("vop_estate", vault: "https://vault.example")

        #expect(store.read(vault: "https://vault.example") == "vop_estate")
        #expect(store.read(vault: "https://lab.example") == nil)
    }
}

@Suite("The token file this machine holds")
struct VaultTokenStoreTests {
    @Test("the file is mode 600 in a directory of mode 700")
    func modes() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        try store.write("vop_test", vault: "https://vault.example")

        let path = try #require(store.path(forVault: "https://vault.example"))
        let file = try FileManager.default.attributesOfItem(atPath: path)
        let directory = try FileManager.default.attributesOfItem(atPath: store.directory)

        #expect(file[.posixPermissions] as? NSNumber == 0o600)
        #expect(directory[.posixPermissions] as? NSNumber == 0o700)
        #expect(path.hasSuffix("vault.example.token"))
    }

    @Test("a second write replaces the token and keeps the mode")
    func rewrite() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        try store.write("vop_first", vault: "https://vault.example")
        try store.write("vop_second", vault: "https://vault.example")

        let path = try #require(store.path(forVault: "https://vault.example"))
        let file = try FileManager.default.attributesOfItem(atPath: path)

        #expect(store.read(vault: "https://vault.example") == "vop_second")
        #expect(file[.posixPermissions] as? NSNumber == 0o600)
    }

    @Test("deleting says whether a token was there")
    func delete() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        try store.write("vop_test", vault: "https://vault.example")

        #expect(try store.delete(vault: "https://vault.example"))
        #expect(try store.delete(vault: "https://vault.example") == false)
        #expect(store.read(vault: "https://vault.example") == nil)
    }

    @Test("an address with no host is refused rather than named after nothing")
    func noHost() {
        let store = temporaryStore()
        #expect(store.path(forVault: "not an address") == nil)
        #expect(throws: VaultTokenStoreError.noHost("not an address")) {
            try store.write("vop_test", vault: "not an address")
        }
    }
}

@Suite("The header that reaches a vault admin request")
struct VaultAdminHeaderTests {
    @Test("an operator token reaches the request as a bearer")
    func bearerReachesTheRequest() async throws {
        let recorder = HeaderRecorder()
        let vault = VaultAdmin(
            baseURL: "https://vault.example",
            credential: .bearer("vop_test"),
            exchange: { try recorder.exchange($0) })

        _ = try await vault.registerApp(slug: "rookery")

        #expect(recorder.headers["Authorization"] == "Bearer vop_test")
        #expect(recorder.headers["Cookie"] == nil)
    }

    @Test("a session still reaches the request as a cookie")
    func sessionReachesTheRequest() async throws {
        let recorder = HeaderRecorder()
        let vault = VaultAdmin(
            baseURL: "https://vault.example",
            session: "abc123",
            exchange: { try recorder.exchange($0) })

        _ = try await vault.registerApp(slug: "rookery")

        #expect(recorder.headers["Cookie"] == "vault_session=abc123")
        #expect(recorder.headers["Authorization"] == nil)
    }

    @Test("whoami reads the address and the token label vault answers")
    func whoami() async throws {
        let recorder = HeaderRecorder()
        let vault = VaultAdmin(
            baseURL: "https://vault.example",
            credential: .bearer("vop_test"),
            exchange: { try recorder.exchange($0) })

        let identity = try await vault.whoami()

        #expect(identity.email == "jimmy@example.com")
        #expect(identity.tokenName == "the mini")
    }
}

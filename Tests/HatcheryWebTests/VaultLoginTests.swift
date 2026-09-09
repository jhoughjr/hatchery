import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A store rooted in a fresh temporary directory, so no test reads or writes the real one.
private func temporaryStore() -> VaultTokenStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hatchery-login-\(UUID().uuidString)")
    return VaultTokenStore(directory: root.path)
}

/// Stands where the browser stands: it takes the sign-in URL and calls the loopback port back with a query.
///
/// The redirect vault sends is a plain GET, so the browser is one request and needs no window.
private func redirect(to url: URL, query: String) {
    guard let port = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "port" })?.value,
        let callback = URL(string: "http://127.0.0.1:\(port)\(VaultLoginListener.path)?\(query)")
    else { return }

    // Detached, because the sign-in is already waiting for this request when the URL is shown.
    Task.detached {
        _ = try? await URLSession.shared.data(from: callback)
    }
}

private let identity = VaultIdentity(email: "jimmy@example.com", tokenName: "the mini")

@Suite("Signing this machine in to vault")
struct VaultLoginTests {
    @Test("the sign-in URL carries the loopback port and the token label")
    func signInURL() throws {
        let url = try #require(
            VaultLogin.signInURL(vault: "https://vault.example", port: 51234, name: "the mini"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.path == "/auth/cli")
        #expect(components.queryItems?.contains(URLQueryItem(name: "port", value: "51234")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "name", value: "the mini")) == true)
    }

    @Test("an address with no host starts no sign-in")
    func badAddress() {
        #expect(VaultLogin.signInURL(vault: "not an address", port: 1, name: "x") == nil)
    }

    @Test("the token the redirect carried is stored at mode 600")
    func storesTheToken() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }

        let outcome = try await VaultLogin.run(
            vault: "https://vault.example",
            name: "the mini",
            store: store,
            waiting: 30,
            show: { redirect(to: $0, query: "token=vop_test") },
            confirm: { _ in identity })

        let attributes = try FileManager.default.attributesOfItem(atPath: outcome.path)

        #expect(store.read(vault: "https://vault.example") == "vop_test")
        #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
        #expect(outcome.identity == identity)
        #expect(outcome.path.hasSuffix("vault.example.token"))
    }

    @Test("the credential the check is made with is the token the redirect carried")
    func checksTheTokenItGot() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        let seen = Box()

        _ = try await VaultLogin.run(
            vault: "https://vault.example",
            name: "the mini",
            store: store,
            waiting: 30,
            show: { redirect(to: $0, query: "token=vop_test") },
            confirm: { credential in
                seen.set(credential.headerValue)
                return identity
            })

        #expect(seen.value == "Bearer vop_test")
    }

    @Test("a refused sign-in writes no file and says what vault answered")
    func refusedWritesNothing() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }

        await #expect(throws: VaultLoginError.refused("admin only")) {
            _ = try await VaultLogin.run(
                vault: "https://vault.example",
                name: "the mini",
                store: store,
                waiting: 30,
                show: { redirect(to: $0, query: "error=admin%20only") },
                confirm: { _ in identity })
        }

        #expect(store.read(vault: "https://vault.example") == nil)
        #expect(FileManager.default.fileExists(atPath: store.directory) == false)
    }

    @Test("a redirect with neither half writes no file")
    func emptyCallbackWritesNothing() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }

        await #expect(throws: VaultLoginError.emptyCallback) {
            _ = try await VaultLogin.run(
                vault: "https://vault.example",
                name: "the mini",
                store: store,
                waiting: 30,
                show: { redirect(to: $0, query: "state=nothing") },
                confirm: { _ in identity })
        }

        #expect(store.read(vault: "https://vault.example") == nil)
    }

    @Test("a vault that never answers ends the wait rather than hanging")
    func waitEnds() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }

        await #expect(throws: VaultLoginError.timedOut(seconds: 1)) {
            _ = try await VaultLogin.run(
                vault: "https://vault.example",
                name: "the mini",
                store: store,
                waiting: 1,
                show: { _ in },
                confirm: { _ in identity })
        }
    }
}

/// One value written from a closure and read after it, which is what a `@Sendable` closure needs to report out.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? { self.lock.withLock { self.stored } }

    func set(_ text: String) {
        self.lock.withLock { self.stored = text }
    }
}

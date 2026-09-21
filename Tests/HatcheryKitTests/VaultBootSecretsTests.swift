import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HatcheryKit

struct VaultBootSecretsTests {
    @Test("fetch throws unreadable on malformed JSON response")
    func unreadableOnMalformedJSON() async throws {
        let stubSession = URLSession(configuration: .default)
        stubSession.configuration.protocolClasses = [VaultBootSecretsStubProtocol.self]

        VaultBootSecretsStubProtocol.setupResponse(
            statusCode: 200,
            body: "invalid json".data(using: .utf8) ?? Data()
        )

        await #expect(throws: VaultBootSecrets.FetchError.unreadable) {
            _ = try await VaultBootSecrets.fetch(
                baseURL: "http://vault.test",
                app: "hatchery",
                appKey: "app-key",
                name: "HATCHERY_SERVE_TOKEN",
                session: stubSession,
                delays: [0.01]
            )
        }
    }
}

class VaultBootSecretsStubProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (statusCode: Int, body: Data)?

    static func setupResponse(statusCode: Int, body: Data) {
        self.response = (statusCode, body)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return request.url?.scheme == "http" && request.url?.host == "vault.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let client = self.client else { return }

        let url = self.request.url ?? URL(fileURLWithPath: "/")

        if let (statusCode, body) = Self.response {
            // A response that cannot be made fails the load. Linux has no bare initializer to fall back on.
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
    }
}

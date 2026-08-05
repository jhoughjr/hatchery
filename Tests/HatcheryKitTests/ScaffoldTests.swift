import Foundation
import Testing

@testable import HatcheryKit

/// Builds a PKCS#1 `RSAPrivateKey` from the nine integers it is defined as.
///
/// Built rather than embedded: a real key checked into the repo is key material checked into the
/// repo, even a throwaway one, and the thing under test is the DER walk rather than the crypto.
private func fakeRSAPEM(_ integers: [[UInt8]]) -> String {
    func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else if content.count < 0x100 {
            out += [0x81, UInt8(content.count)]
        } else {
            out += [0x82, UInt8(content.count >> 8), UInt8(content.count & 0xff)]
        }
        return out + content
    }
    let body = integers.flatMap { der(0x02, $0) }
    let sequence = der(0x30, body)
    let base64 = Data(sequence).base64EncodedString()
    return "-----BEGIN RSA PRIVATE KEY-----\n\(base64)\n-----END RSA PRIVATE KEY-----\n"
}

/// version, n, e, d, p, q, dp, dq, qi — the order the structure defines.
private let sampleIntegers: [[UInt8]] = [
    [0x00],              // version
    [0x00, 0xC5, 0x2B],  // n, with the sign-padding byte a JWK must not carry
    [0x01, 0x00, 0x01],  // e (65537)
    [0x0A, 0x0B],        // d
    [0x11],              // p
    [0x13],              // q
    [0x17],              // dp
    [0x19],              // dq
    [0x1D],              // qi
]

private func minter(pem: String) -> SecretMinter {
    SecretMinter(
        run: { _ in Data(pem.utf8) },
        randomBytes: { count in Data(repeating: 0xAB, count: count) }
    )
}

private func labStack(services: [ServiceSpec] = []) -> StackSpec {
    StackSpec(
        name: "mwlab",
        backend: .dokku,
        host: "dokku@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/mwserver-tf"),
        services: services
    )
}

private func gateway(_ name: String) -> ServiceSpec {
    ServiceSpec(
        name: name, kind: .paymentGateway, image: "payment-gateway:arm64-abc",
        domains: ["\(name).opi"], configFile: "\(name).config.json")
}

@Suite("RSA JWK conversion")
struct RSAJWKTests {
    @Test("the nine integers become the JWK fields the estate already uses")
    func convertsFields() throws {
        let jwk = try SecretMinter.rsaJWK(pem: fakeRSAPEM(sampleIntegers), kid: "test-kid")

        // The live key carries exactly this field set.
        #expect(Set(jwk.keys) == ["kty", "alg", "use", "kid", "n", "e", "d", "p", "q", "dp", "dq", "qi"])
        #expect(jwk["kty"] == "RSA")
        #expect(jwk["alg"] == "RS512")
        #expect(jwk["use"] == "sig")
        #expect(jwk["kid"] == "test-kid")
    }

    @Test("the DER sign-padding byte is dropped, because a JWK holds the magnitude")
    func dropsSignPadding() throws {
        let jwk = try SecretMinter.rsaJWK(pem: fakeRSAPEM(sampleIntegers), kid: "k")
        // n was 00 C5 2B; the leading zero is DER's sign byte and must not survive.
        #expect(jwk["n"] == SecretMinter.base64URL(Data([0xC5, 0x2B])))
        #expect(jwk["e"] == SecretMinter.base64URL(Data([0x01, 0x00, 0x01])))
    }

    @Test("base64url has no padding and no wire-unsafe characters")
    func base64URLIsURLSafe() {
        let encoded = SecretMinter.base64URL(Data([0xFB, 0xFF, 0xBE, 0x00]))
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    @Test("a truncated key is an error rather than a half-built JWK")
    func rejectsTruncatedKey() {
        let short = fakeRSAPEM(Array(sampleIntegers.prefix(4)))
        #expect(throws: (any Error).self) {
            _ = try SecretMinter.rsaJWK(pem: short, kid: "k")
        }
    }

    @Test("a PEM body that is not base64 is an error")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try SecretMinter.rsaJWK(
                pem: "-----BEGIN RSA PRIVATE KEY-----\n!!!!\n-----END RSA PRIVATE KEY-----", kid: "k")
        }
    }

    @Test("the minted JWKS is a keys array holding one signing key")
    func mintsJWKS() async throws {
        let json = try await minter(pem: fakeRSAPEM(sampleIntegers)).signingJWKS(kid: "fixed")
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let keys = parsed?["keys"] as? [[String: String]]
        #expect(keys?.count == 1)
        #expect(keys?.first?["kty"] == "RSA")
        #expect(keys?.first?["kid"] == "fixed")
    }
}

@Suite("Secret planning")
struct SecretPlannerTests {
    @Test("a signing key is shared from a sibling, so tokens still verify across the stack")
    func sharesKeypair() async throws {
        let planner = SecretPlanner(minter: minter(pem: fakeRSAPEM(sampleIntegers)))
        let stack = labStack(services: [gateway("paylab")])
        let resolutions = try await planner.resolve(
            for: gateway("paylab2"), in: stack,
            siblings: ["paylab": ["KEYPAIR_JWKS": "{\"keys\":[]}"]])

        let keypair = resolutions.first { $0.key == "KEYPAIR_JWKS" }
        #expect(keypair?.origin == .shared(from: "paylab"))
        #expect(keypair?.value == "{\"keys\":[]}")
    }

    @Test("with no sibling to share with, a signing key is minted")
    func mintsKeypairWhenAlone() async throws {
        let planner = SecretPlanner(minter: minter(pem: fakeRSAPEM(sampleIntegers)))
        let resolutions = try await planner.resolve(for: gateway("paylab2"), in: labStack())

        let keypair = resolutions.first { $0.key == "KEYPAIR_JWKS" }
        #expect(keypair?.origin == .minted("RSA-2048, RS512"))
        #expect(keypair?.value.contains("\"kty\":\"RSA\"") == true)
    }

    @Test("--mint-keypair overrides a sibling that could have been shared")
    func mintOverridesSharing() async throws {
        let planner = SecretPlanner(minter: minter(pem: fakeRSAPEM(sampleIntegers)))
        let resolutions = try await planner.resolve(
            for: gateway("paylab2"), in: labStack(),
            siblings: ["paylab": ["KEYPAIR_JWKS": "{\"keys\":[]}"]],
            mintKeypair: true)

        #expect(resolutions.first { $0.key == "KEYPAIR_JWKS" }?.origin == .minted("RSA-2048, RS512"))
    }

    @Test("a database password is never invented, because the role already exists")
    func neverInventsDatabasePassword() async throws {
        let planner = SecretPlanner(minter: minter(pem: fakeRSAPEM(sampleIntegers)))
        let resolutions = try await planner.resolve(for: gateway("paylab2"), in: labStack())

        let password = resolutions.first { $0.key == "DATABASE_PASSWORD" }
        #expect(password?.origin.needsValue == true)
        #expect(password?.value.isEmpty == true)
    }

    @Test("an app-scoped token is minted, because nothing else has a claim on it")
    func mintsAdminToken() async throws {
        let planner = SecretPlanner(minter: minter(pem: fakeRSAPEM(sampleIntegers)))
        let resolutions = try await planner.resolve(for: gateway("paylab2"), in: labStack())

        let token = resolutions.first { $0.key == "GATEWAY_ADMIN_TOKEN" }
        #expect(token?.origin == .minted("32 bytes"))
        #expect(token?.value.isEmpty == false)
    }

    @Test("APP_URL is composed from the declared domain")
    func composesAppURL() async throws {
        let planner = SecretPlanner(minter: minter(pem: fakeRSAPEM(sampleIntegers)))
        let resolutions = try await planner.resolve(for: gateway("paylab2"), in: labStack())

        let url = resolutions.first { $0.key == "APP_URL" }
        #expect(url?.origin == .composed)
        // A `.opi` name is a LAN address no tunnel fronts, so it stays plain HTTP.
        #expect(url?.value == "http://paylab2.opi")
    }

    @Test("shared infrastructure is composed only when every sibling agrees")
    func composesOnlyOnAgreement() {
        let agreeing = ["a": ["DATABASE_HOST": "pg"], "b": ["DATABASE_HOST": "pg"]]
        let disagreeing = ["a": ["DATABASE_HOST": "pg"], "b": ["DATABASE_HOST": "other"]]

        #expect(
            SecretPlanner.compose(
                key: "DATABASE_HOST", for: gateway("x"), in: labStack(), siblings: agreeing) == "pg")
        #expect(
            SecretPlanner.compose(
                key: "DATABASE_HOST", for: gateway("x"), in: labStack(), siblings: disagreeing) == nil)
    }

    @Test("every required key is accounted for, one way or another")
    func coversTheContract() async throws {
        let planner = SecretPlanner(minter: minter(pem: fakeRSAPEM(sampleIntegers)))
        let resolutions = try await planner.resolve(for: gateway("paylab2"), in: labStack())
        let contract = EnvContract.contract(for: .paymentGateway, backend: .dokku)

        #expect(Set(resolutions.map(\.key)) == contract?.required)
    }
}

@Suite("Dokku declaration")
struct DokkuProviderTests {
    private func request(gated: Bool = false, network: String? = nil) -> ScaffoldRequest {
        var service = gateway("paylab2")
        service.imageVariable = "paylab2_image"
        return ScaffoldRequest(
            stack: labStack(), service: service, containerPort: 8080,
            network: network, gated: gated)
    }

    @Test("the declaration carries the pieces the lab proved are load-bearing")
    func declarationShape() throws {
        let files = try DokkuProvider().declaration(
            for: request(network: "macworkstack-infra_default"))
        let tf = try #require(files.first { $0.role == .declaration })

        #expect(tf.path == "paylab2.tf")
        #expect(tf.contents.contains("resource \"dokku_app\" \"paylab2\""))
        #expect(tf.contents.contains("app_name = \"paylab2\""))
        #expect(tf.contents.contains("\"paylab2.opi\","))
        #expect(tf.contents.contains("container_port = \"8080\""))
        // The config must come from a file: the provider cannot take variables in that map.
        #expect(tf.contents.contains("jsondecode(file(\"${path.module}/paylab2.config.json\"))"))
        // Without the shared network the app cannot reach its database.
        #expect(tf.contents.contains("attach_post_create = \"macworkstack-infra_default\""))
        #expect(tf.contents.contains("docker_image = var.paylab2_image"))
    }

    @Test("no network declared means no networks block, rather than an empty one")
    func omitsNetworkWhenAbsent() throws {
        let files = try DokkuProvider().declaration(for: request())
        let tf = try #require(files.first { $0.role == .declaration })
        #expect(!tf.contents.contains("networks"))
    }

    @Test("gating adds the count and its enable variable")
    func gated() throws {
        let files = try DokkuProvider().declaration(for: request(gated: true))
        let tf = try #require(files.first { $0.role == .declaration })
        #expect(tf.contents.contains("count = var.enable_paylab2 ? 1 : 0"))

        let variable = try #require(files.first { $0.role == .variableAppend })
        #expect(variable.contents.contains("variable \"enable_paylab2\""))
    }

    @Test("a service with no domain is refused rather than declared unreachable")
    func requiresDomain() {
        var service = gateway("paylab2")
        service.domains = []
        let bad = ScaffoldRequest(stack: labStack(), service: service)
        #expect(throws: ProviderError.missingDetail("at least one domain")) {
            _ = try DokkuProvider().declaration(for: bad)
        }
    }

    @Test("a name that is not a legal identifier is folded rather than emitted raw")
    func foldsIdentifier() {
        #expect(DokkuProvider.identifier("pay-lab-2") == "pay_lab_2")
        #expect(DokkuProvider.identifier("2fast") == "app_2fast")
    }

    @Test("App Platform is refused outright rather than half-authored")
    func appPlatformUnsupported() {
        #expect(throws: ProviderError.noProvider(.appPlatform)) {
            _ = try Providers.provider(for: .appPlatform)
        }
    }
}

@Suite("Scaffolding")
struct ScaffolderTests {
    private final class Files: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: String]
        init(_ store: [String: String] = [:]) { self.store = store }
        var paths: [String] { lock.withLock { store.keys.sorted() } }
        func read(_ path: String) throws -> String {
            guard let value = lock.withLock({ store[path] }) else { throw CocoaError(.fileNoSuchFile) }
            return value
        }
        func write(_ path: String, _ contents: String) { lock.withLock { store[path] = contents } }
        func exists(_ path: String) -> Bool { lock.withLock { store[path] != nil } }
    }

    private func scaffolder(_ files: Files) -> Scaffolder {
        Scaffolder(
            planner: SecretPlanner(minter: minter(pem: fakeRSAPEM(sampleIntegers))),
            readFile: { try files.read($0) },
            writeFile: { files.write($0, $1) },
            fileExists: { files.exists($0) }
        )
    }

    private var manifest: StackManifest {
        StackManifest(stacks: [labStack(services: [gateway("paylab")])])
    }

    @Test("planning produces the declaration, the variable, the config, and the manifest entry")
    func plans() async throws {
        let result = try await scaffolder(Files()).plan(
            service: gateway("paylab2"), into: "mwlab", manifest: manifest,
            network: "macworkstack-infra_default")

        #expect(result.files.contains { $0.path == "paylab2.tf" && $0.role == .declaration })
        #expect(result.files.contains { $0.path == "variables.tf" && $0.role == .variableAppend })
        #expect(result.files.contains { $0.path == "paylab2.config.json" && $0.role == .config })
        #expect(result.manifest.stack(named: "mwlab")?.service(named: "paylab2") != nil)
        // The manifest records which variable moves the image, so `deploy` can find it.
        #expect(result.service.imageVariable == "paylab2_image")
    }

    @Test("a duplicate service is refused")
    func refusesDuplicate() async throws {
        await #expect(throws: ScaffoldError.serviceExists(stack: "mwlab", service: "paylab")) {
            _ = try await scaffolder(Files()).plan(
                service: gateway("paylab"), into: "mwlab", manifest: manifest)
        }
    }

    @Test("a stack with no tofu binding is refused")
    func refusesWithoutBinding() async throws {
        var stack = labStack()
        stack.tofu = nil
        let bare = StackManifest(stacks: [stack])

        await #expect(throws: ScaffoldError.noTofuBinding(stack: "mwlab")) {
            _ = try await scaffolder(Files()).plan(
                service: gateway("paylab2"), into: "mwlab", manifest: bare)
        }
    }

    @Test("writing appends to the variables file rather than replacing it")
    func appendsVariables() async throws {
        let files = Files(["/infra/mwserver-tf/variables.tf": "variable \"existing\" {\n}\n"])
        let scaffolder = self.scaffolder(files)
        let result = try await scaffolder.plan(
            service: gateway("paylab2"), into: "mwlab", manifest: manifest)
        try scaffolder.write(result, in: labStack())

        let variables = try files.read("/infra/mwserver-tf/variables.tf")
        #expect(variables.contains("variable \"existing\""))
        #expect(variables.contains("variable \"paylab2_image\""))
    }

    @Test("an existing declaration is never clobbered")
    func refusesToOverwrite() async throws {
        let files = Files(["/infra/mwserver-tf/paylab2.tf": "# already here\n"])
        let scaffolder = self.scaffolder(files)
        let result = try await scaffolder.plan(
            service: gateway("paylab2"), into: "mwlab", manifest: manifest)

        #expect(throws: ScaffoldError.fileExists("/infra/mwserver-tf/paylab2.tf")) {
            try scaffolder.write(result, in: labStack())
        }
        // The collision is caught before anything is written, so no half-written service is left.
        let untouched = try files.read("/infra/mwserver-tf/paylab2.tf")
        #expect(untouched == "# already here\n")
        #expect(!files.exists("/infra/mwserver-tf/paylab2.config.json"))
    }

    @Test("a key with no value is omitted from the config, never written as an empty string")
    func omitsEmptyValues() async throws {
        let result = try await scaffolder(Files()).plan(
            service: gateway("paylab2"), into: "mwlab", manifest: manifest)
        let config = try #require(result.files.first { $0.role == .config })
        let parsed = try JSONSerialization.jsonObject(with: Data(config.contents.utf8))
            as? [String: String]

        // The dokku provider rejects a zero-length config value, so an empty placeholder makes
        // a freshly created service fail to plan.
        #expect(parsed?["DATABASE_PASSWORD"] == nil)
        #expect(parsed?.values.contains("") == false)
        // What hatchery could supply is still there.
        #expect(parsed?["KEYPAIR_JWKS"] != nil)
        #expect(parsed?["APP_URL"] == "http://paylab2.opi")
    }

    @Test("the keys needing values are reported rather than left as convincing blanks")
    func reportsUnresolved() async throws {
        let result = try await scaffolder(Files()).plan(
            service: gateway("paylab2"), into: "mwlab", manifest: manifest)

        let names = Set(result.unresolved.map(\.key))
        #expect(names.contains("DATABASE_PASSWORD"))
        #expect(!names.contains("KEYPAIR_JWKS"))
        #expect(!names.contains("GATEWAY_ADMIN_TOKEN"))
    }
}

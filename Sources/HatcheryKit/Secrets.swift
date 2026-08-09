import Foundation

public enum SecretError: Error, CustomStringConvertible, Equatable {
    case generationFailed(key: String, reason: String)
    case malformedKeyMaterial(reason: String)

    public var description: String {
        switch self {
        case .generationFailed(let key, let reason):
            return "could not generate \(key): \(reason)"
        case .malformedKeyMaterial(let reason):
            return "generated key material could not be read: \(reason)"
        }
    }
}

/// Where the value for a declared key comes from when hatchery authors a new service.
///
/// The distinction is the whole point. A value hatchery invents is safe to invent only when
/// nothing else already holds a claim on it. A database password does not qualify: the role
/// exists already, so inventing a new password produces a service that cannot connect.
public enum SecretOrigin: Sendable, Equatable {
    /// hatchery generated it. Nothing else has a claim on the value.
    case minted(String)
    /// Copied from a sibling in the same stack, because the value has to match across services.
    case shared(from: String)
    /// Composed from what the manifest already declares.
    case composed
    /// Only a person or a third party has it.
    case supplied(reason: String)

    /// Whether a person has to do something before the service will boot.
    public var needsValue: Bool {
        if case .supplied = self { return true }
        return false
    }

    /// The word shown next to the key.
    public var label: String {
        switch self {
        case .minted(let how): return "minted (\(how))"
        case .shared(let from): return "shared from \(from)"
        case .composed: return "composed"
        case .supplied: return "NEEDS VALUE"
        }
    }
}

/// One declared key, where its value came from, and the value itself.
public struct SecretResolution: Sendable, Equatable {
    public let key: String
    public let origin: SecretOrigin
    /// Empty when the origin is ``SecretOrigin/supplied(reason:)``.
    public let value: String

    public init(key: String, origin: SecretOrigin, value: String) {
        self.key = key
        self.origin = origin
        self.value = value
    }
}

/// Generates the key material hatchery is entitled to invent.
public struct SecretMinter: Sendable {
    private let run: CommandRunner
    private let randomBytes: @Sendable (Int) -> Data

    public init(
        run: @escaping CommandRunner = ShellRunner.live,
        randomBytes: @escaping @Sendable (Int) -> Data = SecretMinter.systemRandom
    ) {
        self.run = run
        self.randomBytes = randomBytes
    }

    public static let systemRandom: @Sendable (Int) -> Data = { count in
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(count: count)
        for index in 0..<count {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return bytes
    }

    /// A URL-safe random token.
    public func token(bytes: Int = 32) -> String {
        Self.base64URL(randomBytes(bytes))
    }

    /// A JWKS holding one RSA signing key, in the shape the estate already uses.
    ///
    /// RSA rather than an elliptic curve, and `RS512` rather than a default, because that is
    /// what the live keys are: the services verify each other's tokens, so a key of a different
    /// type is a key nothing accepts. CryptoKit has no RSA, so this shells out to `openssl` and
    /// reads the DER structure directly.
    public func signingJWKS(kid: String? = nil) async throws -> String {
        try await signingKeypair(kid: kid).jwks
    }

    /// The JWKS and the private key it was derived from, together.
    ///
    /// Together, because they are one secret: minting a JWKS and discarding its PEM produces a
    /// service that publishes keys it cannot sign with — and no person can supply the matching
    /// half of a key that was thrown away. Anything that mints one needs both.
    public func signingKeypair(kid: String? = nil) async throws -> (pem: String, jwks: String) {
        let pem: String
        do {
            // `genpkey`, not `genrsa`: genrsa's output depends on which openssl answered —
            // LibreSSL writes PKCS#1, whose "BEGIN RSA PRIVATE KEY" MWServer's PEM parser
            // rejects outright (the first live clone crashlooped on invalidPEMDocument).
            // genpkey writes PKCS#8 on both, which is the shape the estate's live keys use.
            let data = try await run([
                "openssl", "genpkey", "-algorithm", "RSA",
                "-pkeyopt", "rsa_keygen_bits:2048",
            ])
            pem = String(decoding: data, as: UTF8.self)
        } catch {
            throw SecretError.generationFailed(key: "KEYPAIR_JWKS", reason: "\(error)")
        }
        // Refused here, where the openssl that answered is known, rather than at boot on the
        // box — a service that traps on its own config is the failure this whole path exists
        // to prevent.
        guard pem.hasPrefix("-----BEGIN PRIVATE KEY-----") else {
            throw SecretError.generationFailed(
                key: "PRIVATE_KEY_PEM",
                reason: "openssl wrote \(pem.split(separator: "\n").first ?? "an empty document")"
                    + " instead of a PKCS#8 PRIVATE KEY; the deployed parser accepts only PKCS#8")
        }

        let identifier = kid ?? Self.base64URL(randomBytes(8))
        let jwk = try Self.rsaJWK(pem: pem, kid: identifier)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let document = ["keys": [jwk]]
        guard let json = String(data: try encoder.encode(document), encoding: .utf8) else {
            throw SecretError.malformedKeyMaterial(reason: "the JWKS did not encode as UTF-8")
        }
        return (pem, json)
    }

    /// Converts a PKCS#1 RSA private key into a private JWK.
    ///
    /// `RSAPrivateKey` is a DER `SEQUENCE` of nine `INTEGER`s — version, n, e, d, p, q, dp, dq,
    /// The elements of a DER SEQUENCE, with their tags.
    static func derElements(of der: Data) throws -> [(tag: UInt8, bytes: Data)] {
        var out: [(tag: UInt8, bytes: Data)] = []
        var index = der.startIndex
        guard let outer = try Self.readTag(der, &index), outer.tag == 0x30 else {
            throw SecretError.malformedKeyMaterial(reason: "expected a DER SEQUENCE")
        }
        let end = min(index.advanced(by: outer.length), der.endIndex)
        while index < end {
            guard let element = try Self.readTag(der, &index) else { break }
            let stop = min(index.advanced(by: element.length), der.endIndex)
            out.append((element.tag, der[index..<stop]))
            index = stop
        }
        return out
    }

    /// The nine PKCS#1 integers, whichever container `openssl` wrapped them in.
    ///
    /// macOS ships LibreSSL, whose `genrsa` writes PKCS#1 — the nine integers directly. Ubuntu
    /// ships OpenSSL 3, whose `genrsa` writes PKCS#8: the same structure sealed inside an OCTET
    /// STRING behind a version and an algorithm identifier. Reading only the first shape meant
    /// minting a signing key failed outright on Linux, with "found 3" as the only clue.
    ///
    /// Detected by structure rather than by platform, because the format is a property of the
    /// openssl that answered, not of the OS it answered on.
    static func privateKeyIntegers(der: Data) throws -> [Data] {
        let top = try Self.derElements(of: der)

        // PKCS#8: version, AlgorithmIdentifier, OCTET STRING carrying the PKCS#1 key. Copied
        // into fresh Data so the nested parse starts from a zero-based index.
        if top.count == 3, top[2].tag == 0x04 {
            return try Self.derElements(of: Data(top[2].bytes)).map(\.bytes)
        }
        return top.map(\.bytes)
    }

    /// qi — which is exactly the field set a private RSA JWK carries, so the conversion is a
    /// walk over the sequence rather than a crypto operation.
    static func rsaJWK(pem: String, kid: String) throws -> [String: String] {
        let body = pem.split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else {
            throw SecretError.malformedKeyMaterial(reason: "the PEM body was not base64")
        }

        let integers = try Self.privateKeyIntegers(der: der)

        // version, n, e, d, p, q, dp, dq, qi
        guard integers.count >= 9 else {
            throw SecretError.malformedKeyMaterial(
                reason: "expected 9 integers in the key, found \(integers.count)")
        }

        let names = ["n", "e", "d", "p", "q", "dp", "dq", "qi"]
        var jwk: [String: String] = ["kty": "RSA", "alg": "RS512", "use": "sig", "kid": kid]
        for (offset, name) in names.enumerated() {
            // DER INTEGERs carry a leading zero byte when the high bit would read as a sign.
            // A JWK holds the unsigned magnitude, so that padding is dropped.
            jwk[name] = Self.base64URL(Data(integers[offset + 1].drop(while: { $0 == 0x00 })))
        }
        return jwk
    }

    /// Reads one DER tag-length header, leaving `index` at the first content byte.
    static func readTag(_ data: Data, _ index: inout Data.Index) throws -> (tag: UInt8, length: Int)? {
        guard index < data.endIndex else { return nil }
        let tag = data[index]
        index = data.index(after: index)
        guard index < data.endIndex else {
            throw SecretError.malformedKeyMaterial(reason: "the key ended inside a tag header")
        }

        var length = Int(data[index])
        index = data.index(after: index)
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count > 0, count <= 8 else {
                throw SecretError.malformedKeyMaterial(reason: "unsupported DER length form")
            }
            length = 0
            for _ in 0..<count {
                guard index < data.endIndex else {
                    throw SecretError.malformedKeyMaterial(reason: "the key ended inside a length")
                }
                length = length << 8 | Int(data[index])
                index = data.index(after: index)
            }
        }
        return (tag, length)
    }

    /// base64url without padding, which is what a JWK field is.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Decides where each declared key's value should come from, and produces it.
///
/// Three rules, each of which came from the lab rather than from a preference:
///
/// - `KEYPAIR_JWKS` is *shared* when the stack already has a service carrying one, because the
///   services verify each other's tokens and a fresh key is a key nothing accepts. It is minted
///   only when there is no sibling to share with, which is what a genuinely new stack looks like.
/// - Database credentials are never invented. The role exists before the service does — the
///   lab's were provisioned by the `db/init` matrix — so a minted password produces a service
///   that cannot connect.
/// - Third-party credentials are never invented, and saying so is more useful than a placeholder
///   that looks filled in.
public struct SecretPlanner: Sendable {
    private let minter: SecretMinter

    public init(minter: SecretMinter = SecretMinter()) {
        self.minter = minter
    }

    /// Keys hatchery mints outright: they exist only for this service, so nothing else has a claim.
    static let mintedTokens: Set<String> = [
        "GATEWAY_ADMIN_TOKEN", "PAYMENT_GATEWAY_TOKEN", "GSX_GATEWAY_TOKEN",
    ]

    /// Keys whose value must already exist somewhere else, with the reason it cannot be invented.
    static let mustBeSupplied: [String: String] = [
        "DATABASE_PASSWORD": "the database role already exists; a new password would not connect",
        "DATABASE_APP_PASSWORD": "the app role already exists; a new password would not connect",
        "DATABASE_URL": "points at an existing database and role",
        "DATABASE_OWNER_URL": "points at an existing database and role",
        "DATABASE_APP_URL": "points at an existing database and role",
        "STRIPE_API_KEY": "only Stripe issues this",
        "STRIPE_WEBHOOK_SECRET": "only Stripe issues this",
        "PRIVATE_KEY_PEM": "supply the existing key rather than minting a second one",
    ]

    /// Resolves every required key for a new service.
    ///
    /// `siblings` is the config of services already in the stack, keyed by service name, and is
    /// what makes sharing possible. Passing none means every shareable key is minted instead.
    public func resolve(
        for service: ServiceSpec,
        in stack: StackSpec,
        siblings: [String: [String: String]] = [:],
        mintKeypair: Bool = false
    ) async throws -> [SecretResolution] {
        guard let contract = EnvContract.contract(for: service.kind, backend: stack.backend) else {
            return []
        }

        // The keypair resolves as a pair. Walking the keys independently is what produced a
        // freshly minted JWKS beside "supply the existing key" for its own private half — a
        // key that was generated and thrown away, which no person could ever supply.
        var mintedPEM: String?
        var resolutions: [SecretResolution] = []
        for key in contract.required.sorted() {
            resolutions.append(
                try await resolve(
                    key: key, for: service, in: stack, siblings: siblings,
                    mintKeypair: mintKeypair, mintedPEM: &mintedPEM))
        }
        return resolutions
    }

    private func resolve(
        key: String,
        for service: ServiceSpec,
        in stack: StackSpec,
        siblings: [String: [String: String]],
        mintKeypair: Bool,
        mintedPEM: inout String?
    ) async throws -> SecretResolution {
        if key == "KEYPAIR_JWKS" {
            if !mintKeypair, let (name, value) = Self.sibling(key, in: siblings) {
                return SecretResolution(key: key, origin: .shared(from: name), value: value)
            }
            let pair = try await minter.signingKeypair()
            mintedPEM = pair.pem
            return SecretResolution(key: key, origin: .minted("RSA-2048, RS512"), value: pair.jwks)
        }

        if key == "PRIVATE_KEY_PEM" {
            // The stack's key, wherever the stack keeps it: on a sibling when one carries it,
            // or the private half of the keypair this very resolution minted. Only a stack
            // whose key lives entirely outside hatchery still needs a person.
            if let (name, value) = Self.sibling(key, in: siblings) {
                return SecretResolution(key: key, origin: .shared(from: name), value: value)
            }
            if let pem = mintedPEM {
                return SecretResolution(
                    key: key, origin: .minted("the private half of the minted keypair"),
                    value: pem)
            }
        }

        if Self.mintedTokens.contains(key) {
            return SecretResolution(key: key, origin: .minted("32 bytes"), value: minter.token())
        }

        if let reason = Self.mustBeSupplied[key] {
            return SecretResolution(key: key, origin: .supplied(reason: reason), value: "")
        }

        if let composed = Self.compose(key: key, for: service, in: stack, siblings: siblings) {
            return SecretResolution(key: key, origin: .composed, value: composed)
        }

        return SecretResolution(
            key: key, origin: .supplied(reason: "hatchery has no way to derive this"), value: "")
    }

    /// A value another service in the stack already carries.
    static func sibling(_ key: String, in siblings: [String: [String: String]]) -> (String, String)? {
        for name in siblings.keys.sorted() {
            if let value = siblings[name]?[key], !value.isEmpty {
                return (name, value)
            }
        }
        return nil
    }

    /// Values derivable from what the manifest already says, or from what siblings agree on.
    static func compose(
        key: String,
        for service: ServiceSpec,
        in stack: StackSpec,
        siblings: [String: [String: String]]
    ) -> String? {
        switch key {
        case "APP_URL":
            guard let domain = service.domains.first, !domain.isEmpty else { return nil }
            return "\(ServiceSpec.scheme(forHost: domain))://\(domain)"

        case "APP_DOMAIN":
            return service.domains.first

        case "DATABASE_DB":
            // The lab names a database after the service it belongs to.
            return service.name

        case "DATABASE_HOST", "DATABASE_PORT", "DATABASE_USER", "TEMPORAL_ADDRESS",
            "TEMPORAL_NAMESPACE", "DATABASE_LOG_LEVEL", "LOG_LEVEL":
            // Infrastructure the whole stack shares. If every sibling agrees, the answer is not
            // a guess; if they disagree, hatchery has no basis to pick one.
            let values = Set(siblings.values.compactMap { $0[key] }.filter { !$0.isEmpty })
            return values.count == 1 ? values.first : nil

        default:
            return nil
        }
    }
}

import Foundation
import Testing

@testable import HatcheryKit

/// Key material in both the shapes `openssl genrsa` produces.
///
/// These are throwaway 1024-bit keys generated for this test and used nowhere.
private enum KeyFixtures {
    static let pkcs1 = """
        -----BEGIN RSA PRIVATE KEY-----
        MIICXQIBAAKBgQDmwqoBiwJaK+HpZdSGyFyMCHnGz6PfFiipSoShqAMGTICvWihN
        vCtkuNX1mfu+/DeQiDO7jzc2oyg/b06/1YEQadAM+FurYhfhEofbVcDTDFaWgN4S
        PsGrRBl3Gl09/GHSVR7HtcwDNU67H+ACGhaqI7I1OLWZOcKXbLdryGIYqwIDAQAB
        AoGALBgoejEA2xAlk/7EVJj2rj90XZwRuTA3xtmZbHZ5VXvK3zcAGpKJTC7Rm6O3
        6i+xwml0UTO1njghGbYAO0Hl7ksVXJOiww+aKpE9wXj6iQ3EmkF3MgslRHEEi9JX
        lXuvPNZk7uVwc3lD+wbtRR8cAWAOP2SMY4YhjXqWiHJa1RECQQD1fsZkTG32+PcU
        tr9OxTXbmMJSlhZMzadLemy8nWF4/oxEkSnrqLlVhbVCC+sm+eDhBso6abVH2wor
        KoD61ORjAkEA8KJ61EMbw0i8VdXL8H7/H6ihLPax4BnCtpe0eDbMex1Erp5P1c2o
        PfQ7bW4fPdOnYtqHSi7cWaXmGIW4hFd5GQJBAIqRhGoYufktjkmi3VkY98177DOx
        g+TWMBfqgnX0X5BsHcCWL5NVKUecsTMWhyT45nYd3wgZorlsadDzrNnoUQECQAGH
        BoCSbHqw24Ev+jtskvIAgAVpC3gAsdu22s5oiqO9a9Iv7xHMXGUIR9hJ+qjJzyYx
        fOpbocpv4yYEs0cjxwECQQCY7Fizh5cch5ev46yAd7pj5/T74L/74Vy+Lm0Hq94a
        rQQLbzt6MK6BwjxQWz3kXUv6onphdsshY7uGl1onvwb7
        -----END RSA PRIVATE KEY-----
        """

    static let pkcs8 = """
        -----BEGIN PRIVATE KEY-----
        MIICeAIBADANBgkqhkiG9w0BAQEFAASCAmIwggJeAgEAAoGBAN2VsLXOkxFKmzZ+
        0WPmAzWTxj19j72Y7AuWvntiQTM0J9fZ90+oP+FZxnOL3yL8GHUPijW0MjwTQhTd
        MkA5gQgs0cq9LmzXRFa8XDD0dlIbkyx+jqlYElJJ6v0XXyyOPgOHT/P7xUNZKJ/1
        N51Wr9HbJ6sOkoF+1t1e89lHBnMTAgMBAAECgYA9POFZXX3HiZbbuLClqyu34t8m
        n0zaWSjjCwYZk03xmLhqLxLqMNV2shjmVgGU6ZbYwzKvJN29PJVGrtr0ZPADjrAl
        Cz7JKjzjt+AbRBZ/B9ZVEYYOTVN+snIVDKVpNHVhp7lP1T6tZIBOfhO9/tPdJvev
        mL4KoB7Ux33g8o4gAQJBAPQLnxYoXv/9os+CaeedZpq4bXgSIQlpdVo39NuO8xIo
        /eLjzQIwiHst7mR/rQh+dvZu/hSyknZUafD2LhcRRNMCQQDocGhTS2tWvQHhCXNQ
        5KK1BNqBILf6DgHw0a6yZLiqsEyxnDcNRuXKVj3M16es7DXgzvi60A5EiAkM74c5
        PjDBAkEA8tAVSwCD9QOw1/IT2QT8r3hMQqkXAbxRrJ/8Ge/S3QC4CuVIdqM/R//d
        L1TxHoBlcK/iUUmS+/TlK4BlP0JJTQJBAKdTVCayIkE8qr+fF/5huKdrKQjPzuEZ
        eFgt+f699xoY8/zfodnS8dTopHBzxmb7XAXLuM5yu/Kloy5GuCeDF4ECQQC98DLw
        ECFo26JnYZ/yKlTHbfTFm3KEoqRvftAqQWQ9ynhwGlcIYU9PZPDC9Be207jmvnVC
        nZloIaeSrp4Xsjff
        -----END PRIVATE KEY-----
        """
}

@Suite("Reading generated RSA key material")
struct KeyFormatTests {
    /// LibreSSL, which macOS ships. The nine integers sit directly in the outer SEQUENCE.
    @Test("reads a PKCS#1 key")
    func readsPKCS1() throws {
        let jwk = try SecretMinter.rsaJWK(pem: KeyFixtures.pkcs1, kid: "test")
        #expect(jwk["kty"] == "RSA")
        #expect(jwk["alg"] == "RS512")
        for field in ["n", "e", "d", "p", "q", "dp", "dq", "qi"] {
            #expect(jwk[field]?.isEmpty == false, "\(field) must be present")
        }
    }

    /// OpenSSL 3, which Ubuntu ships. The same nine integers, wrapped in an OCTET STRING behind
    /// a version and an algorithm identifier. Reading only the first shape meant minting a
    /// signing key failed outright on Linux — eight tests, one cause, invisible on macOS.
    @Test("reads a PKCS#8 key")
    func readsPKCS8() throws {
        let jwk = try SecretMinter.rsaJWK(pem: KeyFixtures.pkcs8, kid: "test")
        #expect(jwk["kty"] == "RSA")
        for field in ["n", "e", "d", "p", "q", "dp", "dq", "qi"] {
            #expect(jwk[field]?.isEmpty == false, "\(field) must be present")
        }
    }

    /// The formats must agree on what they mean. A PKCS#8 key whose fields parsed into the wrong
    /// slots would still populate every name above and be silently wrong.
    @Test("the public exponent is the usual 65537 in both formats")
    func exponentMatches() throws {
        // AQAB is base64url for 0x010001.
        #expect(try SecretMinter.rsaJWK(pem: KeyFixtures.pkcs1, kid: "k")["e"] == "AQAB")
        #expect(try SecretMinter.rsaJWK(pem: KeyFixtures.pkcs8, kid: "k")["e"] == "AQAB")
    }

    @Test("rejects material that is not a key at all")
    func rejectsGarbage() {
        #expect(throws: SecretError.self) {
            _ = try SecretMinter.rsaJWK(pem: "-----BEGIN PRIVATE KEY-----\nZ29vZA==\n-----END PRIVATE KEY-----", kid: "k")
        }
    }
}

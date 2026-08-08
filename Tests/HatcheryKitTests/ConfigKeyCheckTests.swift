import Foundation
import Testing

@testable import HatcheryKit

@Suite("A contract can refuse a key by name")
struct ConfigKeyCheckTests {
    private let contract = EnvContract(
        required: ["DATABASE_URL", "GATEWAY_TOKEN"],
        optional: ["LOG_LEVEL"],
        secret: ["PRIVATE_KEY_PEM"],
        retired: ["OLD_FLAG"],
        ignored: ["PORT"],
        ignoredPrefixes: ["DOKKU_"])

    @Test func everyHeadingCountsAsRecognised() {
        #expect(contract.recognizes("DATABASE_URL"))
        #expect(contract.recognizes("LOG_LEVEL"))
        #expect(contract.recognizes("PRIVATE_KEY_PEM"))
        #expect(contract.recognizes("OLD_FLAG"))
        #expect(contract.recognizes("PORT"))
        #expect(contract.recognizes("DOKKU_PROXY_PORT"))
        #expect(!contract.recognizes("DATABSE_URL"))
    }

    @Test func removalsAreNeverUnknown() {
        // Deleting a typo must not require spelling it correctly a second time.
        let unknown = contract.unknownKeys(in: ["DATABSE_URL": "", "LOG_LEVEL": "debug"])
        #expect(unknown.isEmpty)
    }

    @Test func settingAnUnknownKeyIsFlagged() {
        let unknown = contract.unknownKeys(
            in: ["DATABSE_URL": "postgres://x", "LOG_LEVEL": "debug", "MYSTERY": "1"])
        #expect(unknown == ["DATABSE_URL", "MYSTERY"])
    }

    @Test func aNearMissFindsItsNeighbour() {
        #expect(contract.nearest(to: "DATABSE_URL").first == "DATABASE_URL")
        #expect(contract.nearest(to: "log_level").first == "LOG_LEVEL")
    }

    @Test func garbageFindsNothing() {
        #expect(contract.nearest(to: "ZZZZZZZZ").isEmpty)
    }
}

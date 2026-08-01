import XCTest
@testable import HatcheryKit

final class ConfigSyncTests: XCTestCase {
    func testIdenticalConfigsAreInSync() {
        let difference = ConfigSync.diff(
            live: ["APP_ID": "mwlab", "LOG_LEVEL": "info"],
            declared: ["APP_ID": "mwlab", "LOG_LEVEL": "info"]
        )

        XCTAssertTrue(difference.isEmpty)
        XCTAssertEqual(difference.summary, "in sync")
    }

    /// The lab's real case: three keys were set by hand and never reached the file.
    func testKeysSetOnTheServiceReadAsAdded() {
        let difference = ConfigSync.diff(
            live: ["APP_ID": "mwlab", "TEMPORAL_ADDRESS": "h:7233", "TEMPORAL_NAMESPACE": "n"],
            declared: ["APP_ID": "mwlab"]
        )

        XCTAssertEqual(difference.added, ["TEMPORAL_ADDRESS", "TEMPORAL_NAMESPACE"])
        XCTAssertTrue(difference.changed.isEmpty)
        XCTAssertTrue(difference.removed.isEmpty)
    }

    func testAChangedValueReadsAsChanged() {
        let difference = ConfigSync.diff(
            live: ["LOG_LEVEL": "debug"],
            declared: ["LOG_LEVEL": "info"]
        )

        XCTAssertEqual(difference.changed, ["LOG_LEVEL"])
        XCTAssertEqual(difference.summary, "0 added, 1 changed, 0 removed")
    }

    /// `GIT_REV` moves on every deploy, so reporting it would make every sync look like a change.
    func testPlatformKeysAreNeverADifference() {
        XCTAssertTrue(
            ConfigSync.diff(live: ["GIT_REV": "bbbb"], declared: ["GIT_REV": "aaaa"]).isEmpty)
        XCTAssertTrue(
            ConfigSync.diff(live: ["GIT_REV": "bbbb"], declared: [:]).isEmpty)
        XCTAssertTrue(
            ConfigSync.diff(live: ["DOKKU_APP_TYPE": "dockerfile"], declared: [:]).isEmpty)
    }

    func testTheDeclarationKeepsPlatformKeys() throws {
        let data = try ConfigSync.encode(["APP_ID": "mwlab", "GIT_REV": "abc", "DOKKU_APP_TYPE": "x"])
        let text = String(decoding: data, as: UTF8.self)

        // The file must match what tofu tracks, so nothing is filtered out of it.
        XCTAssertTrue(text.contains("APP_ID"))
        XCTAssertTrue(text.contains("GIT_REV"), text)
    }

    // MARK: - Which platform keys a declaration carries

    /// A declaration that already claims `GIT_REV` keeps it, refreshed. Dropping it would make a
    /// plan want to unset the key on the running app.
    func testAClaimedPlatformKeyIsRefreshed() {
        let merged = ConfigSync.merged(
            live: ["APP_ID": "mwlab", "GIT_REV": "new"],
            declared: ["APP_ID": "mwlab", "GIT_REV": "old"]
        )

        XCTAssertEqual(merged["GIT_REV"], "new")
        XCTAssertTrue(ConfigSync.needsWrite(
            live: ["APP_ID": "mwlab", "GIT_REV": "new"],
            declared: ["APP_ID": "mwlab", "GIT_REV": "old"]))
    }

    /// A declaration that never claimed it does not gain it. Adding one makes a plan want to set
    /// it on the app, which is how paylab and comlab briefly grew a key they never had.
    func testAnUnclaimedPlatformKeyIsNotAdded() {
        let merged = ConfigSync.merged(
            live: ["APP_ID": "paylab", "GIT_REV": "new"],
            declared: ["APP_ID": "paylab"]
        )

        XCTAssertNil(merged["GIT_REV"])
        XCTAssertFalse(ConfigSync.needsWrite(
            live: ["APP_ID": "paylab", "GIT_REV": "new"],
            declared: ["APP_ID": "paylab"]))
    }

    func testARealKeyChangeStillNeedsAWrite() {
        XCTAssertTrue(ConfigSync.needsWrite(
            live: ["APP_ID": "mwlab", "LOG_LEVEL": "debug"],
            declared: ["APP_ID": "mwlab", "LOG_LEVEL": "info"]))
    }

    func testAKeyOnlyInTheFileReadsAsRemoved() {
        let difference = ConfigSync.diff(live: [:], declared: ["STALE_KEY": "x"])

        XCTAssertEqual(difference.removed, ["STALE_KEY"])
    }

    /// Sorted, so a summary is stable between runs and diffable.
    func testListsAreSorted() {
        let difference = ConfigSync.diff(
            live: ["ZZZ": "1", "AAA": "1", "MMM": "1"],
            declared: [:]
        )

        XCTAssertEqual(difference.added, ["AAA", "MMM", "ZZZ"])
    }

    // MARK: - Files

    func testEncodingIsSortedAndStable() throws {
        let data = try ConfigSync.encode(["B": "2", "A": "1"])
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertLessThan(
            text.range(of: "\"A\"")!.lowerBound,
            text.range(of: "\"B\"")!.lowerBound,
            "keys should be sorted so a rewrite makes a small diff"
        )
        XCTAssertEqual(try ConfigSync.encode(["B": "2", "A": "1"]), data)
    }

    /// A connection string carries slashes, and escaping them makes the file unreadable.
    func testEncodingDoesNotEscapeSlashes() throws {
        let data = try ConfigSync.encode(["DATABASE_URL": "postgresql://host:5432/db"])

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("postgresql://host:5432/db"))
    }

    /// A service that was never synced has no file, and that is a first sync, not an error.
    func testMissingFileReadsAsEmpty() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hatchery-absent-\(UUID().uuidString).json")

        XCTAssertEqual(try ConfigSync.readDeclared(at: url), [:])
    }

    func testDeclaredConfigRoundTrips() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hatchery-sync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let config = ["APP_ID": "mwlab", "DATABASE_URL": "postgresql://h/db"]
        try ConfigSync.encode(config).write(to: url)

        XCTAssertEqual(try ConfigSync.readDeclared(at: url), config)
    }

    /// The manifest names the sidecar by a relative path, so the pair travels together.
    func testConfigPathResolvesAgainstTheManifestDirectory() {
        let service = ServiceSpec(
            name: "mwlab", kind: .mwserver, image: "i", configFile: "mwlab.config.json")

        let url = ConfigSync.configURL(for: service, manifestPath: "/infra/state/hatchery.json")

        XCTAssertEqual(url.path, "/infra/state/mwlab.config.json")
    }

    func testAnAbsoluteConfigPathIsLeftAlone() {
        let service = ServiceSpec(
            name: "mwlab", kind: .mwserver, image: "i", configFile: "/secrets/mwlab.json")

        let url = ConfigSync.configURL(for: service, manifestPath: "/infra/state/hatchery.json")

        XCTAssertEqual(url.path, "/secrets/mwlab.json")
    }
}

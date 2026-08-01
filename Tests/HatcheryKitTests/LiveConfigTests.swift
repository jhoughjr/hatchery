import XCTest
@testable import HatcheryKit

private func labStack(host: String? = "dokku@192.168.0.103", backend: Backend = .dokku) -> StackSpec {
    StackSpec(
        name: "mwlab",
        backend: backend,
        host: host,
        services: [
            ServiceSpec(name: "mwlab", kind: .mwserver, image: "i", domains: ["mwlab.opi"], configFile: "c.json")
        ]
    )
}

final class LiveConfigTests: XCTestCase {
    /// The command is the contract with dokku. A changed flag here silently reads nothing.
    func testDokkuCommandExportsJSONForTheApp() {
        XCTAssertEqual(
            LiveConfigReader.dokkuCommand(host: "dokku@192.168.0.103", app: "mwlab"),
            ["ssh", "-o", "BatchMode=yes", "dokku@192.168.0.103", "config:export", "--format", "json", "mwlab"]
        )
    }

    func testReadsAndParsesTheLiveConfig() async throws {
        let stack = labStack()
        let reader = LiveConfigReader { argv in
            XCTAssertEqual(argv.last, "mwlab")
            XCTAssertTrue(argv.contains("config:export"))
            return Data(#"{"APP_ID":"mwlab-poc","LOG_LEVEL":"info"}"#.utf8)
        }

        let config = try await reader.config(for: stack.services[0], in: stack)

        XCTAssertEqual(config["APP_ID"], "mwlab-poc")
        XCTAssertEqual(config.count, 2)
    }

    func testDokkuStackWithoutAHostFails() async {
        let stack = labStack(host: nil)
        let reader = LiveConfigReader { _ in Data("{}".utf8) }

        do {
            _ = try await reader.config(for: stack.services[0], in: stack)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? LiveConfigError, .noHost(stack: "mwlab"))
        }
    }

    /// App Platform hands back `EV[...]` ciphertext for every SECRET key, so reading it needs a
    /// decision this does not guess at.
    func testAppPlatformIsReportedUnsupportedRatherThanGuessed() async {
        let stack = labStack(backend: .appPlatform)
        let reader = LiveConfigReader { _ in Data("{}".utf8) }

        do {
            _ = try await reader.config(for: stack.services[0], in: stack)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? LiveConfigError, .unsupportedBackend(.appPlatform))
        }
    }

    func testNonMapOutputIsReportedAsMalformed() async {
        let stack = labStack()
        let reader = LiveConfigReader { _ in Data("[1,2,3]".utf8) }

        do {
            _ = try await reader.config(for: stack.services[0], in: stack)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? LiveConfigError, .malformedConfig(service: "mwlab"))
        }
    }

    func testCommandFailurePropagates() async {
        let stack = labStack()
        let failure = CommandFailure(command: "ssh", status: 255, message: "Permission denied")
        let reader = LiveConfigReader { _ in throw failure }

        do {
            _ = try await reader.config(for: stack.services[0], in: stack)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CommandFailure, failure)
            XCTAssertTrue("\(error)".contains("Permission denied"))
        }
    }

    /// The live config is what the contract must be checked against, because a key set by hand
    /// never reaches the declared file.
    func testLiveConfigFeedsTheContractCheck() async throws {
        let stack = labStack()
        let reader = LiveConfigReader { _ in
            Data(#"{"DATABASE_URL":"postgresql://x","APP_ID":"mwlab"}"#.utf8)
        }

        let config = try await reader.config(for: stack.services[0], in: stack)
        let issues = ConfigValidator.validate(config, against: .mwserver(backend: .dokku))

        XCTAssertFalse(ConfigValidator.passes(issues))
        XCTAssertTrue(issues.contains { $0.key == "TEMPORAL_ADDRESS" && $0.severity == .error })
    }
}

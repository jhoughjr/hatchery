import XCTest
@testable import HatcheryKit

final class StackManifestTests: XCTestCase {
    private func labStack() -> StackSpec {
        StackSpec(
            name: "mwlab",
            backend: .dokku,
            host: "dokku@192.168.0.103",
            services: [
                ServiceSpec(
                    name: "mwlab",
                    kind: .mwserver,
                    image: "mwserver2:arm64-bde0f7d-tf",
                    domains: ["mwlab.opi", "mwlab.jimmyhoughjr.net"],
                    configFile: "mwlab.config.json"
                )
            ]
        )
    }

    func testRoundTripsThroughJSON() throws {
        let manifest = StackManifest(stacks: [labStack()])
        let decoded = try StackManifest.decode(from: manifest.encoded())
        XCTAssertEqual(decoded, manifest)
    }

    /// Service kinds should read as bare strings, not `{"rawValue": …}`.
    func testServiceKindEncodesAsBareString() throws {
        let json = String(decoding: try StackManifest(stacks: [labStack()]).encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"kind\" : \"mwserver\""), json)
        XCTAssertFalse(json.contains("rawValue"), json)
    }

    func testDokkuStackWithoutHostIsRejected() {
        let manifest = StackManifest(stacks: [StackSpec(name: "mwlab", backend: .dokku, host: nil)])
        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? ManifestError, .missingHost(stack: "mwlab"))
        }
    }

    func testAppPlatformStackNeedsNoHost() throws {
        let manifest = StackManifest(stacks: [StackSpec(name: "tenant-one", backend: .appPlatform)])
        XCTAssertNoThrow(try manifest.validate())
    }

    func testDuplicateStackNamesAreRejected() {
        let manifest = StackManifest(stacks: [
            StackSpec(name: "tenant-one", backend: .appPlatform),
            StackSpec(name: "tenant-one", backend: .appPlatform),
        ])
        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? ManifestError, .duplicateStack("tenant-one"))
        }
    }

    func testUnsupportedVersionIsRejected() {
        let manifest = StackManifest(version: 99, stacks: [])
        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedVersion(99))
        }
    }

    /// Names must match what `new-tenant.sh` accepts, or a stack valid here fails there.
    func testStackNameRules() {
        XCTAssertTrue(StackName.isValid("mwlab"))
        XCTAssertTrue(StackName.isValid("tenant-one"))
        XCTAssertFalse(StackName.isValid("-leading"))
        XCTAssertFalse(StackName.isValid("trailing-"))
        XCTAssertFalse(StackName.isValid("Upper"))
        XCTAssertFalse(StackName.isValid("ab"))
        XCTAssertFalse(StackName.isValid(String(repeating: "a", count: 31)))
        XCTAssertFalse(StackName.isValid("under_score"))
    }
}

import Foundation
import Testing

@testable import HatcheryKit

@Suite("Finding the manifest")
struct ManifestLocatorTests {
    private let home = "/Users/someone"
    private let cwd = "/somewhere/else"

    @Test("an explicitly named manifest is used as given, so a typo is not papered over")
    func explicitWins() throws {
        // Nothing exists, and it is still returned: whoever opens it reports the absence, which
        // names the path the person actually typed.
        let resolved = try ManifestLocator.resolve(
            "/tmp/mine.json", exists: { _ in false },
            environment: ["HATCHERY_MANIFEST": "/env/one.json"],
            currentDirectory: cwd, home: home)
        #expect(resolved == "/tmp/mine.json")
    }

    @Test("an explicit path has ~ expanded")
    func expandsExplicit() throws {
        let resolved = try ManifestLocator.resolve(
            "~/stacks.json", exists: { _ in false }, environment: [:],
            currentDirectory: cwd, home: home)
        #expect(!resolved.hasPrefix("~"))
        #expect(resolved.hasSuffix("/stacks.json"))
    }

    @Test("the working directory comes first, because that is the least surprising")
    func prefersCurrentDirectory() throws {
        let resolved = try ManifestLocator.resolve(
            "hatchery.json",
            exists: { $0 == "/somewhere/else/hatchery.json" || $0 == "/env/one.json" },
            environment: ["HATCHERY_MANIFEST": "/env/one.json"],
            currentDirectory: cwd, home: home)
        #expect(resolved == "/somewhere/else/hatchery.json")
    }

    @Test("the environment is used when the working directory has none")
    func fallsBackToEnvironment() throws {
        let resolved = try ManifestLocator.resolve(
            "hatchery.json", exists: { $0 == "/env/one.json" },
            environment: ["HATCHERY_MANIFEST": "/env/one.json"],
            currentDirectory: cwd, home: home)
        #expect(resolved == "/env/one.json")
    }

    @Test("the config directory is the last resort")
    func fallsBackToConfigDirectory() throws {
        let expected = "/Users/someone/.config/hatchery/hatchery.json"
        let resolved = try ManifestLocator.resolve(
            "hatchery.json", exists: { $0 == expected }, environment: [:],
            currentDirectory: cwd, home: home)
        #expect(resolved == expected)
    }

    @Test("an empty environment entry is ignored rather than treated as a path")
    func ignoresEmptyEnvironment() throws {
        let expected = "/Users/someone/.config/hatchery/hatchery.json"
        let resolved = try ManifestLocator.resolve(
            "hatchery.json", exists: { $0 == expected },
            environment: ["HATCHERY_MANIFEST": ""],
            currentDirectory: cwd, home: home)
        #expect(resolved == expected)
    }

    @Test("finding nothing lists everywhere it looked")
    func reportsWhereItLooked() {
        #expect(throws: (any Error).self) {
            _ = try ManifestLocator.resolve(
                "hatchery.json", exists: { _ in false },
                environment: ["HATCHERY_MANIFEST": "/env/one.json"],
                currentDirectory: cwd, home: home)
        }

        let error = ManifestLocatorError.notFound(searched: [
            "/somewhere/else/hatchery.json", "/env/one.json",
        ])
        #expect(error.description.contains("/somewhere/else/hatchery.json"))
        #expect(error.description.contains("/env/one.json"))
        #expect(error.description.contains("HATCHERY_MANIFEST"))
    }

    @Test("the search order is stable and does not include duplicates by accident")
    func searchOrder() {
        let paths = ManifestLocator.searchPaths(
            environment: ["HATCHERY_MANIFEST": "~/env.json"],
            currentDirectory: cwd, home: home)
        #expect(paths.count == 3)
        #expect(paths[0] == "/somewhere/else/hatchery.json")
        #expect(paths[1] == "/Users/someone/env.json")
        #expect(paths[2] == "/Users/someone/.config/hatchery/hatchery.json")
    }
}

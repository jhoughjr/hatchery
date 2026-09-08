import Foundation
import Testing

@testable import HatcheryKit

@Suite("The kind files a registry collects beside a manifest")
struct KindRegistryTests {
    private static let rookery = #"{"kind": "rookery", "environment": {"ROOKERY_TOKEN": {"required": true, "secret": true}}}"#
    private static let coop = #"{"kind": "coop", "environment": {}}"#

    /// A fresh manifest directory, with a `kinds/` sibling the registry will make on demand.
    private func fixture() throws -> (manifestPath: String, sourceDirectory: String, cleanup: () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hatchery-kindregistry-\(UUID().uuidString)")
        let sources = base.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let manifestPath = base.appendingPathComponent("hatchery.json").path
        try "{}".write(toFile: manifestPath, atomically: true, encoding: .utf8)
        return (manifestPath, sources.path, { try? FileManager.default.removeItem(at: base) })
    }

    private func write(_ contents: String, named name: String, in directory: String) throws -> String {
        let path = Paths.join(directory, name)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("a file added to the registry is found again by its kind")
    func addsAndFinds() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)

        let source = try write(Self.rookery, named: "hatchery-kind.json", in: fixture.sourceDirectory)
        let added = try registry.add(from: source)
        #expect(added.kind == "rookery")

        let found = try registry.kindFile(for: ServiceKind(rawValue: "rookery"))
        #expect(found?.kind == "rookery")
        #expect(try registry.kindFile(for: ServiceKind(rawValue: "nothing-here")) == nil)
    }

    @Test("re-adding the same kind's file replaces it")
    func replacesSameKind() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)

        let first = try write(Self.rookery, named: "one.json", in: fixture.sourceDirectory)
        try registry.add(from: first)

        let edited = #"{"kind": "rookery", "summary": "edited", "environment": {}}"#
        let second = try write(edited, named: "two.json", in: fixture.sourceDirectory)
        let replaced = try registry.add(from: second)

        #expect(replaced.summary == "edited")
        let found = try registry.kindFile(for: ServiceKind(rawValue: "rookery"))
        #expect(found?.summary == "edited")
    }

    @Test("a slot holding a different kind is not overwritten")
    func refusesACrossKindOverwrite() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)

        // Placed directly, bypassing `add`, to model a slot whose name and content disagree.
        let kindsDirectory = Paths.join(
            URL(fileURLWithPath: fixture.manifestPath).deletingLastPathComponent().path, "kinds")
        try FileManager.default.createDirectory(atPath: kindsDirectory, withIntermediateDirectories: true)
        _ = try write(Self.coop, named: "rookery.json", in: kindsDirectory)

        let incoming = try write(Self.rookery, named: "hatchery-kind.json", in: fixture.sourceDirectory)
        #expect(throws: KindRegistryError.kindMismatch(
            path: Paths.join(kindsDirectory, "rookery.json"), existing: "coop", incoming: "rookery")
        ) {
            try registry.add(from: incoming)
        }
    }

    @Test("all() lists every kind the registry holds")
    func listsEverything() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)

        #expect(try registry.all().isEmpty)

        try registry.add(from: write(Self.rookery, named: "a.json", in: fixture.sourceDirectory))
        try registry.add(from: write(Self.coop, named: "b.json", in: fixture.sourceDirectory))

        let all = try registry.all().map(\.kind).sorted()
        #expect(all == ["coop", "rookery"])
    }

    @Test("ServiceKind.described(in:) unions the built-in kinds with the registry's")
    func describedUnionsBuiltInAndRegistry() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)
        try registry.add(from: write(Self.coop, named: "a.json", in: fixture.sourceDirectory))

        let described = ServiceKind.described(in: registry)
        #expect(described.contains(.mwserver))
        #expect(described.contains(ServiceKind(rawValue: "coop")))
    }

    @Test("the contract overload consults the registry first, and falls back to the built-in table")
    func contractPrefersRegistry() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)
        try registry.add(from: write(Self.rookery, named: "a.json", in: fixture.sourceDirectory))

        let fromRegistry = EnvContract.contract(
            for: ServiceKind(rawValue: "rookery"), backend: .dokku, registry: registry)
        #expect(fromRegistry?.secret == ["ROOKERY_TOKEN"])

        let fallback = EnvContract.contract(for: .mwserver, backend: .dokku, registry: registry)
        #expect(fallback == EnvContract.contract(for: .mwserver, backend: .dokku))
    }
}

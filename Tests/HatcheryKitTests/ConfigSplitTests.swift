import Foundation
import Testing

@testable import HatcheryKit

@Suite("Moving a service's secret keys out of its sidecar")
struct ConfigSplitTests {
    /// A fresh directory holding a manifest, a `kinds/rookery.json` registered from
    /// `KindFileTests.rookery`, and the stack and service that name it. The sidecar and secrets
    /// file both resolve into this same directory, since the stack's tofu directory is it.
    private func fixture() throws -> (
        directory: URL, manifestPath: String, stack: StackSpec, service: ServiceSpec,
        contract: EnvContract, cleanup: () -> Void
    ) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hatchery-configsplit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestPath = directory.appendingPathComponent("hatchery.json").path
        try "{}".write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let sourcePath = directory.appendingPathComponent("hatchery-kind.json").path
        try KindFileTests.rookery.write(toFile: sourcePath, atomically: true, encoding: .utf8)
        let registry = KindRegistry(manifestPath: manifestPath)
        try registry.add(from: sourcePath)
        try FileManager.default.removeItem(atPath: sourcePath)

        let stack = StackSpec(
            name: "estate", backend: .dokku, host: "dokku@h",
            tofu: TofuBinding(directory: directory.path))
        let service = ServiceSpec(
            name: "rookery", kind: ServiceKind(rawValue: "rookery"), image: "rookery",
            configFile: "rookery.config.json")
        let contract = try #require(
            EnvContract.contract(for: service.kind, backend: stack.backend, registry: registry))

        return (directory, manifestPath, stack, service, contract, {
            try? FileManager.default.removeItem(at: directory)
        })
    }

    /// `ROOKERY_TOKEN` is the fixture's only secret key; `ROOKERY_PUBLIC_URL` is required but
    /// not secret, and `ROOKERY_HOST` is neither. Between them they cover the three ways a key
    /// can sit in the contract.
    private let sidecarContent = [
        "ROOKERY_TOKEN": "office-door-key",
        "ROOKERY_PUBLIC_URL": "https://rookery.example.net",
        "ROOKERY_HOST": "0.0.0.0",
    ]

    @Test("split moves the secret key and leaves the rest declared where it was")
    func movesTheSecretKeyAndLeavesTheRest() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        try ConfigSync.encoded(sidecarContent)
            .write(to: fixture.directory.appendingPathComponent("rookery.config.json"))

        let outcome = try ConfigSplitter.split(
            service: fixture.service, in: fixture.stack, manifestPath: fixture.manifestPath,
            contract: fixture.contract, dryRun: false)

        #expect(outcome.moved == ["ROOKERY_TOKEN"])

        let config = try ConfigSync.readDeclared(
            at: fixture.directory.appendingPathComponent("rookery.config.json"))
        let secrets = try ConfigSync.readDeclared(
            at: fixture.directory.appendingPathComponent("rookery.secrets.json"))

        #expect(config == ["ROOKERY_PUBLIC_URL": "https://rookery.example.net", "ROOKERY_HOST": "0.0.0.0"])
        #expect(secrets == ["ROOKERY_TOKEN": "office-door-key"])
    }

    @Test("a later split adds to an existing secrets file rather than replacing it")
    func laterSplitAddsToExistingSecrets() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        try ConfigSync.encoded(["ROOKERY_TOKEN": "office-door-key"])
            .write(to: fixture.directory.appendingPathComponent("rookery.config.json"))
        try ConfigSync.encoded(["OLD_SECRET": "still here"])
            .write(to: fixture.directory.appendingPathComponent("rookery.secrets.json"))

        _ = try ConfigSplitter.split(
            service: fixture.service, in: fixture.stack, manifestPath: fixture.manifestPath,
            contract: fixture.contract, dryRun: false)

        let secrets = try ConfigSync.readDeclared(
            at: fixture.directory.appendingPathComponent("rookery.secrets.json"))
        #expect(secrets == ["OLD_SECRET": "still here", "ROOKERY_TOKEN": "office-door-key"])
    }

    @Test("a dry run reports what would move and writes nothing")
    func dryRunWritesNothing() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let configURL = fixture.directory.appendingPathComponent("rookery.config.json")
        try ConfigSync.encoded(sidecarContent).write(to: configURL)
        let before = try Data(contentsOf: configURL)

        let outcome = try ConfigSplitter.split(
            service: fixture.service, in: fixture.stack, manifestPath: fixture.manifestPath,
            contract: fixture.contract, dryRun: true)

        #expect(outcome.moved == ["ROOKERY_TOKEN"])
        #expect(try Data(contentsOf: configURL) == before)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("rookery.secrets.json").path))
    }

    @Test("nothing to move reports an empty list and writes nothing")
    func nothingToMove() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        try ConfigSync.encoded(["ROOKERY_HOST": "0.0.0.0"])
            .write(to: fixture.directory.appendingPathComponent("rookery.config.json"))

        let outcome = try ConfigSplitter.split(
            service: fixture.service, in: fixture.stack, manifestPath: fixture.manifestPath,
            contract: fixture.contract, dryRun: false)

        #expect(outcome.moved.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("rookery.secrets.json").path))
    }

    /// A sidecar in a sealed directory the archive has never covered reads as unsealed by
    /// `SealAudit.status(root:)`: no `secrets.manifest` means every on-disk secret is unrecorded.
    @Test("a sidecar the archive has never sealed refuses the split")
    func unsealedSidecarRefuses() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        try ConfigSync.encoded(sidecarContent)
            .write(to: fixture.directory.appendingPathComponent("rookery.config.json"))
        try Data().write(to: fixture.directory.appendingPathComponent(".age-recipient"))

        #expect(throws: ConfigSplitError.sidecarUnsealed(
            service: "rookery", path: "rookery.config.json")) {
            try ConfigSplitter.split(
                service: fixture.service, in: fixture.stack, manifestPath: fixture.manifestPath,
                contract: fixture.contract, dryRun: false)
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("rookery.secrets.json").path))
    }

    // MARK: - config audit's "secret in the sidecar" finding

    @Test("audit reports the finding before the split and not after")
    func auditFindingClearsAfterASplit() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let configURL = fixture.directory.appendingPathComponent("rookery.config.json")
        try ConfigSync.encoded(sidecarContent).write(to: configURL)

        let before = ConfigValidator.secretInSidecar(
            try ConfigSync.readDeclared(at: configURL), against: fixture.contract)
        #expect(before.map(\.key) == ["ROOKERY_TOKEN"])

        _ = try ConfigSplitter.split(
            service: fixture.service, in: fixture.stack, manifestPath: fixture.manifestPath,
            contract: fixture.contract, dryRun: false)

        let after = ConfigValidator.secretInSidecar(
            try ConfigSync.readDeclared(at: configURL), against: fixture.contract)
        #expect(after.isEmpty)
    }
}

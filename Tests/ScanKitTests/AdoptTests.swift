import Foundation
import HatcheryKit
import Testing

@testable import ScanKit

@Suite("Adopting a running app into the manifest")
struct AdoptTests {
    private static let inspect = """
        [{"Config": {"Image": "dokku/mwlab:latest",
                     "Labels": {"com.dokku.docker-image-labeler/alternate-tags":
                                "[\\"mhehmsoth/mwserver2:arm64-9cb6e4c-dev\\"]"}}}]
        """

    private static func fakeBox(_ argv: [String]) -> CommandOutput {
        let command = argv.dropFirst(6).joined(separator: " ")
        switch command {
        case "domains:report mwlab --domains-app-vhosts":
            return CommandOutput(status: 0, standardOutput: "mwlab.opi mwlab.jimmyhoughjr.net\n")
        case "ports:report mwlab --ports-map":
            return CommandOutput(status: 0, standardOutput: "http:80:8080\n")
        case "network:report mwlab --network-attach-post-create":
            return CommandOutput(status: 0, standardOutput: "macworkstack-infra_default\n")
        case "ps:inspect mwlab":
            return CommandOutput(status: 0, standardOutput: inspect)
        case "config:export --format json mwlab":
            return CommandOutput(
                status: 0, standardOutput: #"{"APP_ID": "mwlab", "DATABASE_URL": "postgres://x"}"#)
        default:
            return CommandOutput(status: 1, standardOutput: "", standardError: "unknown \(command)")
        }
    }

    @Test("facts come off the box: the real image, domains, port, network, and config")
    func readsFacts() async throws {
        let adopter = Adopter(execute: { argv, _ in Self.fakeBox(argv) })
        let facts = try await adopter.facts(for: "mwlab", on: "dokku@192.168.0.103")
        #expect(facts.image == "mhehmsoth/mwserver2:arm64-9cb6e4c-dev")
        #expect(facts.domains == ["mwlab.opi", "mwlab.jimmyhoughjr.net"])
        #expect(facts.containerPort == 8080)
        #expect(facts.network == "macworkstack-infra_default")
        #expect(facts.config == ["APP_ID": "mwlab", "DATABASE_URL": "postgres://x"])
    }

    @Test("the image falls back to dokku's retag when no alternate tag is kept")
    func imageFallback() {
        let bare = #"[{"Config": {"Image": "dokku/wiki:latest", "Labels": {}}}]"#
        #expect(Adopter.image(fromInspect: bare, app: "wiki") == "dokku/wiki:latest")
        #expect(Adopter.image(fromInspect: "not json", app: "wiki") == "dokku/wiki:latest")
        #expect(Adopter.containerPort(fromPortMap: "https:443:3000 http:80:3000") == 3000)
        #expect(Adopter.containerPort(fromPortMap: "") == 8080)
    }

    @Test("the kind is read from the image when it says, and is a question when it does not")
    func infersKind() {
        #expect(Adopter.inferKind(fromImage: "mhehmsoth/mwserver2:arm64") == .mwserver)
        #expect(Adopter.inferKind(fromImage: "x/payment-gateway:1") == .paymentGateway)
        #expect(Adopter.inferKind(fromImage: "x/comlab:1") == .communicationGateway)
        #expect(Adopter.inferKind(fromImage: "ghost:5") == nil)
    }

    @Test("the plan declares the service into the stack with the box's config, not minted values")
    func plansAdoption() async throws {
        let adopter = Adopter(execute: { argv, _ in Self.fakeBox(argv) })
        let facts = try await adopter.facts(for: "mwlab", on: "dokku@192.168.0.103")
        let manifest = StackManifest(stacks: [
            StackSpec(
                name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
                tofu: TofuBinding(directory: "/tmp/lab"))
        ])
        let result = try await adopter.plan(
            facts, kind: .mwserver, into: "lab", box: "dokku@192.168.0.103", manifest: manifest)

        #expect(result.manifest.stack(named: "lab")?.services.map(\.name) == ["mwlab"])
        #expect(result.service.image == "mhehmsoth/mwserver2:arm64-9cb6e4c-dev")
        let config = result.files.first { $0.role == .config }
        #expect(config?.path == "mwlab.config.json")
        let written = try JSONDecoder().decode(
            [String: String].self, from: Data((config?.contents ?? "").utf8))
        #expect(written == ["APP_ID": "mwlab", "DATABASE_URL": "postgres://x"])
        #expect(result.files.contains { $0.role == .declaration })
        #expect(result.importCommand == "tofu import dokku_app.mwlab mwlab")
    }

    @Test("a stack on another box, or an app already declared, is refused")
    func refusals() async throws {
        let adopter = Adopter(execute: { argv, _ in Self.fakeBox(argv) })
        let facts = try await adopter.facts(for: "mwlab", on: "dokku@192.168.0.103")
        let elsewhere = StackManifest(stacks: [
            StackSpec(name: "far", backend: .dokku, host: "dokku@10.0.0.9", tofu: TofuBinding(directory: "/tmp/far"))
        ])
        await #expect(throws: AdoptError.stackNotOnBox(stack: "far", box: "dokku@192.168.0.103")) {
            try await adopter.plan(facts, kind: .mwserver, into: "far", box: "dokku@192.168.0.103", manifest: elsewhere)
        }
        let declared = StackManifest(stacks: [
            StackSpec(
                name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
                tofu: TofuBinding(directory: "/tmp/lab"),
                services: [ServiceSpec(name: "mwlab", kind: .mwserver, image: "x", configFile: "c")])
        ])
        await #expect(throws: AdoptError.alreadyDeclared(app: "mwlab", stack: "lab")) {
            try await adopter.plan(facts, kind: .mwserver, into: "lab", box: "dokku@192.168.0.103", manifest: declared)
        }
    }

    // MARK: - Resolving the kind

    private static let rookeryKindFile = #"{"kind": "rookery", "port": 5000, "healthcheck": "/healthz", "environment": {"ROOKERY_TOKEN": {"required": true, "secret": true}}}"#

    /// A fresh manifest directory with nothing in `kinds/` yet.
    private func registryFixture() throws -> (manifestPath: String, sourceDirectory: String, cleanup: () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hatchery-adopt-\(UUID().uuidString)")
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

    @Test("--kind-file wins first, ahead of the registry, --kind, and the image")
    func resolvesFromKindFileFirst() throws {
        let fixture = try registryFixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)
        let path = try write(Self.rookeryKindFile, named: "hatchery-kind.json", in: fixture.sourceDirectory)

        let resolved = try Adopter.resolveKind(
            app: "rookery", kindFilePath: path, kindOption: .paymentGateway,
            image: "mhehmsoth/mwserver2:1", registry: registry)

        #expect(resolved.kind == ServiceKind(rawValue: "rookery"))
        #expect(resolved.kindFile?.port == 5000)
    }

    @Test("the registry is tried next, by a kind equal to the app's own name")
    func resolvesFromRegistryByAppName() throws {
        let fixture = try registryFixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)
        try registry.add(from: write(Self.rookeryKindFile, named: "hatchery-kind.json", in: fixture.sourceDirectory))

        let resolved = try Adopter.resolveKind(
            app: "rookery", kindFilePath: nil, kindOption: .paymentGateway,
            image: "mhehmsoth/mwserver2:1", registry: registry)

        #expect(resolved.kind == ServiceKind(rawValue: "rookery"))
        #expect(resolved.kindFile?.healthcheck == "/healthz")
    }

    @Test("--kind is tried next, when neither a kind file nor the registry says")
    func resolvesFromKindOption() throws {
        let fixture = try registryFixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)

        let resolved = try Adopter.resolveKind(
            app: "mwlab", kindFilePath: nil, kindOption: .paymentGateway,
            image: "ghost:1", registry: registry)

        #expect(resolved.kind == .paymentGateway)
        #expect(resolved.kindFile == nil)
    }

    @Test("the image is tried last, when nothing else says")
    func resolvesFromImage() throws {
        let fixture = try registryFixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)

        let resolved = try Adopter.resolveKind(
            app: "mwlab", kindFilePath: nil, kindOption: nil,
            image: "mhehmsoth/mwserver2:1", registry: registry)

        #expect(resolved.kind == .mwserver)
        #expect(resolved.kindFile == nil)
    }

    @Test("naming none of the three ways is refused, naming all three")
    func refusesWhenNothingSays() throws {
        let fixture = try registryFixture()
        defer { fixture.cleanup() }
        let registry = KindRegistry(manifestPath: fixture.manifestPath)

        #expect(throws: AdoptError.kindUnknown(app: "mwlab", image: "ghost:1")) {
            try Adopter.resolveKind(
                app: "mwlab", kindFilePath: nil, kindOption: nil, image: "ghost:1", registry: registry)
        }
        let description = AdoptError.kindUnknown(app: "mwlab", image: "ghost:1").description
        #expect(description.contains("--kind-file"))
        #expect(description.contains("registry"))
        #expect(description.contains("--kind"))
    }

    // MARK: - A clean plan after import

    @Test("the generated resource text carries the measured host port and disabled checks")
    func planCarriesMeasuredPortsAndChecks() async throws {
        let adopter = Adopter(execute: { argv, _ in
            let command = argv.dropFirst(6).joined(separator: " ")
            switch command {
            case "domains:report mwlab --domains-app-vhosts":
                return CommandOutput(status: 0, standardOutput: "mwlab.opi\n")
            case "ports:report mwlab --ports-map":
                return CommandOutput(status: 0, standardOutput: "http:8080:8080\n")
            case "network:report mwlab --network-attach-post-create":
                return CommandOutput(status: 0, standardOutput: "\n")
            case "ps:inspect mwlab":
                return CommandOutput(
                    status: 0, standardOutput: #"[{"Config": {"Image": "dokku/mwlab:latest", "Labels": {}}}]"#)
            case "config:export --format json mwlab":
                return CommandOutput(status: 0, standardOutput: #"{"APP_ID": "mwlab"}"#)
            case "checks:report mwlab --checks-disabled-list":
                return CommandOutput(status: 0, standardOutput: "web\n")
            default:
                return CommandOutput(status: 1, standardOutput: "", standardError: "unknown \(command)")
            }
        })
        let facts = try await adopter.facts(for: "mwlab", on: "dokku@192.168.0.103")
        #expect(facts.hostPort == "8080")
        #expect(facts.checksDisabled == true)

        let manifest = StackManifest(stacks: [
            StackSpec(
                name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
                tofu: TofuBinding(directory: "/tmp/lab"))
        ])
        let result = try await adopter.plan(
            facts, kind: .mwserver, into: "lab", box: "dokku@192.168.0.103", manifest: manifest)

        let declaration = try #require(result.files.first { $0.role == .declaration })
        #expect(declaration.contents.contains(#""8080" = {"#))
        #expect(declaration.contents.contains(#"status = "disabled""#))
        #expect(declaration.contents.contains(#"container_port = "8080""#))
    }

    @Test("checks are left out of the generated text when the box does not disable them")
    func planOmitsCheckBlockWhenEnabled() async throws {
        let adopter = Adopter(execute: { argv, _ in
            let command = argv.dropFirst(6).joined(separator: " ")
            switch command {
            case "domains:report web --domains-app-vhosts":
                return CommandOutput(status: 0, standardOutput: "web.opi\n")
            case "ports:report web --ports-map":
                return CommandOutput(status: 0, standardOutput: "http:80:8080\n")
            case "network:report web --network-attach-post-create":
                return CommandOutput(status: 0, standardOutput: "\n")
            case "ps:inspect web":
                return CommandOutput(
                    status: 0, standardOutput: #"[{"Config": {"Image": "dokku/web:latest", "Labels": {}}}]"#)
            case "config:export --format json web":
                return CommandOutput(status: 0, standardOutput: "{}")
            case "checks:report web --checks-disabled-list":
                return CommandOutput(status: 0, standardOutput: "\n")
            default:
                return CommandOutput(status: 1, standardOutput: "", standardError: "unknown \(command)")
            }
        })
        let facts = try await adopter.facts(for: "web", on: "dokku@192.168.0.103")
        #expect(facts.checksDisabled == false)

        let manifest = StackManifest(stacks: [
            StackSpec(
                name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
                tofu: TofuBinding(directory: "/tmp/lab"))
        ])
        let result = try await adopter.plan(
            facts, kind: .mwserver, into: "lab", box: "dokku@192.168.0.103", manifest: manifest)

        let declaration = try #require(result.files.first { $0.role == .declaration })
        #expect(!declaration.contents.contains("checks = {"))
    }

    @Test("a resolved kind file's healthcheck and port win over what adopt measured")
    func planTakesHealthPathAndPortFromKindFile() async throws {
        let adopter = Adopter(execute: { argv, _ in Self.fakeBox(argv) })
        let facts = try await adopter.facts(for: "mwlab", on: "dokku@192.168.0.103")
        let manifest = StackManifest(stacks: [
            StackSpec(
                name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
                tofu: TofuBinding(directory: "/tmp/lab"))
        ])
        let fixture = try registryFixture()
        defer { fixture.cleanup() }
        let kindFilePath = try write(
            Self.rookeryKindFile, named: "hatchery-kind.json", in: fixture.sourceDirectory)
        let kindFile = try KindFile.load(atPath: kindFilePath)

        let result = try await adopter.plan(
            facts, kind: ServiceKind(rawValue: "rookery"), into: "lab", box: "dokku@192.168.0.103",
            manifest: manifest, kindFile: kindFile)

        #expect(result.service.healthPath == "/healthz")
        let declaration = try #require(result.files.first { $0.role == .declaration })
        #expect(declaration.contents.contains(#"container_port = "5000""#))
    }

    // MARK: - The underscore rule

    @Test("tofuIdentifier folds a hyphenated app name into a valid terraform identifier")
    func foldsHyphensToUnderscores() {
        #expect(tofuIdentifier(for: "ci-live") == "ci_live")
        #expect(tofuIdentifier(for: "mwlab") == "mwlab")
    }

    @Test("the import command names the folded identifier")
    func importCommandUsesTheFoldedIdentifier() async throws {
        let adopter = Adopter(execute: { argv, _ in
            let command = argv.dropFirst(6).joined(separator: " ")
            switch command {
            case "domains:report ci-live --domains-app-vhosts":
                return CommandOutput(status: 0, standardOutput: "ci-live.opi\n")
            case "ports:report ci-live --ports-map":
                return CommandOutput(status: 0, standardOutput: "http:80:8080\n")
            case "network:report ci-live --network-attach-post-create":
                return CommandOutput(status: 0, standardOutput: "\n")
            case "ps:inspect ci-live":
                return CommandOutput(
                    status: 0, standardOutput: #"[{"Config": {"Image": "dokku/ci-live:latest", "Labels": {}}}]"#)
            case "config:export --format json ci-live":
                return CommandOutput(status: 0, standardOutput: "{}")
            case "checks:report ci-live --checks-disabled-list":
                return CommandOutput(status: 0, standardOutput: "\n")
            default:
                return CommandOutput(status: 1, standardOutput: "", standardError: "unknown \(command)")
            }
        })
        let facts = try await adopter.facts(for: "ci-live", on: "dokku@192.168.0.103")
        let manifest = StackManifest(stacks: [
            StackSpec(
                name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
                tofu: TofuBinding(directory: "/tmp/lab"))
        ])
        let result = try await adopter.plan(
            facts, kind: .mwserver, into: "lab", box: "dokku@192.168.0.103", manifest: manifest)

        #expect(result.importCommand == "tofu import dokku_app.ci_live ci-live")
    }
}

@Suite("One adopter at a time")
struct AdoptLockTests {
    private func fixture() throws -> (directory: String, cleanup: () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hatchery-adoptlock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base.path, { try? FileManager.default.removeItem(at: base) })
    }

    @Test("a fresh lock acquires and releases cleanly")
    func acquiresAndReleases() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let lock = AdoptLock(manifestDirectory: fixture.directory)

        try lock.acquire()
        #expect(FileManager.default.fileExists(atPath: lock.path))
        lock.release()
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test("a lock held less than an hour refuses, naming the holder's pid and time")
    func refusesAFreshHold() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let lock = AdoptLock(manifestDirectory: fixture.directory)
        // ISO 8601 round-trips to whole seconds, so the expectation is built from that,
        // not the sub-second `Date` that went in.
        let startedAt = Date(timeIntervalSince1970: Date().addingTimeInterval(-60).timeIntervalSince1970.rounded())

        try lock.acquire(now: startedAt, pid: 4242)

        #expect(throws: AdoptLockError.held(pid: 4242, since: startedAt)) {
            try lock.acquire(now: Date(), pid: 9999)
        }
    }

    @Test("a lock older than an hour is taken over, with one line reported")
    func takesOverAStaleLock() throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let lock = AdoptLock(manifestDirectory: fixture.directory)
        let staleStart = Date().addingTimeInterval(-3700)

        try lock.acquire(now: staleStart, pid: 4242)

        var reported: [String] = []
        try lock.acquire(now: Date(), pid: 9999, report: { reported.append($0) })

        #expect(reported.count == 1)
        #expect(reported.first?.contains("4242") == true)
    }
}

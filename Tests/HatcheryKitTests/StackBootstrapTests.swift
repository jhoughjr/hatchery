import Foundation
import Testing

@testable import HatcheryKit

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    private var commands: [(argv: [String], directory: String?)] = []
    private var directories: [String] = []

    init(files: [String: String] = [:]) { self.files = files }

    var written: [String: String] { lock.withLock { files } }
    var ran: [(argv: [String], directory: String?)] { lock.withLock { commands } }
    var madeDirectories: [String] { lock.withLock { directories } }

    func write(_ path: String, _ contents: String) { lock.withLock { files[path] = contents } }
    func exists(_ path: String) -> Bool { lock.withLock { files[path] != nil } }
    func record(_ argv: [String], _ directory: String?) { lock.withLock { commands.append((argv, directory)) } }
    func makeDirectory(_ path: String) { lock.withLock { directories.append(path) } }
}

private func bootstrapper(
    _ recorder: Recorder,
    initStatus: Int32 = 0
) -> StackBootstrapper {
    StackBootstrapper(
        execute: { argv, directory in
            recorder.record(argv, directory)
            return CommandOutput(
                status: initStatus,
                standardOutput: initStatus == 0 ? "OpenTofu has been successfully initialized!" : "",
                standardError: initStatus == 0 ? "" : "no provider named dokku")
        },
        writeFile: { recorder.write($0, $1) },
        fileExists: { recorder.exists($0) },
        createDirectory: { recorder.makeDirectory($0) },
        // Fixed rather than ambient, so these do not pass or fail on what the shell exports.
        environment: ["DIGITALOCEAN_TOKEN": "present-for-tests"]
    )
}

@Suite("Creating a stack from nothing")
struct StackBootstrapTests {
    @Test("the three files a tofu directory needs are planned")
    func plansConfiguration() throws {
        let result = try bootstrapper(Recorder()).plan(
            name: "newlab", backend: .dokku, host: "dokku@10.0.0.5", tofuDir: "/infra/newlab")

        #expect(Set(result.files.map(\.path)) == ["versions.tf", "providers.tf", "variables.tf"])
        #expect(result.stack.name == "newlab")
        #expect(result.stack.tofu?.directory == "/infra/newlab")
        #expect(result.stack.services.isEmpty)
    }

    @Test("the host is recorded without the ssh user, which the provider supplies itself")
    func stripsSSHUser() throws {
        let result = try bootstrapper(Recorder()).plan(
            name: "newlab", backend: .dokku, host: "dokku@10.0.0.5", tofuDir: "/infra/newlab")
        let variables = try #require(result.files.first { $0.path == "variables.tf" })

        #expect(variables.contents.contains("default     = \"10.0.0.5\""))
        #expect(!variables.contents.contains("dokku@10.0.0.5"))
        // The stack still records the full SSH target, which is what lifecycle commands use.
        #expect(result.stack.host == "dokku@10.0.0.5")
    }

    @Test("the manifest lands beside the configuration it describes")
    func manifestBesideConfiguration() throws {
        let result = try bootstrapper(Recorder()).plan(
            name: "newlab", backend: .dokku, host: "dokku@h", tofuDir: "/infra/newlab")
        #expect(result.manifestPath == "/infra/newlab/hatchery.json")
    }

    @Test("an existing configuration is never written over")
    func refusesOccupiedDirectory() {
        let occupied = Recorder(files: ["/infra/newlab/versions.tf": "terraform {}"])
        #expect(throws: BootstrapError.directoryNotEmpty("/infra/newlab")) {
            _ = try bootstrapper(occupied).plan(
                name: "newlab", backend: .dokku, host: "dokku@h", tofuDir: "/infra/newlab")
        }
    }

    @Test("a second stack is added to the manifest rather than replacing the first")
    func extendsManifest() throws {
        let existing = StackManifest(stacks: [
            StackSpec(name: "mwlab", backend: .dokku, host: "dokku@h")
        ])
        let result = try bootstrapper(Recorder()).plan(
            name: "newlab", backend: .dokku, host: "dokku@h", tofuDir: "/infra/newlab",
            into: existing)

        #expect(result.manifest.stacks.count == 2)
        #expect(result.manifest.stack(named: "mwlab") != nil)
        #expect(result.manifest.stack(named: "newlab") != nil)
    }

    @Test("a duplicate stack name is refused")
    func refusesDuplicate() {
        let existing = StackManifest(stacks: [
            StackSpec(name: "mwlab", backend: .dokku, host: "dokku@h")
        ])
        #expect(throws: BootstrapError.stackExists("mwlab")) {
            _ = try bootstrapper(Recorder()).plan(
                name: "mwlab", backend: .dokku, host: "dokku@h", tofuDir: "/infra/x",
                into: existing)
        }
    }

    @Test("an invalid stack name is refused before anything is written")
    func refusesBadName() {
        #expect(throws: ManifestError.invalidStackName("Not A Name")) {
            _ = try bootstrapper(Recorder()).plan(
                name: "Not A Name", backend: .dokku, host: "dokku@h", tofuDir: "/infra/x")
        }
    }

    @Test("every backend the registry calls authorable can actually be bootstrapped")
    func bootstrapsEveryAuthorableBackend() throws {
        // App Platform used to be refused here on a claim that turned out to be wrong. The
        // guard still exists — it asks the provider rather than naming backends — but nothing
        // currently trips it, so this asserts the positive case for all of them instead.
        for backend in Backend.allCases where Providers.support(for: backend).authorable {
            let result = try bootstrapper(Recorder()).plan(
                name: "lab", backend: backend, host: "dokku@h", tofuDir: "/infra/lab",
                settings: ["project": "a-project"])
            #expect(!result.files.isEmpty, "\(backend.rawValue) planned no files")
            #expect(result.stack.backend == backend)
        }
    }

    @Test("creating writes the files and runs tofu init in the new directory")
    func createsAndInitialises() async throws {
        let recorder = Recorder()
        let tool = bootstrapper(recorder)
        let planned = try tool.plan(
            name: "newlab", backend: .dokku, host: "dokku@h", tofuDir: "/infra/newlab")
        let created = try await tool.create(planned)

        #expect(recorder.madeDirectories.contains("/infra/newlab"))
        #expect(recorder.written["/infra/newlab/versions.tf"]?.contains("aliksend/dokku") == true)
        #expect(recorder.written["/infra/newlab/providers.tf"]?.contains("ssh_user = \"dokku\"") == true)
        #expect(recorder.ran.count == 1)
        #expect(recorder.ran[0].argv == ["tofu", "init", "-input=false", "-no-color"])
        #expect(recorder.ran[0].directory == "/infra/newlab")
        #expect(created.initOutput?.contains("successfully initialized") == true)
    }

    @Test("a failed init is an error rather than a stack that cannot plan")
    func failedInit() async throws {
        let recorder = Recorder()
        let tool = bootstrapper(recorder, initStatus: 1)
        let planned = try tool.plan(
            name: "newlab", backend: .dokku, host: "dokku@h", tofuDir: "/infra/newlab")

        await #expect(throws: BootstrapError.self) {
            _ = try await tool.create(planned)
        }
    }

    @Test("the generated configuration names the provider the lab actually uses")
    func generatesCorrectProvider() throws {
        let result = try bootstrapper(Recorder()).plan(
            name: "newlab", backend: .dokku, host: "dokku@h", tofuDir: "/infra/newlab")
        let versions = try #require(result.files.first { $0.path == "versions.tf" })
        // aliksend/dokku, not hashicorp/dokku — the latter does not exist and init would fail.
        #expect(versions.contents.contains("source  = \"aliksend/dokku\""))
    }
}

@Suite("Filling in values")
struct ConfigApplyTests {
    @Test("a value is merged in, leaving everything hatchery minted alone")
    func merges() {
        let declared = ["KEYPAIR_JWKS": "{...}", "APP_URL": "http://x", "DATABASE_PASSWORD": ""]
        let result = ConfigSync.applying(["DATABASE_PASSWORD": "hunter2"], to: declared)

        #expect(result["DATABASE_PASSWORD"] == "hunter2")
        #expect(result["KEYPAIR_JWKS"] == "{...}")
        #expect(result["APP_URL"] == "http://x")
    }

    @Test("an empty value removes the key rather than writing a convincing blank")
    func emptyRemoves() {
        let result = ConfigSync.applying(["APP_URL": ""], to: ["APP_URL": "http://x", "A": "b"])
        #expect(result["APP_URL"] == nil)
        #expect(result["A"] == "b")
    }

    @Test("config resolves against the stack's own tofu directory, not the manifest's")
    func resolvesAgainstStack() {
        let service = ServiceSpec(
            name: "paylab2", kind: .paymentGateway, image: "i", configFile: "paylab2.config.json")
        let stack = StackSpec(
            name: "other", backend: .dokku, host: "dokku@h",
            tofu: TofuBinding(directory: "/infra/other"), services: [service])

        let url = ConfigSync.configURL(
            for: service, in: stack, manifestPath: "/somewhere/else/hatchery.json")
        #expect(url.path == "/infra/other/paylab2.config.json")
    }

    @Test("with no tofu binding it still resolves against the manifest, as it always did")
    func fallsBackToManifestDirectory() {
        let service = ServiceSpec(
            name: "mwlab", kind: .mwserver, image: "i", configFile: "mwlab.config.json")
        let url = ConfigSync.configURL(
            for: service, in: nil, manifestPath: "/infra/mwserver-tf/hatchery.json")
        #expect(url.path == "/infra/mwserver-tf/mwlab.config.json")
    }
}

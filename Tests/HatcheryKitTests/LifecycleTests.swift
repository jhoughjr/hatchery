import XCTest
@testable import HatcheryKit

private func stack(
    backend: Backend = .dokku,
    host: String? = "dokku@192.168.0.103",
    environment: Environment? = nil
) -> StackSpec {
    StackSpec(
        name: "mwlab",
        backend: backend,
        environment: environment,
        host: host,
        services: [
            ServiceSpec(name: "mwlab", kind: .mwserver, image: "i", domains: ["mwlab.opi"], configFile: "c.json"),
            ServiceSpec(name: "paylab", kind: .paymentGateway, image: "i", domains: ["paylab.opi"], configFile: "p.json"),
        ]
    )
}

final class LifecycleTests: XCTestCase {
    /// The command is the contract with dokku. A changed verb here silently does nothing useful.
    func testCommandsUseTheDokkuPsVerbs() {
        XCTAssertEqual(
            LifecycleRunner.command(host: "dokku@h", action: .start, app: "mwlab"),
            ["ssh", "-o", "BatchMode=yes", "dokku@h", "ps:start", "mwlab"]
        )
        XCTAssertEqual(LifecycleRunner.Action.stop.rawValue, "ps:stop")
        XCTAssertEqual(LifecycleRunner.Action.restart.rawValue, "ps:restart")
    }

    func testStartReportsSuccessAndSendsTheAppName() async {
        let spec = stack()
        let runner = LifecycleRunner { argv in
            XCTAssertEqual(argv.last, "mwlab")
            XCTAssertTrue(argv.contains("ps:start"))
            return Data()
        }

        let result = await runner.perform(.start, on: spec.services[0], in: spec)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.action, "start")
        XCTAssertNil(result.reason)
    }

    func testAFailedCommandIsReportedNotThrown() async {
        let spec = stack()
        let runner = LifecycleRunner { _ in
            throw CommandFailure(command: "ssh", status: 1, message: "App mwlab does not exist")
        }

        let result = await runner.perform(.stop, on: spec.services[0], in: spec)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.reason?.contains("does not exist") ?? false)
    }

    /// Every service, in the order the manifest declared them.
    func testStackActionCoversEveryServiceInOrder() async {
        let spec = stack()
        let runner = LifecycleRunner { _ in Data() }

        let results = await runner.perform(.restart, on: spec)

        XCTAssertEqual(results.map(\.service), ["mwlab", "paylab"])
        XCTAssertTrue(results.allSatisfy(\.succeeded))
    }

    func testDokkuStackWithoutAHostFails() async {
        let spec = stack(host: nil)
        let runner = LifecycleRunner { _ in Data() }

        let result = await runner.perform(.start, on: spec.services[0], in: spec)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.reason?.contains("no host") ?? false)
    }

    /// App Platform has no `ps` verbs, and guessing an equivalent would act on the wrong thing.
    func testAppPlatformIsReportedUnsupported() async {
        let spec = stack(backend: .appPlatform, host: nil)
        let runner = LifecycleRunner { _ in Data() }

        let result = await runner.perform(.start, on: spec.services[0], in: spec)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.reason?.contains("appPlatform") ?? false)
    }

    func testRunningReadsTheDokkuAnswer() async throws {
        let spec = stack()
        let running = try await LifecycleRunner { _ in Data("true\n".utf8) }
            .isRunning(spec.services[0], in: spec)
        let stopped = try await LifecycleRunner { _ in Data("false\n".utf8) }
            .isRunning(spec.services[0], in: spec)

        XCTAssertTrue(running)
        XCTAssertFalse(stopped)
    }

    // MARK: - Environment

    /// An unlabelled stack must not read as production, or every lab action needs a flag.
    func testUnlabelledStackIsDev() {
        XCTAssertEqual(stack().resolvedEnvironment, .dev)
        XCTAssertFalse(stack().resolvedEnvironment.isProduction)
        XCTAssertTrue(stack(environment: .prod).resolvedEnvironment.isProduction)
        XCTAssertFalse(stack(environment: .staging).resolvedEnvironment.isProduction)
    }

    func testEnvironmentEncodesAsABareString() throws {
        let manifest = StackManifest(stacks: [stack(environment: .prod)])
        let json = String(decoding: try manifest.encoded(), as: UTF8.self)

        XCTAssertTrue(json.contains("\"environment\" : \"prod\""), json)
        XCTAssertFalse(json.contains("rawValue"), json)
    }

    /// A manifest written before environments existed must still read.
    func testManifestWithoutAnEnvironmentStillDecodes() throws {
        let json = """
        {"version":1,"stacks":[{"name":"mwlab","backend":"dokku","host":"dokku@h","services":[]}]}
        """
        let decoded = try StackManifest.decode(from: Data(json.utf8))

        XCTAssertNil(decoded.stacks[0].environment)
        XCTAssertEqual(decoded.stacks[0].resolvedEnvironment, .dev)
    }

    /// These raw values match the administration tier's `service_kind` enum. A rename on either
    /// side turns the eventual join into a translation table.
    func testServiceKindsMatchTheRegistryEnum() {
        XCTAssertEqual(
            ServiceKind.all.map(\.rawValue),
            ["mwserver", "payment-gateway", "communication-gateway", "gsx-gateway", "bucket", "edge"]
        )
    }

    /// hatchery carries the registry's identifier but never mints one.
    func testDeploymentIDRoundTrips() throws {
        var spec = stack()
        spec.services[0].deploymentID = "dep-01j9x2"
        let decoded = try StackManifest.decode(from: StackManifest(stacks: [spec]).encoded())

        XCTAssertEqual(decoded.stacks[0].services[0].deploymentID, "dep-01j9x2")
        XCTAssertNil(decoded.stacks[0].services[1].deploymentID)
    }
}

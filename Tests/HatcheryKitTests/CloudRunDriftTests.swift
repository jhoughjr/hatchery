import Foundation
import Testing

@testable import HatcheryKit

@Suite("Drift on Cloud Run, asked through gcloud")
struct CloudRunDriftTests {
    private static func fake(_ argv: [String]) throws -> Data {
        let joined = argv.joined(separator: " ")
        if joined.hasPrefix("sh -c command -v gcloud") { return Data("/usr/bin/gcloud".utf8) }
        if joined.contains("run services describe mwgcp ") { return Data("mwgcp-00003-abc\n".utf8) }
        if joined.contains("run revisions describe mwgcp-00003-abc ") {
            return Data("us-central1-docker.pkg.dev/mws-lab/images/mwserver@sha256:aaa\n".utf8)
        }
        if joined.contains("artifacts docker images describe us-central1-docker.pkg.dev/mws-lab/images/mwserver:staging") {
            return Data("sha256:bbb\n".utf8)
        }
        if joined.contains("run services describe quiet ") { return Data("\n".utf8) }
        throw CommandFailure(command: "gcloud", status: 1, message: "no")
    }

    @Test("a moved Artifact Registry tag is drift, and a service with no ready revision is not checkable")
    func checks() async {
        let drift = CloudRunDrift(run: { argv in try Self.fake(argv) })
        let moved = await drift.check(stack: StackSpec(
            name: "mwgcp", backend: .cloudRun, settings: ["project": "mws-lab", "region": "us-central1"],
            services: [ServiceSpec(name: "mwgcp", kind: .mwserver, image: "us-central1-docker.pkg.dev/mws-lab/images/mwserver:staging", configFile: "c")]))
        #expect(moved == ["mwgcp: the registry's tag staging has moved past what Cloud Run deployed — applying pulls and runs new code"])

        let quiet = await drift.check(stack: StackSpec(
            name: "quiet", backend: .cloudRun,
            services: [ServiceSpec(name: "quiet", kind: .mwserver, image: "x/y:z", configFile: "c")]))
        #expect(quiet.first?.contains("no ready revision") == true)
    }

    @Test("without gcloud every service says so, and other backends are not its business")
    func noGcloud() async {
        let drift = CloudRunDrift(run: { _ in throw CommandFailure(command: "sh", status: 1, message: "") })
        let lines = await drift.check(stack: StackSpec(
            name: "s", backend: .cloudRun,
            services: [ServiceSpec(name: "a", kind: .mwserver, image: "x:y", configFile: "c")]))
        #expect(lines == ["a: drift not checkable — gcloud is not on this machine"])
        #expect(await drift.check(stack: StackSpec(name: "s", backend: .appPlatform)).isEmpty)
    }
}

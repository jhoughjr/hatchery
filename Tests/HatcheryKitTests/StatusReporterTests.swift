import XCTest
@testable import HatcheryKit

/// File scope, so a `@Sendable` transport closure never captures the test case.
private func json(_ body: String) -> ProbeResult {
    .response(status: 200, body: Data(body.utf8), contentType: "application/json; charset=utf-8")
}

private func service(_ name: String, domains: [String] = ["svc.example.com"]) -> ServiceSpec {
    ServiceSpec(name: name, kind: .mwserver, image: "img", domains: domains, configFile: "c.json")
}

private func reporter(_ result: @escaping @Sendable (URL) -> ProbeResult) -> StatusReporter {
    StatusReporter(transport: { probe, _ in result(probe.url) })
}

final class StatusReporterTests: XCTestCase {

    // MARK: - Interpreting an answer

    func testReadyReportReadsAsReady() async {
        let reporter = reporter { _ in
            json(#"{"status":"ready","gitRev":"abc1234","reasons":[]}"#)
        }
        let health = await reporter.status(of: service("mwlab"))

        XCTAssertEqual(health.state, .ready)
        XCTAssertEqual(health.gitRev, "abc1234")
        XCTAssertTrue(health.reasons.isEmpty)
    }

    func testDegradedReportCarriesItsReasons() async {
        let reporter = reporter { _ in
            json(#"{"status":"degraded","gitRev":null,"reasons":["4 migrations pending"]}"#)
        }
        let health = await reporter.status(of: service("mwlab"))

        XCTAssertEqual(health.state, .degraded)
        XCTAssertEqual(health.reasons, ["4 migrations pending"])
    }

    /// A ready status that still carries a reason is a contradiction, and the reason wins.
    func testReasonsOutrankAReadyStatus() async {
        let reporter = reporter { _ in
            json(#"{"status":"ready","reasons":["1 migration pending"]}"#)
        }
        let health = await reporter.status(of: service("mwlab"))

        XCTAssertEqual(health.state, .degraded)
    }

    /// An older image has no health route. A routed 404 still proves the process is up.
    func testMissingHealthRouteReadsAsResponding() async {
        let reporter = reporter { _ in
            .response(status: 404, body: Data(), contentType: "application/json")
        }
        let health = await reporter.status(of: service("mwlab"))

        XCTAssertEqual(health.state, .responding)
        XCTAssertEqual(health.reasons, ["no health endpoint"])
    }

    func testServerErrorReadsAsDegraded() async {
        let reporter = reporter { _ in
            .response(status: 502, body: Data(), contentType: "text/plain")
        }
        let health = await reporter.status(of: service("mwlab"))

        XCTAssertEqual(health.state, .degraded)
        XCTAssertEqual(health.reasons, ["HTTP 502"])
    }

    /// Some services in this estate answer every unmatched path with 200 and an HTML page.
    /// Parsing that as a report would invent a status.
    func testHTMLBodyIsNotParsedAsAReport() async {
        let reporter = reporter { _ in
            .response(status: 200, body: Data("<html>dashboard</html>".utf8), contentType: "text/html")
        }
        let health = await reporter.status(of: service("mwlab"))

        XCTAssertEqual(health.state, .responding)
    }

    func testTransportFailureReadsAsUnreachable() async {
        let reporter = reporter { _ in .failure("cannot connect") }
        let health = await reporter.status(of: service("mwlab"))

        XCTAssertEqual(health.state, .unreachable)
        XCTAssertEqual(health.reasons, ["cannot connect"])
    }

    func testServiceWithNoDomainIsUnreachable() async {
        let reporter = reporter { _ in json(#"{"status":"ready"}"#) }
        let health = await reporter.status(of: service("mwlab", domains: []))

        XCTAssertEqual(health.state, .unreachable)
        XCTAssertEqual(health.reasons, ["no address declared"])
    }

    // MARK: - Addressing

    func testLANHostsStayOnHTTPAndPublicHostsGetTLS() {
        XCTAssertEqual(ServiceSpec.scheme(forHost: "mwlab.opi"), "http")
        XCTAssertEqual(ServiceSpec.scheme(forHost: "opi"), "http")
        XCTAssertEqual(ServiceSpec.scheme(forHost: "box.local"), "http")
        XCTAssertEqual(ServiceSpec.scheme(forHost: "mwlab.jimmyhoughjr.net"), "https")
    }

    func testHealthURLUsesTheFirstDomainAndDefaultPath() {
        let spec = service("mwlab", domains: ["mwlab.opi", "mwlab.jimmyhoughjr.net"])
        XCTAssertEqual(spec.healthURL()?.absoluteString, "http://mwlab.opi/health")
    }

    func testExplicitBaseURLOverridesDomains() {
        var spec = service("mwlab", domains: ["mwlab.opi"])
        spec.baseURL = "http://127.0.0.1:8080"
        XCTAssertEqual(spec.healthURL()?.absoluteString, "http://127.0.0.1:8080/health")
    }

    func testHealthPathIsOverridable() {
        var spec = service("mwlab")
        spec.healthPath = "/healthz"
        XCTAssertEqual(spec.healthURL()?.absoluteString, "https://svc.example.com/healthz")
    }

    // MARK: - Composing a stack

    func testStackTakesTheWorstStateAndKeepsServiceOrder() async {
        // A dokku stack sends every probe to the box, so the vhost is what tells them apart.
        let reporter = StatusReporter(transport: { probe, _ in
            probe.hostHeader == "paylab.opi"
                ? .failure("cannot connect")
                : .response(
                    status: 200,
                    body: Data(#"{"status":"ready"}"#.utf8),
                    contentType: "application/json")
        })

        let stack = StackSpec(
            name: "mwlab",
            backend: .dokku,
            host: "dokku@192.168.0.103",
            services: [
                service("mwlab", domains: ["mwlab.opi"]),
                service("paylab", domains: ["paylab.opi"]),
                service("comlab", domains: ["comlab.opi"]),
            ]
        )

        let report = await reporter.status(of: stack)

        XCTAssertEqual(report.services.map(\.service), ["mwlab", "paylab", "comlab"])
        XCTAssertEqual(report.state, .unreachable)
    }

    func testAStackOfReadyServicesIsReady() async {
        let reporter = reporter { _ in json(#"{"status":"ready"}"#) }
        let stack = StackSpec(
            name: "mwlab", backend: .dokku, host: "h",
            services: [service("a", domains: ["a.opi"]), service("b", domains: ["b.opi"])]
        )

        let report = await reporter.status(of: stack)
        XCTAssertEqual(report.state, .ready)
    }

    /// An empty answer is not a healthy one.
    func testAStackWithNoServicesIsUnreachable() {
        XCTAssertEqual(StackStatus(stack: "empty", services: []).state, .unreachable)
    }

    func testStateOrderingRunsWorstToBest() {
        XCTAssertTrue(HealthState.unreachable < HealthState.degraded)
        XCTAssertTrue(HealthState.degraded < HealthState.responding)
        XCTAssertTrue(HealthState.responding < HealthState.ready)
    }
}

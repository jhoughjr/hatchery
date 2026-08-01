import XCTest
@testable import HatcheryKit

/// A dokku box routes on the `Host` header, and a lab vhost usually has no public DNS record.
/// Reaching the box directly is therefore the only address that works on a LAN fleet.
final class HealthRequestTests: XCTestCase {
    private func labStack(host: String? = "dokku@192.168.0.103") -> StackSpec {
        StackSpec(
            name: "mwlab",
            backend: .dokku,
            host: host,
            services: [
                ServiceSpec(
                    name: "paylab",
                    kind: .paymentGateway,
                    image: "img",
                    domains: ["paylab.opi", "paylab.example.net"],
                    configFile: "paylab.config.json"
                )
            ]
        )
    }

    func testSSHUserIsStrippedFromTheHostAddress() {
        XCTAssertEqual(labStack().hostAddress, "192.168.0.103")
        XCTAssertEqual(StackSpec(name: "s", backend: .dokku, host: "10.0.0.5").hostAddress, "10.0.0.5")
        XCTAssertNil(StackSpec(name: "s", backend: .appPlatform).hostAddress)
    }

    func testDokkuServiceIsProbedAtTheBoxWithItsVhost() throws {
        let stack = labStack()
        let probe = try XCTUnwrap(stack.services[0].healthRequest(in: stack))

        XCTAssertEqual(probe.url.absoluteString, "http://192.168.0.103/health")
        XCTAssertEqual(probe.hostHeader, "paylab.opi")
    }

    /// Without a stack there is no box to aim at, so the published name is all there is.
    func testWithoutAStackTheRequestUsesThePublishedName() throws {
        let probe = try XCTUnwrap(labStack().services[0].healthRequest())

        XCTAssertEqual(probe.url.absoluteString, "http://paylab.opi/health")
        XCTAssertNil(probe.hostHeader)
    }

    func testAppPlatformServiceUsesItsPublicName() throws {
        let stack = StackSpec(
            name: "tenant-one",
            backend: .appPlatform,
            services: [
                ServiceSpec(
                    name: "mwserver",
                    kind: .mwserver,
                    image: "img",
                    domains: ["tenant.example.com"],
                    configFile: "c.json"
                )
            ]
        )
        let probe = try XCTUnwrap(stack.services[0].healthRequest(in: stack))

        XCTAssertEqual(probe.url.absoluteString, "https://tenant.example.com/api/health")
        XCTAssertNil(probe.hostHeader)
    }

    /// A dokku stack that names no box falls back rather than probing nothing.
    func testDokkuStackWithoutAHostFallsBackToTheName() throws {
        let stack = labStack(host: nil)
        let probe = try XCTUnwrap(stack.services[0].healthRequest(in: stack))

        XCTAssertEqual(probe.url.absoluteString, "http://paylab.opi/health")
    }

    /// Verified against the lab: `/api/metrics` is 200 on mwserver and 404 on both gateways,
    /// and `/health` is the reverse. One path for every kind would probe the wrong route.
    func testHealthPathFollowsTheServiceKind() {
        XCTAssertEqual(ServiceKind.mwserver.defaultHealthPath, "/api/health")
        XCTAssertEqual(ServiceKind.paymentGateway.defaultHealthPath, "/health")
        XCTAssertEqual(ServiceKind.communicationGateway.defaultHealthPath, "/health")
    }

    func testExplicitPathBeatsTheKindDefault() throws {
        var stack = labStack()
        stack.services[0].healthPath = "/custom"
        let probe = try XCTUnwrap(stack.services[0].healthRequest(in: stack))

        XCTAssertEqual(probe.url.absoluteString, "http://192.168.0.103/custom")
    }

    func testExplicitBaseURLBeatsBoxRouting() throws {
        var stack = labStack()
        stack.services[0].baseURL = "http://127.0.0.1:8080"
        let probe = try XCTUnwrap(stack.services[0].healthRequest(in: stack))

        XCTAssertEqual(probe.url.absoluteString, "http://127.0.0.1:8080/health")
        XCTAssertNil(probe.hostHeader)
    }
}

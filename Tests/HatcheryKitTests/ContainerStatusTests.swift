import Foundation
import Testing

@testable import HatcheryKit

/// The recorded answer, with `State` replaced by the state under test.
///
/// One recording covers all four grades: the state block is the only part of the document a grade reads, and
/// rewriting it is how a running container's bytes stand in for a stopped one without stopping anything.
private func recordedWithState(_ state: String) throws -> String {
    let data = try recordedInspection("rookery-pg.inspect.json")
    var objects = try #require(
        JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    objects[0]["State"] = try #require(
        JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])
    let rewritten = try JSONSerialization.data(withJSONObject: objects)
    return String(decoding: rewritten, as: UTF8.self)
}

private func containerService(healthPath: String? = nil) -> ServiceSpec {
    ServiceSpec(
        name: "rookery-pg", kind: .container, image: "postgres:17-alpine",
        configFile: "rookery-pg.config.json", healthPath: healthPath,
        container: ContainerSpec(
            image: "postgres:17-alpine",
            network: "rookery_default",
            ports: [ContainerSpec.PortMap(host: 5433, container: 5432)],
            restart: "unless-stopped"))
}

/// Carries the probed address out of the transport closure, which is `@Sendable`.
private final class AskedURL: @unchecked Sendable {
    var url: URL?
}

private func hostStack(services: [ServiceSpec]) -> StackSpec {
    StackSpec(
        name: "box", backend: .host, environment: .prod, host: "jimmy@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/box"), services: services)
}

@Suite("Grading a container the box runs")
struct ContainerStatusTests {
    @Test("a box that does not answer reads as unreachable, and so does a name it does not hold")
    func unreachable() async throws {
        let silent = StatusReporter(execute: { _, _ in
            CommandOutput(status: 255, standardOutput: "", standardError: "ssh: connect to host port 22: No route to host")
        })
        let service = containerService()
        let health = await silent.status(of: service, in: hostStack(services: [service]))
        #expect(health.state == .unreachable)
        #expect(health.reasons == ["the box did not answer docker inspect"])

        let absent = StatusReporter(execute: { _, _ in
            CommandOutput(
                status: 1, standardOutput: "[]\n",
                standardError: "Error response from daemon: No such object: rookery-pg")
        })
        let missing = await absent.status(of: service, in: hostStack(services: [service]))
        #expect(missing.state == .unreachable)
        #expect(missing.reasons == ["no container named 'rookery-pg' on the box"])
    }

    @Test("a container that exists and is not running is degraded, and so is one docker calls unhealthy")
    func degraded() async throws {
        let stopped = try recordedWithState("""
            {"Status": "exited", "Running": false, "ExitCode": 1}
            """)
        let service = containerService()
        let reporter = StatusReporter(execute: { _, _ in
            CommandOutput(status: 0, standardOutput: stopped)
        })
        let health = await reporter.status(of: service, in: hostStack(services: [service]))
        #expect(health.state == .degraded)
        #expect(health.reasons == ["the container is exited"])

        let unhealthy = try recordedWithState("""
            {"Status": "running", "Running": true, "Health": {"Status": "unhealthy", "FailingStreak": 4}}
            """)
        let second = StatusReporter(execute: { _, _ in
            CommandOutput(status: 0, standardOutput: unhealthy)
        })
        let sick = await second.status(of: service, in: hostStack(services: [service]))
        #expect(sick.state == .degraded)
        #expect(sick.reasons == ["docker reports it unhealthy"])
    }

    @Test("a running container with nothing to say about itself is responding, not ready")
    func responding() async throws {
        let running = try recordedWithState("""
            {"Status": "running", "Running": true}
            """)
        let service = containerService()
        let reporter = StatusReporter(execute: { _, _ in
            CommandOutput(status: 0, standardOutput: running)
        })
        let health = await reporter.status(of: service, in: hostStack(services: [service]))
        #expect(health.state == .responding)
        #expect(health.reasons == ["running, and it reports no readiness of its own"])
    }

    @Test("a running container docker calls healthy is ready")
    func readyFromItsOwnHealth() async throws {
        let healthy = try recordedWithState("""
            {"Status": "running", "Running": true, "Health": {"Status": "healthy", "FailingStreak": 0}}
            """)
        let service = containerService()
        let reporter = StatusReporter(execute: { _, _ in
            CommandOutput(status: 0, standardOutput: healthy)
        })
        let health = await reporter.status(of: service, in: hostStack(services: [service]))
        #expect(health.state == .ready)
        #expect(health.reasons.isEmpty)
    }

    @Test("a health path that answers makes a running container ready, and one that does not leaves it responding")
    func readyFromItsHealthPath() async throws {
        let running = try recordedWithState("""
            {"Status": "running", "Running": true}
            """)
        let service = containerService(healthPath: "/health")

        let asked = AskedURL()
        let answering = StatusReporter(
            transport: { request, _ in
                asked.url = request.url
                return .response(status: 200, body: Data(), contentType: "text/plain")
            },
            execute: { _, _ in CommandOutput(status: 0, standardOutput: running) })
        let ready = await answering.status(of: service, in: hostStack(services: [service]))
        #expect(ready.state == .ready)
        // A container on its own network is reachable only where it publishes a port.
        #expect(asked.url?.absoluteString == "http://192.168.0.103:5433/health")

        let quiet = StatusReporter(
            transport: { _, _ in .failure("cannot connect") },
            execute: { _, _ in CommandOutput(status: 0, standardOutput: running) })
        let health = await quiet.status(of: service, in: hostStack(services: [service]))
        #expect(health.state == .responding)
        #expect(health.reasons == ["running, and /health did not answer (cannot connect)"])
    }

    @Test("a health path on a host-network container is asked at the box's own address")
    func hostNetworkProbesTheBox() {
        let onHost = ContainerSpec(image: "4km3/dnsmasq:latest", network: "host")
        let request = StatusReporter.containerProbe(
            path: "/health", container: onHost, box: "jimmy@192.168.0.103")
        #expect(request?.url.absoluteString == "http://192.168.0.103/health")

        // A container that publishes nothing and holds none of the box's ports has no address to ask.
        let closed = ContainerSpec(image: "x", network: "rookery_default")
        #expect(
            StatusReporter.containerProbe(path: "/health", container: closed, box: "jimmy@h") == nil)
    }
}

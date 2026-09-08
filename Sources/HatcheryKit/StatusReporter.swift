import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One answer from a probe.
public enum ProbeResult: Sendable {
    case response(status: Int, body: Data, contentType: String?)
    /// A stable one-line reason, which a caller diffs between polls.
    case failure(String)
}

/// Where to send one probe.
///
/// `hostHeader` carries the vhost when the address is an IP. A dokku box routes by the `Host`
/// header, and a lab app usually has no public DNS record, so an IP alone reaches the proxy
/// but not the app.
public struct HealthRequest: Sendable, Equatable {
    public let url: URL
    public let hostHeader: String?

    public init(url: URL, hostHeader: String? = nil) {
        self.url = url
        self.hostHeader = hostHeader
    }
}

/// How a probe reaches a service. The tests replace it, so no test opens a socket.
public typealias HealthTransport = @Sendable (HealthRequest, Duration) async -> ProbeResult

public enum URLSessionTransport {
    public static let live: HealthTransport = { probe, timeout in
        var request = URLRequest(url: probe.url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.seconds(timeout)
        // A readiness answer that a cache served describes a state that already passed.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let hostHeader = probe.hostHeader {
            request.setValue(hostHeader, forHTTPHeaderField: "Host")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("no HTTP response")
            }
            return .response(
                status: http.statusCode,
                body: data,
                contentType: http.value(forHTTPHeaderField: "Content-Type")
            )
        } catch {
            return .failure(Self.reason(for: error))
        }
    }

    /// Map the transport error onto a short stable line.
    ///
    /// The underlying description carries the host and sometimes the whole URL, and this
    /// output is meant to be pasted into a ticket.
    static func reason(for error: any Error) -> String {
        guard let urlError = error as? URLError else { return "request failed" }
        switch urlError.code {
        case .timedOut: return "timed out"
        case .cannotFindHost, .dnsLookupFailed: return "host not found"
        case .cannotConnectToHost: return "cannot connect"
        case .networkConnectionLost, .notConnectedToInternet: return "no route"
        case .serverCertificateUntrusted, .secureConnectionFailed: return "TLS failed"
        default: return "request failed"
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}

/// Reads the live state of the services a manifest declares.
///
/// This composes what each service says about itself. It deliberately does not ask a
/// container runtime whether a process is running, because a running container that answers
/// every request with an error still reads as running.
public struct StatusReporter: Sendable {
    private let transport: HealthTransport
    private let timeout: Duration
    private let execute: CommandExecutor

    public init(
        transport: @escaping HealthTransport = URLSessionTransport.live,
        timeout: Duration = .seconds(5),
        execute: @escaping CommandExecutor = ShellRunner.liveExecutor
    ) {
        self.transport = transport
        self.timeout = timeout
        self.execute = execute
    }

    public func status(of stack: StackSpec) async -> StackStatus {
        // The services are probed together, so one slow service does not set the wall clock
        // for the whole stack. The results are re-sorted, because a group yields out of order.
        let health = await withTaskGroup(of: (Int, ServiceHealth).self) { group in
            for (index, service) in stack.services.enumerated() {
                group.addTask { (index, await self.status(of: service, in: stack)) }
            }
            var collected: [(Int, ServiceHealth)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return StackStatus(stack: stack.name, services: health)
    }

    public func status(of service: ServiceSpec, in stack: StackSpec? = nil) async -> ServiceHealth {
        if let stack, stack.backend == .host, let container = service.container {
            return await self.containerStatus(of: service, container: container, in: stack)
        }
        guard let probe = service.healthRequest(in: stack) else {
            return HealthInterpreter.unreachable(service: service.name, reason: "no address declared")
        }

        let start = ContinuousClock.now
        let result = await self.transport(probe, self.timeout)
        let elapsed = ContinuousClock.now - start
        let latencyMs = Int(elapsed.components.seconds * 1_000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)

        switch result {
        case .failure(let reason):
            return HealthInterpreter.unreachable(service: service.name, reason: reason)
        case .response(let status, let body, let contentType):
            return HealthInterpreter.interpret(
                service: service.name,
                status: status,
                body: body,
                contentType: contentType,
                latencyMs: latencyMs
            )
        }
    }

    /// Grades a container from what the box says about it, and then from its health path when it has one.
    ///
    /// A container has no vhost to ask, so the daemon is the only witness that it exists at all. Docker's own
    /// health is read where the container declares a HEALTHCHECK, because a process that is up and failing
    /// its own check is degraded rather than responding.
    private func containerStatus(
        of service: ServiceSpec, container: ContainerSpec, in stack: StackSpec
    ) async -> ServiceHealth {
        guard let box = stack.host, !box.isEmpty else {
            return HealthInterpreter.unreachable(
                service: service.name, reason: "the stack declares no box")
        }
        let output: CommandOutput
        do {
            output = try await self.execute(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", box,
                 "docker inspect \(service.name)"], nil)
        } catch {
            return HealthInterpreter.unreachable(service: service.name, reason: "cannot reach \(box)")
        }
        guard output.status == 0 else {
            // The daemon answers about a name it does not hold, and ssh answers about a box that is not
            // there, with the same nonzero status. The message is what separates them.
            let missing = output.combined.lowercased().contains("no such object")
            return HealthInterpreter.unreachable(
                service: service.name,
                reason: missing
                    ? "no container named '\(service.name)' on the box"
                    : "the box did not answer docker inspect")
        }
        guard let read = try? ContainerInspection.decode(Data(output.standardOutput.utf8)) else {
            return HealthInterpreter.unreachable(
                service: service.name, reason: "docker inspect answered with nothing readable")
        }

        guard read.running else {
            return ServiceHealth(
                service: service.name, state: .degraded, reasons: ["the container is \(read.state)"])
        }
        if let health = read.health, health != "healthy" {
            return ServiceHealth(
                service: service.name, state: .degraded, reasons: ["docker reports it \(health)"])
        }

        if let path = service.healthPath, !path.isEmpty,
            let request = Self.containerProbe(path: path, container: container, box: box)
        {
            let result = await self.transport(request, self.timeout)
            switch result {
            case .response(let status, _, _) where (200..<400).contains(status):
                return ServiceHealth(service: service.name, state: .ready, reasons: [])
            case .response(let status, _, _):
                return ServiceHealth(
                    service: service.name, state: .responding, reasons: ["HTTP \(status) at \(path)"])
            case .failure(let reason):
                return ServiceHealth(
                    service: service.name, state: .responding,
                    reasons: ["running, and \(path) did not answer (\(reason))"])
            }
        }

        guard read.health == "healthy" else {
            return ServiceHealth(
                service: service.name, state: .responding,
                reasons: ["running, and it reports no readiness of its own"])
        }
        return ServiceHealth(service: service.name, state: .ready, reasons: [])
    }

    /// Where to reach a container's health path.
    ///
    /// A container on the host network answers at the box's own address, because it holds the box's ports.
    /// Any other container is reachable only where it publishes a port, so a container that publishes none
    /// has no address a probe can use.
    static func containerProbe(path: String, container: ContainerSpec, box: String) -> HealthRequest? {
        let address = box.split(separator: "@").last.map(String.init) ?? box
        if container.network == "host" {
            return URL(string: "http://\(address)\(path)").map { HealthRequest(url: $0) }
        }
        guard let port = container.ports.first else { return nil }
        return URL(string: "http://\(address):\(port.host)\(path)").map { HealthRequest(url: $0) }
    }

    public func status(of manifest: StackManifest) async -> [StackStatus] {
        var reports: [StackStatus] = []
        for stack in manifest.stacks {
            reports.append(await self.status(of: stack))
        }
        return reports
    }
}

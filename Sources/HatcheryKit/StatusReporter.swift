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

    public init(
        transport: @escaping HealthTransport = URLSessionTransport.live,
        timeout: Duration = .seconds(5)
    ) {
        self.transport = transport
        self.timeout = timeout
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

    public func status(of manifest: StackManifest) async -> [StackStatus] {
        var reports: [StackStatus] = []
        for stack in manifest.stacks {
            reports.append(await self.status(of: stack))
        }
        return reports
    }
}

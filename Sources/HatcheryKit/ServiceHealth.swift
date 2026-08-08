import Foundation

/// What a probe learned about one service.
///
/// The states are ordered worst to best, because a stack reports the worst state among
/// its services. `responding` sits between the failures and `ready` on purpose: it means
/// the service answered but told us nothing, which is better than silence and worse than
/// a report we can read.
public enum HealthState: String, Sendable, Codable, CaseIterable, Comparable {
    /// Nothing answered.
    case unreachable
    /// The service reported a problem.
    case degraded
    /// The service answered without a readiness report. An older image has no health route,
    /// and a routed error still proves the process is up and the router matched.
    case responding
    /// The service reported that it is ready.
    case ready

    private var rank: Int {
        switch self {
        case .unreachable: return 0
        case .degraded: return 1
        case .responding: return 2
        case .ready: return 3
        }
    }

    public static func < (lhs: HealthState, rhs: HealthState) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct ServiceHealth: Sendable, Equatable {
    public let service: String
    public let state: HealthState
    /// Stable one-line failures, which a caller diffs between polls.
    public let reasons: [String]
    public let gitRev: String?
    public let latencyMs: Int?

    public init(
        service: String,
        state: HealthState,
        reasons: [String] = [],
        gitRev: String? = nil,
        latencyMs: Int? = nil
    ) {
        self.service = service
        self.state = state
        self.reasons = reasons
        self.gitRev = gitRev
        self.latencyMs = latencyMs
    }
}

/// One stack, and the services under it.
public struct StackStatus: Sendable, Equatable {
    public let stack: String
    public let services: [ServiceHealth]

    public init(stack: String, services: [ServiceHealth]) {
        self.stack = stack
        self.services = services
    }

    /// The worst state among the services. A stack with no services reads as `unreachable`,
    /// because an empty answer is not a healthy one.
    public var state: HealthState {
        services.map(\.state).min() ?? .unreachable
    }
}

/// The readiness body a service returns.
///
/// `reasons` is optional so a service that reports only a status still parses. Nothing else
/// about the shape is assumed, because a decoder that demands every field turns a partial
/// answer into no answer.
struct HealthPayload: Decodable {
    let status: String
    let gitRev: String?
    let reasons: [String]?
}

public enum HealthInterpreter {
    /// Read one HTTP answer into a state.
    ///
    /// A body is parsed only when the service called it JSON. Some services in this estate
    /// answer every unmatched path with 200 and an HTML dashboard, so a parse attempt on any
    /// 200 would read a web page as a health report.
    public static func interpret(
        service: String,
        status: Int,
        body: Data,
        contentType: String?,
        latencyMs: Int?
    ) -> ServiceHealth {
        if isJSON(contentType), let payload = try? JSONDecoder().decode(HealthPayload.self, from: body) {
            let reasons = payload.reasons ?? []
            let state: HealthState = payload.status == "ready" && reasons.isEmpty ? .ready : .degraded
            return ServiceHealth(
                service: service,
                state: state,
                reasons: reasons,
                gitRev: payload.gitRev,
                latencyMs: latencyMs
            )
        }

        // No readable report. The status code is all there is.
        switch status {
        case 404:
            // The router answered and matched nothing. That is an image without the health
            // route, not a broken service.
            return ServiceHealth(
                service: service,
                state: .responding,
                reasons: ["no health endpoint"],
                latencyMs: latencyMs
            )
        case 500...599:
            return ServiceHealth(
                service: service,
                state: .degraded,
                reasons: ["HTTP \(status)"],
                latencyMs: latencyMs
            )
        default:
            return ServiceHealth(
                service: service,
                state: .responding,
                reasons: ["HTTP \(status), no readiness report"],
                latencyMs: latencyMs
            )
        }
    }

    public static func unreachable(service: String, reason: String) -> ServiceHealth {
        ServiceHealth(service: service, state: .unreachable, reasons: [reason])
    }

    static func isJSON(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        return contentType.lowercased().contains("json")
    }
}

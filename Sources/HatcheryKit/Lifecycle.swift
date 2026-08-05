import Foundation

public enum LifecycleError: Error, CustomStringConvertible, Equatable {
    case noHost(stack: String)
    case unsupportedBackend(Backend, action: String)

    public var description: String {
        switch self {
        case .noHost(let stack):
            return "stack '\(stack)' targets dokku but declares no host"
        case .unsupportedBackend(let backend, let action):
            return "\(action) is not implemented for \(backend.rawValue)"
        }
    }
}

/// What a lifecycle action did to one service.
public struct LifecycleResult: Sendable, Equatable {
    public let service: String
    public let action: String
    public let succeeded: Bool
    /// A stable one-line reason when the action failed.
    public let reason: String?

    public init(service: String, action: String, succeeded: Bool, reason: String? = nil) {
        self.service = service
        self.action = action
        self.succeeded = succeeded
        self.reason = reason
    }
}

/// Starts, stops, and restarts the services a stack declares.
///
/// These three actions are safe to drive directly, because tofu does not manage the running
/// state of a dokku app. It manages the image, the domains, the ports, the checks, and the
/// config, and a plan stays clean across a stop and a start.
///
/// Changing the image is deliberately absent. That attribute *is* declared, so writing it here
/// would fight `tofu plan` and put two owners on one field. A deploy belongs in the declaration.
public struct LifecycleRunner: Sendable {
    private let run: CommandRunner

    public init(run: @escaping CommandRunner = ShellRunner.live) {
        self.run = run
    }

    public enum Action: String, Sendable, CaseIterable {
        case start = "ps:start"
        case stop = "ps:stop"
        case restart = "ps:restart"

        /// The word a person reads, rather than the dokku verb.
        public var label: String {
            switch self {
            case .start: return "start"
            case .stop: return "stop"
            case .restart: return "restart"
            }
        }
    }

    static func command(host: String, action: Action, app: String) -> [String] {
        ["ssh", "-o", "BatchMode=yes", host, action.rawValue, app]
    }

    static func runningCommand(host: String, app: String) -> [String] {
        ["ssh", "-o", "BatchMode=yes", host, "ps:report", app, "--running"]
    }

    public func perform(
        _ action: Action,
        on service: ServiceSpec,
        in stack: StackSpec
    ) async -> LifecycleResult {
        guard stack.backend == .dokku else {
            return LifecycleResult(
                service: service.name,
                action: action.label,
                succeeded: false,
                reason: LifecycleError.unsupportedBackend(stack.backend, action: action.label).description
            )
        }
        guard let host = stack.host, !host.isEmpty else {
            return LifecycleResult(
                service: service.name,
                action: action.label,
                succeeded: false,
                reason: LifecycleError.noHost(stack: stack.name).description
            )
        }

        do {
            _ = try await self.run(
                Self.command(
                    host: DokkuProvider.sshTarget(host), action: action, app: service.name))
            return LifecycleResult(service: service.name, action: action.label, succeeded: true)
        } catch {
            return LifecycleResult(
                service: service.name,
                action: action.label,
                succeeded: false,
                reason: "\(error)"
            )
        }
    }

    /// Every service in the stack, in declaration order.
    ///
    /// These run one at a time rather than together. A stop or a start on a shared box competes
    /// for the same docker daemon, and the order a person declared is the order they expect.
    public func perform(_ action: Action, on stack: StackSpec) async -> [LifecycleResult] {
        var results: [LifecycleResult] = []
        for service in stack.services {
            results.append(await self.perform(action, on: service, in: stack))
        }
        return results
    }

    /// Whether dokku reports the app as running.
    public func isRunning(_ service: ServiceSpec, in stack: StackSpec) async throws -> Bool {
        guard stack.backend == .dokku else {
            throw LifecycleError.unsupportedBackend(stack.backend, action: "running check")
        }
        guard let host = stack.host, !host.isEmpty else {
            throw LifecycleError.noHost(stack: stack.name)
        }
        let data = try await self.run(
            Self.runningCommand(host: DokkuProvider.sshTarget(host), app: service.name))
        let answer = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return answer == "true"
    }
}

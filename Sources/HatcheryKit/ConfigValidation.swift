import Foundation

public enum Severity: String, Sendable, Codable {
    case error
    case warning
}

public struct ValidationIssue: Sendable, Equatable, Codable {
    public let severity: Severity
    public let key: String
    public let message: String

    public init(severity: Severity, key: String, message: String) {
        self.severity = severity
        self.key = key
        self.message = message
    }
}

public enum ConfigValidator {
    /// Check a resolved config map against a contract.
    ///
    /// Issues are returned sorted (errors first, then by key) so output is stable
    /// and diffable across runs.
    public static func validate(_ config: [String: String], against contract: EnvContract) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        for key in contract.required where !contract.isIgnored(key) {
            guard let value = config[key] else {
                issues.append(ValidationIssue(
                    severity: .error,
                    key: key,
                    message: "required key is missing; the service will not boot without it"
                ))
                continue
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(ValidationIssue(
                    severity: .error,
                    key: key,
                    message: "required key is present but empty"
                ))
            }
        }

        for key in config.keys where contract.retired.contains(key) {
            issues.append(ValidationIssue(
                severity: .error,
                key: key,
                message: "retired key; connection strings are the only supported wire format — "
                    + "use DATABASE_URL / DATABASE_OWNER_URL / DATABASE_APP_URL"
            ))
        }

        // Dokku config:set merges rather than replaces, so undeclared keys accumulate
        // silently and never appear in a plan. Surfacing them is the whole point.
        for key in config.keys where !contract.isDeclared(key) && !contract.isIgnored(key) {
            issues.append(ValidationIssue(
                severity: .warning,
                key: key,
                message: "key is set but not declared in the contract; it will never be removed by an apply"
            ))
        }

        return issues.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity == .error }
            return lhs.key < rhs.key
        }
    }

    /// True when nothing would stop the service booting.
    public static func passes(_ issues: [ValidationIssue]) -> Bool {
        !issues.contains { $0.severity == .error }
    }

    /// Redact a config map for display. Secret values become a fingerprint, never
    /// the value, so validation output is safe to paste into a ticket.
    public static func redact(_ config: [String: String], contract: EnvContract) -> [String: String] {
        config.mapValues { $0 }.reduce(into: [:]) { result, pair in
            if contract.secret.contains(pair.key) {
                result[pair.key] = "<redacted \(pair.value.count) chars>"
            } else {
                result[pair.key] = pair.value
            }
        }
    }
}

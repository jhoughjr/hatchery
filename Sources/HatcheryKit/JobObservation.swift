import Foundation

/// What a supervisor says about one job it holds.
///
/// launchd and systemd answer the same three questions in two shapes, and this is the shape the grade reads.
/// A job that has never run answers `nil` for its last exit rather than zero, because a job that never ran and a
/// job that ran and succeeded are not the same state.
public struct JobObservation: Sendable, Equatable {
    public var label: String
    /// Whether the supervisor is holding a process for this job right now.
    public var running: Bool
    /// The status the last run exited with, or `nil` when the job has not exited yet.
    public var lastExit: Int?
    /// When the last run exited. launchd does not keep one, so this is `nil` on a Mac.
    public var lastRun: Date?

    public init(label: String, running: Bool, lastExit: Int? = nil, lastRun: Date? = nil) {
        self.label = label
        self.running = running
        self.lastExit = lastExit
        self.lastRun = lastRun
    }
}

extension JobObservation {
    /// The command that asks one supervisor about one job, as a remote shell line.
    ///
    /// `id -u` is left for the box to answer. launchd addresses a job by the account's own GUI domain, and the
    /// account that runs the job is the account ssh lands in.
    public static func query(label: String, platform: HostPlatform) -> String {
        switch platform {
        case .darwin:
            return "launchctl print gui/$(id -u)/\(label)"
        case .linux:
            return "systemctl --user show \(label).service -p LoadState -p ExecMainStatus "
                + "-p ExecMainExitTimestamp -p ActiveState -p Result -p SubState"
        }
    }

    /// The observation an answer describes, or `nil` when the supervisor does not hold the job at all.
    public static func read(
        _ text: String, label: String, platform: HostPlatform
    ) -> JobObservation? {
        switch platform {
        case .darwin: return Self.launchd(text, label: label)
        case .linux: return Self.systemd(text, label: label)
        }
    }

    /// `launchctl print`, whose answer is an indented block of `key = value` lines.
    ///
    /// A label launchd is not holding produces no `state` line at all, which is how a missing job is told from a
    /// loaded one that is idle.
    static func launchd(_ text: String, label: String) -> JobObservation? {
        var running: Bool?
        var lastExit: Int?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("state = ") {
                running = trimmed.dropFirst("state = ".count).hasPrefix("running")
            }
            if trimmed.hasPrefix("last exit code = ") {
                lastExit = Int(trimmed.dropFirst("last exit code = ".count))
            }
        }
        guard let running else { return nil }
        return JobObservation(label: label, running: running, lastExit: lastExit)
    }

    /// `systemctl --user show`, whose answer is one `Key=value` line per property asked for.
    ///
    /// A oneshot between runs reads `inactive`, which is the healthy resting state of a timer's unit and not a
    /// reason to grade it down. `activating` counts as running, because a job in the middle of its run is running.
    static func systemd(_ text: String, label: String) -> JobObservation? {
        var properties: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            properties[String(parts[0])] = String(parts[1])
        }
        // systemd answers about a unit it has never heard of with the same properties and an empty load state,
        // so this is the one line that separates a missing unit from an idle one.
        guard properties["LoadState"] != "not-found", let state = properties["ActiveState"] else {
            return nil
        }
        let running = state == "active" || state == "activating"
        let stamp = properties["ExecMainExitTimestamp"] ?? ""
        let lastRun = Self.timestamp(stamp)
        // An empty exit timestamp on a running unit means it has not exited yet, so the status is about nothing.
        let lastExit = (stamp.isEmpty && running) ? nil : properties["ExecMainStatus"].flatMap(Int.init)
        return JobObservation(label: label, running: running, lastExit: lastExit, lastRun: lastRun)
    }

    /// systemd writes a timestamp as `Wed 2026-09-09 07:20:33 CDT`, and an empty one for a unit that never ran.
    static func timestamp(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm:ss zzz"
        return formatter.date(from: trimmed)
    }
}

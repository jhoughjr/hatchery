import Foundation
import HatcheryKit

/// One job that runs on a target, read from the target rather than from a manifest.
///
/// The fields are the ones a person needs to decide whether to adopt it: what it runs, when, where it writes, and
/// whether the last run worked. Everything else is in the file, and adopt is what reads that.
public struct FoundJob: Sendable, Equatable {
    public let label: String
    /// The schedule as the file states it, and `nil` for a job the supervisor keeps alive.
    public let schedule: String?
    /// The command, joined for the listing.
    public let program: String
    public let log: String?
    /// The status the last run exited with, or `nil` when the supervisor has no answer yet.
    public let lastExit: Int?
    public let running: Bool

    public init(
        label: String, schedule: String? = nil, program: String, log: String? = nil,
        lastExit: Int? = nil, running: Bool = false
    ) {
        self.label = label
        self.schedule = schedule
        self.program = program
        self.log = log
        self.lastExit = lastExit
        self.running = running
    }
}

/// Which jobs on a host are the estate's to declare.
public enum JobNames {
    /// The owners whose agents and units live beside the estate's and belong to somebody else.
    ///
    /// Google's updater, Apple's own agents and Ubuntu's cache cleaner all sit in the same directory as a roost
    /// timer. Declaring one would put hatchery in charge of software it did not install.
    static let foreignPrefixes = [
        "com.apple.", "com.google.", "com.microsoft.", "org.mozilla.", "com.adobe.", "com.docker.",
        "dbus", "gpg-agent", "pipewire", "wireplumber", "xdg-", "snap.", "app-", "grub-",
        "launchpadlib-cache-clean", "systemd-",
    ]

    /// Whether hatchery should offer this job as one to declare.
    public static func isDeclarable(_ label: String) -> Bool {
        !Self.foreignPrefixes.contains { label.hasPrefix($0) }
    }
}

// MARK: - Reading the jobs off a host

extension Scanner {
    /// The line before each artifact in the one command that reads them all.
    static let jobMarker = "=== hatchery job "
    /// The line before the crontab entries on Linux.
    static let crontabMarker = "=== hatchery crontab ==="
    /// The line before the supervisor's own listing.
    static let supervisorMarker = "=== hatchery supervisor ==="

    /// One command that reads every job artifact under the account, then asks the supervisor about all of them.
    ///
    /// One round trip rather than one per job. A box with twenty agents on a LAN that flaps is a scan that either
    /// finishes or does not, instead of one that half-finishes.
    public static func jobCommand(platform: HostPlatform) -> String {
        switch platform {
        case .darwin:
            return "for f in \"$HOME\"/Library/LaunchAgents/*.plist; do "
                + "[ -e \"$f\" ] || continue; echo \"\(Self.jobMarker)$f\"; cat \"$f\"; done; "
                + "echo '\(Self.supervisorMarker)'; launchctl list"
        case .linux:
            return "for f in \"$HOME\"/.config/systemd/user/*.service "
                + "\"$HOME\"/.config/systemd/user/*.timer; do "
                + "[ -e \"$f\" ] || continue; echo \"\(Self.jobMarker)$f\"; cat \"$f\"; done; "
                + "echo '=== hatchery crontab ==='; crontab -l 2>/dev/null || true; "
                + "echo '\(Self.supervisorMarker)'; "
                + "systemctl --user list-units --type=service,timer --all --no-legend --no-pager"
        }
    }

    /// Every job the answer describes. Split out so a test can hand it recorded text.
    public static func jobInventory(from text: String, platform: HostPlatform) -> [FoundJob] {
        let parts = text.components(separatedBy: Self.supervisorMarker)
        let beforeSupervisor = parts[0]
        let supervisorText = parts.count > 1 ? parts[1] : ""
        let running = Self.runningLabels(supervisorText, platform: platform)

        var artifacts: [String: String] = [:]
        let crontabParts = beforeSupervisor.components(separatedBy: Self.crontabMarker)
        let beforeCrontab = crontabParts[0]

        for block in beforeCrontab.components(separatedBy: Self.jobMarker).dropFirst() {
            guard let newline = block.firstIndex(of: "\n") else { continue }
            let path = String(block[block.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
            artifacts[(path as NSString).lastPathComponent] = String(block[block.index(after: newline)...])
        }

        var found: [FoundJob] = []
        for (name, contents) in artifacts.sorted(by: { $0.key < $1.key }) {
            guard let read = Self.readJob(name: name, contents: contents, artifacts: artifacts, platform: platform),
                JobNames.isDeclarable(read.label)
            else { continue }
            found.append(
                FoundJob(
                    label: read.label,
                    schedule: read.job.schedule.map(Declaration.words(for:)),
                    program: read.job.program.joined(separator: " "),
                    log: read.job.log,
                    lastExit: running[read.label]?.lastExit,
                    running: running[read.label]?.running ?? false))
        }

        if platform == .linux, crontabParts.count > 1 {
            let crontabText = crontabParts[1]
            for (index, line) in crontabText.split(separator: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                if let parsed = Self.parseCrontabLine(String(line)) {
                    found.append(
                        FoundJob(
                            label: "cron:\(index)",
                            schedule: parsed.schedule,
                            program: parsed.program,
                            log: parsed.log,
                            running: false))
                }
            }
        }

        return found
    }

    /// One artifact as a job, with its timer found beside it on Linux.
    ///
    /// A timer is not a job of its own: it says when its unit runs. Reading it as one would list every scheduled
    /// job twice, once as a unit with no schedule and once as a schedule with no program.
    static func readJob(
        name: String, contents: String, artifacts: [String: String], platform: HostPlatform
    ) -> ReadJob? {
        switch platform {
        case .darwin:
            guard name.hasSuffix(".plist") else { return nil }
            return try? JobReader.agent(Data(contents.utf8))
        case .linux:
            guard name.hasSuffix(".service") else { return nil }
            let unit = String(name.dropLast(".service".count))
            return try? JobReader.unit(
                named: unit, service: contents, timer: artifacts["\(unit).timer"])
        }
    }

    /// What the supervisor's own listing says about each label it holds.
    ///
    /// `launchctl list` prints `PID Status Label`, with a `-` for a job that is not running. `systemctl --user
    /// list-units` prints the unit, its load, active and sub states, and its description.
    static func runningLabels(
        _ text: String, platform: HostPlatform
    ) -> [String: (running: Bool, lastExit: Int?)] {
        var found: [String: (running: Bool, lastExit: Int?)] = [:]
        for line in text.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch platform {
            case .darwin:
                guard columns.count >= 3, columns[0] != "PID" else { continue }
                found[columns[2]] = (running: columns[0] != "-", lastExit: Int(columns[1]))

            case .linux:
                guard columns.count >= 4 else { continue }
                let unit = columns[0].hasPrefix("\u{25CF}") ? columns[1] : columns[0]
                let states = columns[0].hasPrefix("\u{25CF}") ? columns[3] : columns[2]
                guard let dot = unit.lastIndex(of: ".") else { continue }
                found[String(unit[unit.startIndex..<dot])] = (running: states == "active", lastExit: nil)
            }
        }
        return found
    }

    /// Parse a crontab line into schedule and program components.
    ///
    /// Returns a tuple with the schedule (OnCalendar format), program (the command), and optional log path.
    static func parseCrontabLine(_ line: String) -> (schedule: String?, program: String, log: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count >= 6 else { return nil }

        let minute = String(parts[0])
        let hour = String(parts[1])
        let dayOfMonth = String(parts[2])
        let month = String(parts[3])
        let dayOfWeek = String(parts[4])
        let command = String(parts[5])

        let onCalendar = cronToOnCalendar(minute: minute, hour: hour, day: dayOfMonth, month: month, dow: dayOfWeek)
        var log: String?
        if let redirectIndex = command.range(of: ">>") {
            let afterRedirect = String(command[redirectIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            let logParts = afterRedirect.split(separator: " ", maxSplits: 1)
            if !logParts.isEmpty {
                log = String(logParts[0]).replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
            }
        }

        return (schedule: onCalendar, program: command, log: log)
    }

    /// Convert cron expression fields to systemd OnCalendar format.
    static func cronToOnCalendar(minute: String, hour: String, day: String, month: String, dow: String) -> String {
        let minuteStr = normalizeField(minute, max: 59)
        let hourStr = normalizeField(hour, max: 23)
        let dayStr = normalizeField(day, max: 31)
        let monthStr = normalizeField(month, max: 12)
        let dowStr = normalizeFieldDow(dow)

        if dayStr != "*" && dowStr != "*" {
            return "*-\(monthStr)-\(dayStr) \(hourStr):\(minuteStr):00"
        } else if dowStr != "*" {
            return "\(dowStr) \(hourStr):\(minuteStr):00"
        } else {
            return "*-\(monthStr)-\(dayStr) \(hourStr):\(minuteStr):00"
        }
    }

    /// Normalize a cron field to systemd format.
    static func normalizeField(_ field: String, max: Int) -> String {
        if field == "*" { return "*" }
        if field.contains("/") {
            let parts = field.split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                let base = parts[0] == "*" ? "*" : String(parts[0])
                return base + "/" + String(parts[1])
            }
        }
        if field.contains(",") {
            return field
        }
        if field.contains("-") {
            return field
        }
        if let val = Int(field) {
            return String(format: "%02d", val)
        }
        return field
    }

    /// Normalize day of week field.
    static func normalizeFieldDow(_ field: String) -> String {
        if field == "*" || field == "?" { return "*" }
        return field
    }
}

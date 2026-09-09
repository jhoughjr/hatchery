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
                + "echo '\(Self.supervisorMarker)'; "
                + "systemctl --user list-units --type=service,timer --all --no-legend --no-pager"
        }
    }

    /// Every job the answer describes. Split out so a test can hand it recorded text.
    public static func jobInventory(from text: String, platform: HostPlatform) -> [FoundJob] {
        let halves = text.components(separatedBy: Self.supervisorMarker)
        let running = Self.runningLabels(halves.count > 1 ? halves[1] : "", platform: platform)

        var artifacts: [String: String] = [:]
        for block in halves[0].components(separatedBy: Self.jobMarker).dropFirst() {
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
            // launchctl separates its columns with tabs and systemctl with runs of spaces, so both are whitespace.
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
}

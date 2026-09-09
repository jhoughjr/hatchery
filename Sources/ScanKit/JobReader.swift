import Foundation
import HatcheryKit

/// One job read off a host, as the supervisor's own file describes it.
///
/// The environment travels beside the spec rather than inside it, because a job's keys belong in the sidecar and the
/// secrets file like every other service's, and the spec records only how the host runs the program.
public struct ReadJob: Sendable, Equatable {
    /// The supervisor's own name for the job: a launchd label, or a systemd unit without its suffix.
    public let label: String
    /// The name the manifest declares this job under, which is the label with the estate's prefix removed.
    public let name: String
    public let job: JobSpec
    public let environment: [String: String]

    public init(label: String, name: String, job: JobSpec, environment: [String: String]) {
        self.label = label
        self.name = name
        self.job = job
        self.environment = environment
    }
}

/// Turns a launchd plist or a systemd user unit into the spec a manifest declares.
///
/// These are the two shapes phase 4 adopts, and a file that is neither is refused rather than half-read.
/// A half-read job would declare a program with no schedule, and the declaration would then say the box does
/// something it does not do.
public enum JobReader {
    /// The estate's reverse-domain prefix, which a manifest name never carries.
    static let labelPrefix = "net.jimmyhoughjr."

    /// The manifest name for a supervisor's label.
    ///
    /// A label the estate wrote loses its prefix. Anything else keeps its whole name, because a label somebody else
    /// chose is the only handle the box answers to.
    public static func name(forLabel label: String) -> String {
        label.hasPrefix(Self.labelPrefix)
            ? String(label.dropFirst(Self.labelPrefix.count))
            : label
    }

    // MARK: - launchd

    /// The job a launchd agent plist describes.
    ///
    /// The plist is parsed rather than pattern-matched, because launchd accepts several shapes for the same fact:
    /// `KeepAlive` is a boolean or a dictionary of conditions, and a program is `Program` or `ProgramArguments`.
    public static func agent(_ data: Data) throws -> ReadJob {
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        guard let plist = parsed as? [String: Any], let label = plist["Label"] as? String else {
            throw AdoptError.notAJobFile("a launchd agent plist with a Label")
        }
        var program = plist["ProgramArguments"] as? [String] ?? []
        if program.isEmpty, let single = plist["Program"] as? String {
            program = [single]
        }
        guard !program.isEmpty else {
            throw AdoptError.notAJobFile("a launchd agent plist with a program to run")
        }

        // A dictionary of KeepAlive conditions still means the supervisor keeps it alive, so both shapes read true.
        let keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        let log = (plist["StandardOutPath"] as? String) ?? (plist["StandardErrorPath"] as? String)
        let job = JobSpec(
            program: program,
            workingDirectory: plist["WorkingDirectory"] as? String,
            schedule: Self.launchSchedule(plist),
            keepAlive: keepAlive,
            log: log,
            runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
            label: label)
        return ReadJob(
            label: label,
            name: Self.name(forLabel: label),
            job: job,
            environment: plist["EnvironmentVariables"] as? [String: String] ?? [:])
    }

    /// `StartInterval` or `StartCalendarInterval`, which are launchd's two schedules.
    ///
    /// launchd takes an array of calendar dictionaries for a job that runs at several times. Only the first is read,
    /// because the spec holds one schedule and declaring one of several would be a lie about the rest.
    static func launchSchedule(_ plist: [String: Any]) -> Schedule? {
        if let seconds = plist["StartInterval"] as? Int {
            return .interval(seconds: seconds)
        }
        var calendar = plist["StartCalendarInterval"] as? [String: Any]
        if calendar == nil {
            calendar = (plist["StartCalendarInterval"] as? [[String: Any]])?.first
        }
        guard let calendar else { return nil }
        return .calendar(
            minute: calendar["Minute"] as? Int,
            hour: calendar["Hour"] as? Int,
            day: calendar["Day"] as? Int,
            weekday: calendar["Weekday"] as? Int)
    }

    // MARK: - systemd

    /// The job a systemd user unit and its timer describe.
    ///
    /// The timer is a second file, so a scheduled job is read from both. A unit with no timer beside it is a job the
    /// box keeps alive, which is the same answer the manifest gives for a spec with no schedule.
    public static func unit(named name: String, service: String, timer: String? = nil) throws -> ReadJob {
        let directives = Self.directives(service)
        guard let start = directives["ExecStart"], !start.isEmpty else {
            throw AdoptError.notAJobFile("a systemd unit with an ExecStart")
        }
        let schedule = timer.flatMap { Self.timerSchedule(Self.directives($0)) }
        let log = directives["StandardOutput"].flatMap { value -> String? in
            guard value.hasPrefix("append:") else { return nil }
            return String(value.dropFirst("append:".count))
        }
        var environment: [String: String] = [:]
        for line in Self.repeated(service, key: "Environment") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            environment[String(parts[0])] = String(parts[1])
        }

        let job = JobSpec(
            program: Self.words(start),
            workingDirectory: directives["WorkingDirectory"],
            schedule: schedule,
            keepAlive: (directives["Restart"] ?? "no") != "no" && schedule == nil,
            log: log,
            runAtLoad: false,
            label: name)
        return ReadJob(label: name, name: name, job: job, environment: environment)
    }

    /// `OnCalendar` verbatim, or `OnUnitActiveSec` as a count of seconds.
    ///
    /// A calendar expression is kept as it stands: systemd's calendar grammar is richer than the four fields the
    /// spec holds, and rewriting `*:0/10` into fields would change when the job runs.
    static func timerSchedule(_ directives: [String: String]) -> Schedule? {
        if let calendar = directives["OnCalendar"], !calendar.isEmpty {
            return .at(calendar)
        }
        guard let interval = directives["OnUnitActiveSec"] ?? directives["OnBootSec"],
            let seconds = Self.seconds(interval)
        else { return nil }
        return .interval(seconds: seconds)
    }

    /// systemd writes an interval as a bare count of seconds or with a unit, as in `10min` or `1h`.
    static func seconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let bare = Int(trimmed) { return bare }
        let units: [(suffix: String, multiplier: Int)] = [
            ("s", 1), ("sec", 1), ("m", 60), ("min", 60), ("h", 3600), ("hr", 3600), ("d", 86400),
        ]
        for unit in units.sorted(by: { $0.suffix.count > $1.suffix.count })
        where trimmed.hasSuffix(unit.suffix) {
            guard let count = Int(trimmed.dropLast(unit.suffix.count)) else { continue }
            return count * unit.multiplier
        }
        return nil
    }

    /// Every `Key=value` line of a unit, with the comments dropped and the last value winning.
    ///
    /// The section headers are not kept. A user unit names each key once across its sections, and a reader that
    /// tracked sections would only be able to refuse a shape systemd itself accepts.
    static func directives(_ text: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
                !trimmed.hasPrefix("[")
            else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            found[String(parts[0])] = String(parts[1])
        }
        return found
    }

    /// Every value of a key a unit may name more than once, in the order it names them.
    static func repeated(_ text: String, key: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + "=") else { return nil }
            return String(trimmed.dropFirst(key.count + 1))
        }
    }

    /// A command line split on spaces, with a quoted argument kept whole.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

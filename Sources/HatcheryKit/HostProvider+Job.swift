import Foundation

// MARK: - The job scaffolds

extension HostProvider {
    /// The name the supervisor knows this job by.
    ///
    /// A Mac needs a reverse-domain label, and the estate's is `net.jimmyhoughjr`. Linux names a unit after the
    /// service. A job adopted from a host that named it something else carries that name in its spec instead.
    public static func jobLabel(for service: ServiceSpec, platform: HostPlatform) -> String {
        if let label = service.job?.label, !label.isEmpty { return label }
        switch platform {
        case .darwin: return "net.jimmyhoughjr.\(service.name)"
        case .linux: return service.name
        }
    }

    /// Where the box keeps this job's artifacts, relative to the account's own home.
    ///
    /// A scheduled job on Linux is two files: systemd separates what to run from when to run it, and only the timer
    /// is enabled. launchd holds both in the one agent.
    /// ``jobFiles(for:platform:environment:secretKeys:)`` answers in this same order, so the two zip together.
    public static func jobDestinations(for service: ServiceSpec, platform: HostPlatform) -> [String] {
        guard let job = service.job else { return [] }
        switch platform {
        case .darwin:
            return ["Library/LaunchAgents/\(Self.jobLabel(for: service, platform: .darwin)).plist"]
        case .linux:
            let unit = "\(Self.jobLabel(for: service, platform: .linux))"
            var names = [".config/systemd/user/\(unit).service"]
            if job.schedule != nil {
                names.append(".config/systemd/user/\(unit).timer")
            }
            return names
        }
    }

    /// The supervisor's artifact for one job: a launchd agent on a Mac, a systemd user unit and its timer on Linux.
    ///
    /// Tofu writes none of this. The plist or the unit is the declaration's artifact, and the manifest is the declaration.
    /// A key named in `secretKeys` reaches neither file, because a plist value is readable by every account on the
    /// machine and a unit's `Environment=` line is readable by everything that can read the unit. A job collects its
    /// secrets from vault at start instead.
    public static func jobFiles(
        for service: ServiceSpec,
        platform: HostPlatform,
        environment: [String: String] = [:],
        secretKeys: Set<String> = []
    ) throws -> [GeneratedFile] {
        guard let job = service.job else {
            throw ProviderError.missingDetail("a job spec on service '\(service.name)'")
        }
        let declared = environment.filter { !secretKeys.contains($0.key) }.sorted { $0.key < $1.key }
        // The artifact is committed beside the stack under its bare name, and the installer is what knows where on
        // the box it goes. A path relative to the box's home would make no sense in the repository.
        let names = Self.jobDestinations(for: service, platform: platform)
            .map { ($0 as NSString).lastPathComponent }
        switch platform {
        case .darwin:
            let contents = try Self.launchAgent(
                label: Self.jobLabel(for: service, platform: .darwin), job: job, environment: declared)
            return [GeneratedFile(path: names[0], contents: contents, role: .declaration)]

        case .linux:
            let unit = Self.jobLabel(for: service, platform: .linux)
            var files = [
                GeneratedFile(
                    path: names[0],
                    contents: Self.systemdService(
                        name: unit, service: service.name, job: job, environment: declared),
                    role: .declaration)
            ]
            if let schedule = job.schedule {
                files.append(
                    GeneratedFile(
                        path: names[1],
                        contents: Self.systemdTimer(name: unit, schedule: schedule),
                        role: .declaration))
            }
            return files
        }
    }

    // MARK: - launchd

    /// The agent plist, as launchd reads it.
    ///
    /// The keys are written in one fixed order so the same job scaffolds to the same bytes every run, and a diff
    /// against the box shows a change to the job rather than a reordering.
    static func launchAgent(
        label: String, job: JobSpec, environment: [(key: String, value: String)]
    ) throws -> String {
        var body = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(Self.xmlEscaped(label))</string>
                <key>ProgramArguments</key>
                <array>

            """
        for argument in job.program {
            body += "        <string>\(Self.xmlEscaped(argument))</string>\n"
        }
        body += "    </array>\n"

        if let directory = job.workingDirectory, !directory.isEmpty {
            body += "    <key>WorkingDirectory</key>\n"
            body += "    <string>\(Self.xmlEscaped(directory))</string>\n"
        }
        if !environment.isEmpty {
            body += "    <key>EnvironmentVariables</key>\n    <dict>\n"
            for pair in environment {
                body += "        <key>\(Self.xmlEscaped(pair.key))</key>\n"
                body += "        <string>\(Self.xmlEscaped(pair.value))</string>\n"
            }
            body += "    </dict>\n"
        }
        if job.runAtLoad {
            body += "    <key>RunAtLoad</key>\n    <true/>\n"
        }
        body += try Self.launchSchedule(job: job)
        if let log = job.log, !log.isEmpty {
            body += "    <key>StandardOutPath</key>\n    <string>\(Self.xmlEscaped(log))</string>\n"
            body += "    <key>StandardErrorPath</key>\n    <string>\(Self.xmlEscaped(log))</string>\n"
        }
        body += """
            </dict>
            </plist>

            """
        return body
    }

    /// `StartInterval`, `StartCalendarInterval` or `KeepAlive`, which are launchd's three answers to when.
    static func launchSchedule(job: JobSpec) throws -> String {
        guard let schedule = job.schedule else {
            return job.keepAlive ? "    <key>KeepAlive</key>\n    <true/>\n" : ""
        }
        switch schedule {
        case .interval(let seconds):
            return "    <key>StartInterval</key>\n    <integer>\(seconds)</integer>\n"

        case .calendar(let minute, let hour, let day, let weekday):
            var body = "    <key>StartCalendarInterval</key>\n    <dict>\n"
            let fields = [("Minute", minute), ("Hour", hour), ("Day", day), ("Weekday", weekday)]
            for (name, value) in fields {
                guard let value else { continue }
                body += "        <key>\(name)</key>\n        <integer>\(value)</integer>\n"
            }
            body += "    </dict>\n"
            return body

        case .at(let expression):
            // A launchd calendar is a dictionary of fields, so there is no string for it to keep verbatim.
            // The job declares a systemd expression and the box is a Mac, and only a person can resolve that.
            throw ProviderError.missingDetail(
                "a calendar launchd can read; '\(expression)' is a systemd OnCalendar expression")
        }
    }

    // MARK: - systemd

    /// The user unit, as systemd reads it.
    ///
    /// A scheduled job carries no `[Install]` section: the timer is what is enabled, and a oneshot service with its
    /// own install target would be started once at login as well as on its schedule.
    static func systemdService(
        name: String, service: String, job: JobSpec, environment: [(key: String, value: String)]
    ) -> String {
        var body = """
            # Written by hatchery.
            [Unit]
            Description=\(service), declared by hatchery

            [Service]
            Type=\(job.keepAlive ? "simple" : "oneshot")
            ExecStart=\(job.program.map(Self.unitEscaped).joined(separator: " "))

            """
        if let directory = job.workingDirectory, !directory.isEmpty {
            body += "WorkingDirectory=\(Self.unitEscaped(directory))\n"
        }
        for pair in environment {
            body += "Environment=\(pair.key)=\(Self.unitEscaped(pair.value))\n"
        }
        if job.keepAlive {
            body += "Restart=always\n"
        }
        if let log = job.log, !log.isEmpty {
            // Without these systemd writes to the journal, which is where a job on this box belongs.
            // A declaration that names a path is asking for the file, usually because something else reads it.
            body += "StandardOutput=append:\(Self.unitEscaped(log))\n"
            body += "StandardError=append:\(Self.unitEscaped(log))\n"
        }
        if job.schedule == nil {
            body += """

                [Install]
                WantedBy=default.target

                """
        }
        return body
    }

    /// The timer beside the unit.
    ///
    /// `Persistent=true` replays a window the box slept through, which is the case a scheduled job exists for.
    /// An interval carries `OnBootSec` beside `OnUnitActiveSec`, because a timer with only the second anchors off its
    /// own last run and a timer that has never run computes no next elapse.
    static func systemdTimer(name: String, schedule: Schedule) -> String {
        var body = """
            # Written by hatchery.
            [Unit]
            Description=\(name), on the schedule the manifest declares

            [Timer]

            """
        switch schedule {
        case .interval(let seconds):
            body += "OnBootSec=\(seconds)\n"
            body += "OnUnitActiveSec=\(seconds)\n"

        case .calendar:
            body += "OnCalendar=\(Self.onCalendar(schedule))\n"

        case .at(let expression):
            body += "OnCalendar=\(expression)\n"
        }
        body += """
            Persistent=true
            Unit=\(name).service

            [Install]
            WantedBy=timers.target

            """
        return body
    }

    /// A calendar schedule as systemd's `DayOfWeek Year-Month-Day Hour:Minute:Second`.
    ///
    /// A schedule that names an hour and no minute means the top of that hour, which is what launchd's own
    /// `StartCalendarInterval` does with the same two fields.
    static func onCalendar(_ schedule: Schedule) -> String {
        guard case .calendar(let minute, let hour, let day, let weekday) = schedule else { return "" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let prefix = weekday.map { "\(names[$0 % 7]) " } ?? ""
        let monthDay = day.map { String(format: "%02d", $0) } ?? "*"
        let hourField = hour.map { String(format: "%02d", $0) } ?? "*"
        let minuteField = minute.map { String(format: "%02d", $0) } ?? (hour == nil ? "*" : "00")
        return "\(prefix)*-*-\(monthDay) \(hourField):\(minuteField):00"
    }

    // MARK: - escaping

    /// A `<`, `>` or `&` inside a program argument or a value would end the element early.
    static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// systemd reads a newline as the end of a directive, so a value carrying one is folded to a space.
    static func unitEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

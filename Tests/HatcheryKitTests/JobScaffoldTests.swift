import XCTest
@testable import HatcheryKit

/// The two scaffolds, proved as text.
///
/// A plist and a unit are read by a supervisor and by a person, and both care about the exact bytes, so these
/// compare whole files rather than asserting that a substring is somewhere in them.
final class JobScaffoldTests: XCTestCase {
    private func nodeReport() -> ServiceSpec {
        ServiceSpec(
            name: "roost-node-report",
            kind: .job,
            image: "",
            configFile: "roost-node-report.config.json",
            job: JobSpec(
                program: ["/Users/jimmyhoughjr/repos/roost/bin/node-report.sh"],
                schedule: .interval(seconds: 30),
                log: "/tmp/roost-node-report.log",
                runAtLoad: true)
        )
    }

    private func dokkuReconcile() -> ServiceSpec {
        ServiceSpec(
            name: "dokku-reconcile",
            kind: .job,
            image: "",
            configFile: "dokku-reconcile.config.json",
            job: JobSpec(
                program: ["/home/jimmy/opt/dokku-reconcile/dokku-reconcile.sh"],
                schedule: .at("*:0/10"))
        )
    }

    func testTheLaunchAgentForAScheduledJobIsWrittenWhole() throws {
        let files = try HostProvider.jobFiles(for: nodeReport(), platform: .darwin)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(
            files[0].path, "net.jimmyhoughjr.roost-node-report.plist")
        XCTAssertEqual(
            files[0].contents,
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>net.jimmyhoughjr.roost-node-report</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/Users/jimmyhoughjr/repos/roost/bin/node-report.sh</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>StartInterval</key>
                <integer>30</integer>
                <key>StandardOutPath</key>
                <string>/tmp/roost-node-report.log</string>
                <key>StandardErrorPath</key>
                <string>/tmp/roost-node-report.log</string>
            </dict>
            </plist>

            """)
    }

    func testTheUnitAndTimerForAScheduledJobAreWrittenWhole() throws {
        let files = try HostProvider.jobFiles(for: dokkuReconcile(), platform: .linux)
        XCTAssertEqual(
            files.map(\.path), ["dokku-reconcile.service", "dokku-reconcile.timer"])
        XCTAssertEqual(
            files[0].contents,
            """
            # Written by hatchery.
            [Unit]
            Description=dokku-reconcile, declared by hatchery

            [Service]
            Type=oneshot
            ExecStart=/home/jimmy/opt/dokku-reconcile/dokku-reconcile.sh

            """)
        XCTAssertEqual(
            files[1].contents,
            """
            # Written by hatchery.
            [Unit]
            Description=dokku-reconcile, on the schedule the manifest declares

            [Timer]
            OnCalendar=*:0/10
            Persistent=true
            Unit=dokku-reconcile.service

            [Install]
            WantedBy=timers.target

            """)
    }

    /// The journal is the log unless the declaration names a path, so a unit that names none carries no redirection.
    func testAUnitWithoutALogPathWritesToTheJournal() throws {
        let files = try HostProvider.jobFiles(for: dokkuReconcile(), platform: .linux)
        XCTAssertFalse(files[0].contents.contains("StandardOutput"))
        XCTAssertFalse(files[0].contents.contains("StandardError"))
    }

    func testAKeptAliveJobIsRestartedRatherThanScheduled() throws {
        let serve = ServiceSpec(
            name: "hatchery-serve", kind: .job, image: "",
            configFile: "hatchery-serve.config.json",
            job: JobSpec(
                program: ["/usr/local/bin/hatchery", "serve", "--port", "7878"],
                log: "/var/log/hatchery-serve.log", runAtLoad: true))

        let unit = try HostProvider.jobFiles(for: serve, platform: .linux)
        XCTAssertEqual(unit.map(\.path), ["hatchery-serve.service"])
        XCTAssertTrue(unit[0].contents.contains("Type=simple"), unit[0].contents)
        XCTAssertTrue(unit[0].contents.contains("Restart=always"), unit[0].contents)
        XCTAssertTrue(unit[0].contents.contains("WantedBy=default.target"), unit[0].contents)
        XCTAssertTrue(
            unit[0].contents.contains("StandardOutput=append:/var/log/hatchery-serve.log"),
            unit[0].contents)

        let agent = try HostProvider.jobFiles(for: serve, platform: .darwin)
        XCTAssertTrue(agent[0].contents.contains("<key>KeepAlive</key>"), agent[0].contents)
        XCTAssertFalse(agent[0].contents.contains("StartInterval"), agent[0].contents)
    }

    /// The ruling of 2026-09-09: a job's secrets come from vault at boot, never from a plist value or a unit line.
    func testASecretKeyReachesNeitherThePlistNorTheUnit() throws {
        var serve = ServiceSpec(
            name: "hatchery-serve", kind: .job, image: "",
            configFile: "hatchery-serve.config.json",
            job: JobSpec(
                program: ["/usr/local/bin/hatchery", "serve"],
                environmentFromVault: true))
        serve.job?.log = "/var/log/hatchery-serve.log"
        let environment = ["HATCHERY_BIND": "0.0.0.0", "HATCHERY_TOKEN": "the-bearer-token"]

        let agent = try HostProvider.jobFiles(
            for: serve, platform: .darwin, environment: environment,
            secretKeys: ["HATCHERY_TOKEN"])
        XCTAssertTrue(agent[0].contents.contains("<key>HATCHERY_BIND</key>"), agent[0].contents)
        XCTAssertFalse(agent[0].contents.contains("HATCHERY_TOKEN"), agent[0].contents)
        XCTAssertFalse(agent[0].contents.contains("the-bearer-token"), agent[0].contents)

        let unit = try HostProvider.jobFiles(
            for: serve, platform: .linux, environment: environment,
            secretKeys: ["HATCHERY_TOKEN"])
        XCTAssertTrue(unit[0].contents.contains("Environment=HATCHERY_BIND=0.0.0.0"), unit[0].contents)
        XCTAssertFalse(unit[0].contents.contains("HATCHERY_TOKEN"), unit[0].contents)
        XCTAssertFalse(unit[0].contents.contains("the-bearer-token"), unit[0].contents)
    }

    func testACalendarScheduleBecomesBothSupervisorsCalendars() throws {
        // The laptop's watts-refresh: day 3 of every month at 07:00.
        let refresh = ServiceSpec(
            name: "watts-refresh", kind: .job, image: "",
            configFile: "watts-refresh.config.json",
            job: JobSpec(
                program: ["/Users/jimmyhoughjr/watts-site/monthly-refresh.sh"],
                schedule: .calendar(minute: 0, hour: 7, day: 3, weekday: nil),
                log: "/tmp/watts-refresh.log"))

        let agent = try HostProvider.jobFiles(for: refresh, platform: .darwin)
        XCTAssertTrue(
            agent[0].contents.contains(
                """
                    <key>StartCalendarInterval</key>
                    <dict>
                        <key>Minute</key>
                        <integer>0</integer>
                        <key>Hour</key>
                        <integer>7</integer>
                        <key>Day</key>
                        <integer>3</integer>
                    </dict>
                """), agent[0].contents)

        let unit = try HostProvider.jobFiles(for: refresh, platform: .linux)
        XCTAssertTrue(unit[1].contents.contains("OnCalendar=*-*-03 07:00:00"), unit[1].contents)
    }

    func testAMinuteOfEveryHourReadsAsAWildcardHour() {
        XCTAssertEqual(
            HostProvider.onCalendar(.calendar(minute: 10, hour: nil, day: nil, weekday: nil)),
            "*-*-* *:10:00")
        XCTAssertEqual(
            HostProvider.onCalendar(.calendar(minute: nil, hour: 23, day: nil, weekday: nil)),
            "*-*-* 23:00:00")
        XCTAssertEqual(
            HostProvider.onCalendar(.calendar(minute: 30, hour: 9, day: nil, weekday: 1)),
            "Mon *-*-* 09:30:00")
    }

    /// An interval timer uses OnCalendar with a calendar expression rather than OnBootSec+OnUnitActiveSec,
    /// because a timer that has never run computes no next elapse and silently never runs.
    func testAnIntervalTimerUsesOnCalendarExpression() throws {
        let files = try HostProvider.jobFiles(for: nodeReport(), platform: .linux)
        XCTAssertTrue(files[1].contents.contains("OnCalendar=*-*-* *:*:0/30"), files[1].contents)
        XCTAssertFalse(files[1].contents.contains("OnBootSec"), files[1].contents)
        XCTAssertFalse(files[1].contents.contains("OnUnitActiveSec"), files[1].contents)
    }

    /// launchd's calendar is a dictionary of fields, so a systemd expression has nothing to become on a Mac.
    func testAVerbatimSystemdExpressionIsRefusedOnAMac() {
        XCTAssertThrowsError(try HostProvider.jobFiles(for: dokkuReconcile(), platform: .darwin)) {
            error in
            XCTAssertEqual(
                error as? ProviderError,
                .missingDetail(
                    "a calendar launchd can read; '*:0/10' is a systemd OnCalendar expression"))
        }
    }

    func testAServiceWithoutAJobIsRefused() {
        let service = ServiceSpec(
            name: "mwlab", kind: .mwserver, image: "mwserver2:latest",
            configFile: "mwlab.config.json")
        XCTAssertThrowsError(try HostProvider.jobFiles(for: service, platform: .darwin)) { error in
            XCTAssertEqual(
                error as? ProviderError, .missingDetail("a job spec on service 'mwlab'"))
        }
    }

    // MARK: - the apply

    func testTheApplyStepsWriteTheFileThenLoadItOnAMac() throws {
        let files = try HostProvider.jobFiles(for: nodeReport(), platform: .darwin)
        let steps = JobInstaller.steps(for: nodeReport(), platform: .darwin, files: files)
        XCTAssertEqual(steps.count, 3)
        XCTAssertTrue(steps[0].hasPrefix("mkdir -p \"$HOME/Library/LaunchAgents\""), steps[0])
        XCTAssertTrue(steps[0].contains("base64 --decode"), steps[0])
        XCTAssertEqual(
            steps[1], "launchctl bootout gui/$(id -u)/net.jimmyhoughjr.roost-node-report >/dev/null 2>&1 || true")
        XCTAssertEqual(
            steps[2],
            "launchctl bootstrap gui/$(id -u) \"$HOME/Library/LaunchAgents/net.jimmyhoughjr.roost-node-report.plist\"")
    }

    func testTheApplyStepsEnableTheTimerRatherThanTheOneshotOnLinux() throws {
        let files = try HostProvider.jobFiles(for: dokkuReconcile(), platform: .linux)
        let steps = JobInstaller.steps(for: dokkuReconcile(), platform: .linux, files: files)
        XCTAssertEqual(steps.count, 4)
        XCTAssertTrue(steps[0].contains("$HOME/.config/systemd/user"), steps[0])
        XCTAssertEqual(steps[2], "systemctl --user daemon-reload")
        XCTAssertEqual(steps[3], "systemctl --user enable --now dokku-reconcile.timer")
    }

    /// A kept-alive job has no timer, so the unit itself is what is enabled.
    func testTheApplyStepsEnableTheUnitForAKeptAliveJob() throws {
        let serve = ServiceSpec(
            name: "hatchery-serve", kind: .job, image: "",
            configFile: "hatchery-serve.config.json",
            job: JobSpec(program: ["/usr/local/bin/hatchery", "serve"]))
        let files = try HostProvider.jobFiles(for: serve, platform: .linux)
        let steps = JobInstaller.steps(for: serve, platform: .linux, files: files)
        XCTAssertEqual(steps.last, "systemctl --user enable --now hatchery-serve.service")
    }

    /// The written bytes are the scaffold's bytes, which is what makes base64 worth the step.
    func testTheEncodedFileDecodesBackToTheScaffold() throws {
        let files = try HostProvider.jobFiles(for: nodeReport(), platform: .darwin)
        let steps = JobInstaller.steps(for: nodeReport(), platform: .darwin, files: files)
        let start = steps[0].range(of: "printf %s '")!.upperBound
        let end = steps[0].range(of: "' | base64 --decode")!.lowerBound
        let encoded = String(steps[0][start..<end])
        let decoded = Data(base64Encoded: encoded)
        XCTAssertEqual(String(decoding: decoded ?? Data(), as: UTF8.self), files[0].contents)
    }
}

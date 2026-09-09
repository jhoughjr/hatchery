import XCTest
@testable import HatcheryKit

/// The supervisor answers recorded on 2026-09-09, read only: `launchctl print` on this Mac and
/// `systemctl --user show` on the opi.
private func recordedSupervisor(_ name: String) throws -> String {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    return try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
}

/// One executor that answers every ssh with the same text, so no test opens a connection.
private func reporter(answering text: String, status: Int32 = 0) -> StatusReporter {
    StatusReporter(execute: { _, _ in
        CommandOutput(status: status, standardOutput: text, standardError: "")
    })
}

final class JobStatusTests: XCTestCase {
    private func mac() -> StackSpec {
        StackSpec(
            name: "laptop-jobs", backend: .host, host: "jimmy@127.0.0.1",
            settings: ["platform": "darwin"])
    }

    private func opi() -> StackSpec {
        StackSpec(
            name: "opi-jobs", backend: .host, host: "jimmy@192.168.0.103",
            settings: ["platform": "linux"])
    }

    private func nodeReport(log: String? = "/tmp/roost-node-report.log") -> ServiceSpec {
        ServiceSpec(
            name: "roost-node-report", kind: .job, image: "",
            configFile: "roost-node-report.config.json",
            job: JobSpec(
                program: ["/Users/jimmyhoughjr/repos/roost/bin/node-report.sh"],
                schedule: .interval(seconds: 30), log: log, runAtLoad: true))
    }

    private func serve() -> ServiceSpec {
        ServiceSpec(
            name: "hatchery-serve", kind: .job, image: "",
            configFile: "hatchery-serve.config.json",
            job: JobSpec(
                program: ["/usr/local/bin/hatchery", "serve"],
                log: "/Users/jimmyhoughjr/Library/Logs/hatchery-serve.log"))
    }

    /// The log's mtime, as `stat` prints it, so a test can put the log at any age it wants.
    private func answer(_ supervisor: String, logAgeSeconds: TimeInterval?) -> String {
        guard let age = logAgeSeconds else { return supervisor + "\n" + StatusReporter.logMarker }
        let epoch = Date().timeIntervalSince1970 - age
        return supervisor + "\n" + StatusReporter.logMarker + "\n\(Int(epoch))"
    }

    // MARK: - unreachable

    func testABoxThatDoesNotAnswerIsUnreachable() async {
        let reporter = StatusReporter(execute: { _, _ in
            throw CommandFailure(command: "ssh", status: 255, message: "no route to host")
        })
        let health = await reporter.status(of: nodeReport(), in: mac())

        XCTAssertEqual(health.state, .unreachable)
        XCTAssertEqual(health.reasons, ["cannot reach jimmy@127.0.0.1"])
    }

    func testASupervisorThatDoesNotHoldTheLabelIsUnreachable() async {
        let reporter = reporter(answering: answer("Could not find service", logAgeSeconds: nil))
        let health = await reporter.status(of: nodeReport(), in: mac())

        XCTAssertEqual(health.state, .unreachable)
        XCTAssertEqual(
            health.reasons,
            ["the supervisor on jimmy@127.0.0.1 does not hold 'net.jimmyhoughjr.roost-node-report'"])
    }

    // MARK: - degraded

    /// The exit the inventory recorded on 2026-09-09: curl could not reach pulse on the last run.
    func testANonZeroLastExitIsDegraded() async throws {
        let recorded = try recordedSupervisor("roost-node-report.launchctl-print.txt")
            .replacingOccurrences(of: "last exit code = 0", with: "last exit code = 56")
        let reporter = reporter(answering: answer(recorded, logAgeSeconds: 10))
        let health = await reporter.status(of: nodeReport(), in: mac())

        XCTAssertEqual(health.state, .degraded)
        XCTAssertEqual(health.reasons, ["the last run exited 56"])
    }

    func testAKeptAliveJobThatIsNotRunningIsDegraded() async {
        let answer = self.answer(
            """
            gui/501/net.jimmyhoughjr.hatchery-serve = {
            \tstate = not running
            \tlast exit code = 0
            }
            """, logAgeSeconds: 10)
        let health = await reporter(answering: answer).status(of: serve(), in: mac())

        XCTAssertEqual(health.state, .degraded)
        XCTAssertEqual(
            health.reasons, ["the job is kept alive and the supervisor is not holding it"])
    }

    // MARK: - responding

    /// A supervisor that is happy and a log that is stale is a job that is being started and doing nothing.
    func testAStaleLogIsRespondingRatherThanReady() async throws {
        let recorded = try recordedSupervisor("roost-node-report.launchctl-print.txt")
        let reporter = reporter(answering: answer(recorded, logAgeSeconds: 600))
        let health = await reporter.status(of: nodeReport(), in: mac())

        XCTAssertEqual(health.state, .responding)
        XCTAssertEqual(health.reasons.count, 1)
        XCTAssertTrue(
            health.reasons[0].hasPrefix(
                "the supervisor is happy, and /tmp/roost-node-report.log has not been written"),
            health.reasons[0])
    }

    func testAJobWithNoLogCannotReadAsReady() async throws {
        let recorded = try recordedSupervisor("roost-node-report.launchctl-print.txt")
        let reporter = reporter(answering: answer(recorded, logAgeSeconds: nil))
        let health = await reporter.status(of: nodeReport(log: nil), in: mac())

        XCTAssertEqual(health.state, .responding)
        XCTAssertEqual(
            health.reasons, ["the supervisor is happy, and the job declares no log to read"])
    }

    func testAMissingLogFileIsRespondingRatherThanReady() async throws {
        let recorded = try recordedSupervisor("roost-node-report.launchctl-print.txt")
        let reporter = reporter(answering: answer(recorded, logAgeSeconds: nil))
        let health = await reporter.status(of: nodeReport(), in: mac())

        XCTAssertEqual(health.state, .responding)
        XCTAssertEqual(
            health.reasons,
            ["the supervisor is happy, and there is no /tmp/roost-node-report.log to read"])
    }

    // MARK: - ready

    func testAHappySupervisorAndAFreshLogAreReady() async throws {
        let recorded = try recordedSupervisor("roost-node-report.launchctl-print.txt")
        let reporter = reporter(answering: answer(recorded, logAgeSeconds: 20))
        let health = await reporter.status(of: nodeReport(), in: mac())

        XCTAssertEqual(health.state, .ready)
        XCTAssertTrue(health.reasons.isEmpty)
    }

    /// The opi's own answer, recorded: a oneshot between runs, which is the resting state of a timer's unit.
    func testAnIdleOneshotOnLinuxIsReadyWhenItsLogIsFresh() async throws {
        let recorded = try recordedSupervisor("roost-node-report.systemctl-show.txt")
        let reporter = reporter(answering: answer(recorded, logAgeSeconds: 20))
        let health = await reporter.status(
            of: nodeReport(log: "/var/log/roost-node-report.log"), in: opi())

        XCTAssertEqual(health.state, .ready)
    }

    // MARK: - the pieces

    func testTheLogProbeAsksEachPlatformInItsOwnFlag() {
        XCTAssertEqual(
            StatusReporter.logProbe("/tmp/a.log", platform: .darwin),
            "stat -f %m '/tmp/a.log' 2>/dev/null || true")
        XCTAssertEqual(
            StatusReporter.logProbe("/tmp/a.log", platform: .linux),
            "stat -c %Y '/tmp/a.log' 2>/dev/null || true")
        XCTAssertEqual(StatusReporter.logProbe(nil, platform: .linux), "true")
    }

    func testFreshnessIsTwiceTheIntervalAndAnHourForAKeptAliveJob() {
        XCTAssertEqual(
            StatusReporter.freshness(of: JobSpec(program: ["x"], schedule: .interval(seconds: 30))),
            60)
        XCTAssertEqual(StatusReporter.freshness(of: JobSpec(program: ["x"])), 3600)
        XCTAssertEqual(
            StatusReporter.freshness(of: JobSpec(program: ["x"], schedule: .at("*:0/10"))), 3600)
    }

    func testTheRecordedLaunchctlPrintReadsAsAnIdleJobThatLastExitedZero() throws {
        let read = JobObservation.read(
            try recordedSupervisor("roost-node-report.launchctl-print.txt"),
            label: "net.jimmyhoughjr.roost-node-report", platform: .darwin)

        XCTAssertEqual(read?.running, false)
        XCTAssertEqual(read?.lastExit, 0)
    }

    func testTheRecordedSystemctlShowReadsAsAnIdleUnitWithATimeOfItsLastRun() throws {
        let read = JobObservation.read(
            try recordedSupervisor("roost-node-report.systemctl-show.txt"),
            label: "roost-node-report", platform: .linux)

        XCTAssertEqual(read?.running, false)
        XCTAssertEqual(read?.lastExit, 0)
        XCTAssertNotNil(read?.lastRun)
    }

    func testAUnitSystemdHasNeverHeardOfIsNoObservation() {
        let text = """
            LoadState=not-found
            ExecMainStatus=0
            ExecMainExitTimestamp=
            ActiveState=inactive
            """
        XCTAssertNil(JobObservation.read(text, label: "nothing", platform: .linux))
    }

    /// A kept-alive unit that is running has not exited, so its status is about nothing.
    func testARunningUnitWithNoExitTimestampReportsNoLastExit() {
        let text = """
            LoadState=loaded
            Result=success
            ExecMainExitTimestamp=
            ExecMainStatus=0
            ActiveState=active
            SubState=running
            """
        let read = JobObservation.read(text, label: "roost-tapo-poll", platform: .linux)

        XCTAssertEqual(read?.running, true)
        XCTAssertNil(read?.lastExit)
    }
}

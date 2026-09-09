import XCTest
@testable import HatcheryKit

final class JobSpecTests: XCTestCase {
    /// The two shapes the inventory found: a scheduled job that exits, and a process the supervisor keeps alive.
    private func boxStack() -> StackSpec {
        StackSpec(
            name: "laptop-jobs",
            backend: .host,
            host: "jimmy@127.0.0.1",
            settings: ["platform": "darwin"],
            services: [
                ServiceSpec(
                    name: "roost-node-report",
                    kind: .job,
                    image: "",
                    configFile: "roost-node-report.config.json",
                    job: JobSpec(
                        program: ["/Users/jimmy/roost/bin/node-report.sh"],
                        schedule: .interval(seconds: 30),
                        log: "/tmp/roost-node-report.log",
                        runAtLoad: true)
                ),
                ServiceSpec(
                    name: "hatchery-serve",
                    kind: .job,
                    image: "",
                    configFile: "hatchery-serve.config.json",
                    job: JobSpec(
                        program: ["/usr/local/bin/hatchery", "serve", "--port", "7878"],
                        log: "/Users/jimmy/Library/Logs/hatchery-serve.log",
                        runAtLoad: true,
                        environmentFromVault: true)
                ),
            ]
        )
    }

    func testAScheduledJobAndAKeptAliveJobRoundTrip() throws {
        let manifest = StackManifest(stacks: [boxStack()])
        let decoded = try StackManifest.decode(from: manifest.encoded())
        XCTAssertEqual(decoded, manifest)
    }

    func testAJobWithNoScheduleIsKeptAlive() {
        let job = JobSpec(program: ["/usr/local/bin/hatchery", "serve"])
        XCTAssertTrue(job.keepAlive)
        XCTAssertNil(job.schedule)
    }

    func testAScheduledJobIsNotKeptAlive() {
        let job = JobSpec(program: ["/bin/echo"], schedule: .interval(seconds: 30))
        XCTAssertFalse(job.keepAlive)
    }

    /// A schedule reads as one key rather than a wrapper, so a manifest stays hand-editable.
    func testAScheduleEncodesAsOneKey() throws {
        let json = String(decoding: try StackManifest(stacks: [boxStack()]).encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"interval\" : 30"), json)
    }

    func testACalendarScheduleRoundTrips() throws {
        let schedule = Schedule.calendar(minute: 0, hour: 7, day: 3, weekday: nil)
        let data = try JSONEncoder().encode(schedule)
        XCTAssertEqual(try JSONDecoder().decode(Schedule.self, from: data), schedule)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("weekday"), json)
    }

    func testAVerbatimScheduleRoundTrips() throws {
        let schedule = Schedule.at("*-*-* 03:30:00")
        let data = try JSONEncoder().encode(schedule)
        XCTAssertEqual(try JSONDecoder().decode(Schedule.self, from: data), schedule)
    }

    /// A service that says nothing about a job gains no key, so every manifest written before this still reads.
    func testAServiceWithoutAJobWritesNoJobKey() throws {
        let service = ServiceSpec(
            name: "mwlab", kind: .mwserver, image: "mwserver2:latest",
            configFile: "mwlab.config.json")
        let json = String(decoding: try JSONEncoder().encode(service), as: UTF8.self)
        XCTAssertFalse(json.contains("job"), json)
    }

    func testAServiceDeclaringBothAContainerAndAJobIsRejected() {
        var stack = boxStack()
        stack.services[0].container = ContainerSpec(image: "alpine:3")
        let manifest = StackManifest(stacks: [stack])
        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? ManifestError,
                .jobAndContainer(stack: "laptop-jobs", service: "roost-node-report"))
        }
    }

    func testAJobOnADokkuStackIsRejected() {
        var stack = boxStack()
        stack.backend = .dokku
        stack.host = "dokku@192.168.0.103"
        let manifest = StackManifest(stacks: [stack])
        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? ManifestError,
                .jobOffHost(stack: "laptop-jobs", service: "roost-node-report", backend: "dokku"))
        }
    }

    func testAStackReadsItsPlatformFromItsSettings() {
        XCTAssertEqual(boxStack().platform, .darwin)
        XCTAssertEqual(
            StackSpec(name: "opi", backend: .host, host: "jimmy@192.168.0.103").platform, .linux)
    }

    func testUnameNamesThePlatform() {
        XCTAssertEqual(HostPlatform.named("Darwin\n"), .darwin)
        XCTAssertEqual(HostPlatform.named("Linux\n"), .linux)
        XCTAssertNil(HostPlatform.named("FreeBSD"))
    }
}

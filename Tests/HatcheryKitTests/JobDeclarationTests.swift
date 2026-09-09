import XCTest
@testable import HatcheryKit

final class JobDeclarationTests: XCTestCase {
    /// The laptop as phase 4 declares it: one scheduled job and the one process that carries a token.
    private func laptop() -> StackSpec {
        StackSpec(
            name: "laptop-jobs",
            backend: .host,
            host: "jimmy@127.0.0.1",
            settings: ["platform": "darwin"],
            services: [
                ServiceSpec(
                    name: "roost-node-report", kind: .job, image: "",
                    configFile: "roost-node-report.config.json",
                    job: JobSpec(
                        program: ["/Users/jimmyhoughjr/repos/roost/bin/node-report.sh"],
                        schedule: .interval(seconds: 30),
                        log: "/tmp/roost-node-report.log", runAtLoad: true)),
                ServiceSpec(
                    name: "hatchery-serve", kind: .job, image: "",
                    configFile: "hatchery-serve.config.json",
                    job: JobSpec(
                        program: [
                            "/Users/jimmyhoughjr/.local/bin/hatchery", "serve", "--port", "7878",
                            "--token", "REDACTED",
                        ],
                        log: "/Users/jimmyhoughjr/Library/Logs/hatchery-serve.log",
                        runAtLoad: true)),
            ])
    }

    private func document() -> Declaration {
        Declaration(
            manifests: [(manifest: StackManifest(stacks: [laptop()]), path: "/tmp/hatchery.json")])
    }

    func testAJobCarriesItsScheduleKeepAliveLogAndPlatform() {
        let services = document().stacks[0].services
        let report = services[0]

        XCTAssertEqual(report.kind, "job")
        XCTAssertEqual(report.schedule, "every 30s")
        XCTAssertEqual(report.keepAlive, false)
        XCTAssertEqual(report.log, "/tmp/roost-node-report.log")
        XCTAssertEqual(report.platform, "darwin")
    }

    func testAKeptAliveJobCarriesNoSchedule() {
        let serve = document().stacks[0].services[1]

        XCTAssertNil(serve.schedule)
        XCTAssertEqual(serve.keepAlive, true)
    }

    /// A document of dokku apps gains no job field, so nothing that reads it has a new case to handle.
    func testAServiceThatIsNotAJobCarriesNoneOfTheFourFields() throws {
        let stack = StackSpec(
            name: "mwlab", backend: .dokku, host: "dokku@127.0.0.1",
            services: [
                ServiceSpec(
                    name: "mwlab", kind: .mwserver, image: "mwserver2:latest",
                    configFile: "mwlab.config.json")
            ])
        let document = Declaration(
            manifests: [(manifest: StackManifest(stacks: [stack]), path: "/tmp/hatchery.json")])
        let json = String(decoding: try document.encoded(), as: UTF8.self)

        XCTAssertFalse(json.contains("schedule"), json)
        XCTAssertFalse(json.contains("keepAlive"), json)
        XCTAssertFalse(json.contains("platform"), json)
    }

    func testAJobAnswersAsNameKindBackend() {
        XCTAssertEqual(
            document().answers,
            ["roost-node-report job host", "hatchery-serve job host"])
    }

    // MARK: - the two findings

    /// The laptop's hatchery-serve agent, recorded on 2026-09-09 with its token replaced.
    /// `ps` shows the whole command line to every account on the machine, so the plist is not the only copy.
    func testACredentialOnTheCommandLineRaisesSecretInPlist() {
        let findings = DeclarationAudit.jobFindings(for: laptop().services[1], platform: .darwin)
        let secret = findings.first { $0.code == FindingCode.secretInPlist }

        XCTAssertNotNil(secret)
        XCTAssertTrue(secret?.text.contains("--token") ?? false, secret?.text ?? "")
    }

    func testALogUnderTmpRaisesNoLog() {
        let findings = DeclarationAudit.jobFindings(for: laptop().services[0], platform: .darwin)

        XCTAssertEqual(findings.map(\.code), [FindingCode.noLog])
        XCTAssertTrue(
            findings[0].text.contains("/tmp/roost-node-report.log"), findings[0].text)
    }

    func testAJobThatNamesNoLogRaisesNoLogOnDarwin() {
        let service = ServiceSpec(
            name: "phoenix-builds", kind: .job, image: "",
            configFile: "phoenix-builds.config.json",
            job: JobSpec(program: ["python3", "-m", "http.server", "8090"]))
        let findings = DeclarationAudit.jobFindings(for: service, platform: .darwin)

        XCTAssertEqual(findings.map(\.code), [FindingCode.noLog])
        XCTAssertTrue(findings[0].text.contains("names no log"), findings[0].text)
    }

    func testAJobThatNamesNoLogDoesNotRaiseNoLogOnLinux() {
        let service = ServiceSpec(
            name: "phoenix-builds", kind: .job, image: "",
            configFile: "phoenix-builds.config.json",
            job: JobSpec(program: ["python3", "-m", "http.server", "8090"]))
        let findings = DeclarationAudit.jobFindings(for: service, platform: .linux)

        XCTAssertTrue(findings.isEmpty, "absent log on linux is the journal and is not a finding")
    }

    func testACleanJobRaisesNothing() {
        let service = ServiceSpec(
            name: "hatchery-declared", kind: .job, image: "",
            configFile: "hatchery-declared.config.json",
            job: JobSpec(
                program: ["/Users/jimmyhoughjr/.local/bin/hatchery", "declared", "--publish"],
                schedule: .interval(seconds: 86400),
                log: "/Users/jimmyhoughjr/Library/Logs/hatchery-declared.log"))

        XCTAssertTrue(DeclarationAudit.jobFindings(for: service, platform: .darwin).isEmpty)
    }

    /// A flag at the end of the arguments carries no value, so it is a flag and not a credential.
    func testACredentialFlagWithNoValueIsNotAFinding() {
        XCTAssertNil(DeclarationAudit.credentialFlag(in: ["hatchery", "serve", "--token"]))
        XCTAssertEqual(
            DeclarationAudit.credentialFlag(in: ["hatchery", "serve", "--token=abc"]), "--token")
        XCTAssertEqual(
            DeclarationAudit.credentialFlag(in: ["curl", "--password", "abc"]), "--password")
    }

    /// The findings reach the published document, which is where the coop draws them.
    func testTheFindingsReachThePublishedDocument() {
        let manifest = StackManifest(stacks: [laptop()])
        let found = [
            "laptop-jobs/hatchery-serve": DeclarationAudit.jobFindings(for: laptop().services[1], platform: .darwin)
        ]
        let document = Declaration(
            manifests: [(manifest: manifest, path: "/tmp/hatchery.json")], findings: found)

        XCTAssertEqual(
            document.stacks[0].services[1].findings.map(\.code), [FindingCode.secretInPlist])
    }
}

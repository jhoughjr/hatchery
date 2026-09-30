import Foundation
import Testing

@testable import HatcheryKit

private func service(_ job: String, description: String? = nil) throws -> ServiceSpec {
    let text = description.map { ", \"description\": \"\($0)\"" } ?? ""
    return try JSONDecoder().decode(
        ServiceSpec.self,
        from: Data("{\"name\": \"watch\", \"kind\": \"job\", \"image\": \"\", \"domains\": [], \"configFile\": \"w.config.json\"\(text), \"job\": \(job)}".utf8))
}

@Suite("What a job declares beyond its program and its schedule")
struct JobDirectivesTests {
    @Test("a unit carries OnFailure under [Unit], the declared description, and each directive in its own section")
    func systemdDirectives() throws {
        let spec = try service(
            """
            {"program": ["%h/opt/r/r.sh"], "keepAlive": false, "schedule": {"at": "*:0/10"}, "onFailure": "r-alert.service",
             "directives": {"Unit.Documentation": "https://example/r", "Service.SuccessExitStatus": "0 1", "Service.TimeoutStartSec": "120", "Service.EnvironmentFile": "-%h/.config/r.env"}}
            """, description: "Start apps that are down")
        let unit = try HostProvider.jobFiles(for: spec, platform: .linux)[0].contents

        let head = try #require(unit.range(of: "[Unit]")), body = try #require(unit.range(of: "[Service]"))
        let failure = try #require(unit.range(of: "OnFailure=r-alert.service"))
        #expect(failure.lowerBound > head.lowerBound && failure.lowerBound < body.lowerBound)
        #expect(unit.contains("Description=Start apps that are down\n"))
        #expect(unit.contains("Documentation=https://example/r\n"))
        #expect(unit.contains("EnvironmentFile=-%h/.config/r.env\nSuccessExitStatus=0 1\nTimeoutStartSec=120\n"))
        // A scheduled job is started by its timer, so its own unit is wanted by nothing.
        #expect(!unit.contains("[Install]"))
    }

    @Test("a timer carries its own directives, and the unit beside it carries none of them")
    func timerDirectives() throws {
        let spec = try service(#"{"program": ["/r/report.sh"], "keepAlive": false, "schedule": {"interval": 30}, "directives": {"Timer.AccuracySec": "5s", "Timer.RandomizedDelaySec": "30"}}"#)
        let files = try HostProvider.jobFiles(for: spec, platform: .linux)
        #expect(files[1].contents.contains("AccuracySec=5s\nRandomizedDelaySec=30\nPersistent=true"))
        #expect(!files[0].contents.contains("AccuracySec"))
    }

    @Test("a command argument with spaces is quoted, or the shell is given its first word alone")
    func quotesAnArgument() throws {
        let spec = try service(#"{"program": ["/bin/sh", "-c", "exec %h/m.sh \"opi: $(journalctl -n 1)\""], "keepAlive": false}"#)
        let unit = try HostProvider.jobFiles(for: spec, platform: .linux)[0].contents
        #expect(unit.contains(#"ExecStart=/bin/sh -c 'exec %h/m.sh "opi: $(journalctl -n 1)"'"#))
    }

    @Test("a job another unit asks for is wanted by no target, and one kept alive is")
    func installSection() throws {
        let demand = try service(#"{"program": ["/x"], "keepAlive": false}"#)
        #expect(demand.job?.start == .demand)
        #expect(!(try HostProvider.jobFiles(for: demand, platform: .linux)[0].contents.contains("[Install]")))
        let kept = try service(#"{"program": ["/x"], "keepAlive": true, "directives": {"Service.RestartSec": "15", "Service.KillMode": "process"}}"#)
        let unit = try HostProvider.jobFiles(for: kept, platform: .linux)[0].contents
        #expect(kept.job?.start == .keep)
        #expect(unit.contains("Restart=always\nKillMode=process\nRestartSec=15\n"))
        #expect(unit.contains("[Install]\nWantedBy=default.target"))
    }

    @Test("a plist carries its own error log and each directive as the kind of value it is")
    func launchdDirectives() throws {
        let spec = try service(
            #"{"program": ["/r/runsvc.sh"], "keepAlive": true, "runAtLoad": true, "log": "/l/stdout.log", "errorLog": "/l/stderr.log", "directives": {"ProcessType": "Interactive", "SessionCreate": "true", "ExitTimeOut": "30"}}"#)
        let plist = try HostProvider.jobFiles(for: spec, platform: .darwin)[0].contents
        #expect(plist.contains("<key>StandardErrorPath</key>\n    <string>/l/stderr.log</string>"))
        #expect(plist.contains("<key>StandardOutPath</key>\n    <string>/l/stdout.log</string>"))
        #expect(plist.contains("<key>ProcessType</key>\n    <string>Interactive</string>"))
        #expect(plist.contains("<key>SessionCreate</key>\n    <true/>"))
        #expect(plist.contains("<key>ExitTimeOut</key>\n    <integer>30</integer>"))
    }

    @Test("the three new fields survive a manifest round trip, and an old manifest reads with none")
    func roundTrip() throws {
        let job = JobSpec(program: ["/x"], onFailure: "a.service", errorLog: "/e", directives: ["Service.RestartSec": "15"])
        let back = try JSONDecoder().decode(JobSpec.self, from: try JSONEncoder().encode(job))
        #expect(back == job)
        let old = try JSONDecoder().decode(JobSpec.self, from: Data(#"{"program": ["/x"], "keepAlive": true}"#.utf8))
        #expect(old.onFailure == nil && old.errorLog == nil && old.directives == nil)
    }
}

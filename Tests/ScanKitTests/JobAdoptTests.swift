import Foundation
import Testing

import HatcheryKit

@testable import ScanKit

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { self.stored = value }
    var value: T {
        get { self.lock.withLock { self.stored } }
        set { self.lock.withLock { self.stored = newValue } }
    }
}

/// The supervisor files recorded on 2026-09-09, read only: two launchd agents off this Mac and the
/// dokku-reconcile unit and timer off the opi.
private func recordedJob(_ name: String) throws -> String {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    return try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
}

private func hostStack() -> StackSpec {
    StackSpec(
        name: "opi-jobs", backend: .host, host: "jimmy@192.168.0.103",
        settings: ["platform": "linux"])
}

private func macStack() -> StackSpec {
    StackSpec(
        name: "laptop-jobs", backend: .host, host: "jimmy@127.0.0.1",
        settings: ["platform": "darwin"])
}

@Suite("Reading a job off a host and declaring it")
struct JobAdoptTests {
    @Test("the recorded launchd agent reads into the spec the Mac runs it with")
    func readsTheAgent() throws {
        let read = try JobReader.agent(Data(try recordedJob("roost-node-report.agent.plist").utf8))

        #expect(read.label == "net.jimmyhoughjr.roost-node-report")
        #expect(read.name == "roost-node-report")
        #expect(read.job.program == ["/Users/jimmyhoughjr/repos/roost/bin/node-report.sh"])
        #expect(read.job.schedule == .interval(seconds: 30))
        #expect(read.job.keepAlive == false)
        #expect(read.job.runAtLoad)
        #expect(read.job.log == "/tmp/roost-node-report.log")
        #expect(read.environment.isEmpty)
    }

    @Test("a kept-alive agent reads as kept alive, with the whole command line it runs")
    func readsAKeptAliveAgent() throws {
        let read = try JobReader.agent(Data(try recordedJob("hatchery-serve.agent.plist").utf8))

        #expect(read.name == "hatchery-serve")
        #expect(read.job.schedule == nil)
        #expect(read.job.keepAlive)
        #expect(read.job.program.contains("--token"))
        #expect(read.job.log == "/Users/jimmyhoughjr/Library/Logs/hatchery-serve.log")
    }

    @Test("the recorded unit and its timer read into one spec")
    func readsTheUnit() throws {
        let read = try JobReader.unit(
            named: "dokku-reconcile",
            service: try recordedJob("dokku-reconcile.service"),
            timer: try recordedJob("dokku-reconcile.timer"))

        #expect(read.name == "dokku-reconcile")
        #expect(read.job.program == ["%h/opt/dokku-reconcile/dokku-reconcile.sh"])
        #expect(read.job.schedule == .at("*:0/10"))
        #expect(read.job.keepAlive == false)
        // The unit names no StandardOutput, so the journal is the log and the spec names no path.
        #expect(read.job.log == nil)
    }

    @Test("a unit with no timer beside it is a job the box keeps alive")
    func readsAKeptAliveUnit() throws {
        let read = try JobReader.unit(
            named: "roost-tapo-poll",
            service: """
                [Unit]
                Description=Poll the Tapo plugs

                [Service]
                Type=simple
                ExecStart=%h/roost/bin/tapo-poll.py --watch
                Environment=ROOST_PULSE=https://pulse.jimmyhoughjr.net
                Restart=always

                [Install]
                WantedBy=default.target
                """)

        #expect(read.job.schedule == nil)
        #expect(read.job.keepAlive)
        #expect(read.job.program == ["%h/roost/bin/tapo-poll.py", "--watch"])
        #expect(read.environment == ["ROOST_PULSE": "https://pulse.jimmyhoughjr.net"])
    }

    @Test("a file that is neither shape is refused rather than half-read")
    func refusesAnythingElse() {
        #expect(throws: AdoptError.notAJobFile("a launchd agent plist with a Label")) {
            try JobReader.agent(Data("not a plist at all".utf8))
        }
        #expect(throws: AdoptError.notAJobFile("a systemd unit with an ExecStart")) {
            try JobReader.unit(named: "x", service: "[Unit]\nDescription=nothing to run\n")
        }
    }

    @Test("an interval a timer names with a unit reads as seconds")
    func readsAnIntervalWithAUnit() {
        #expect(JobReader.seconds("600") == 600)
        #expect(JobReader.seconds("10min") == 600)
        #expect(JobReader.seconds("30s") == 30)
        #expect(JobReader.seconds("1h") == 3600)
        #expect(JobReader.seconds("whenever") == nil)
    }

    @Test("adopt declares the job into the stack, with the artifact beside it and no tofu import")
    func plansTheJob() throws {
        let read = try JobReader.unit(
            named: "dokku-reconcile",
            service: try recordedJob("dokku-reconcile.service"),
            timer: try recordedJob("dokku-reconcile.timer"))
        let manifest = StackManifest(stacks: [hostStack()])
        let result = try Adopter().planJob(
            read, kind: .job, into: "opi-jobs", box: "jimmy@192.168.0.103", manifest: manifest,
            manifestPath: "/tmp/hatchery.json")

        #expect(result.service.kind == .job)
        #expect(result.service.job?.schedule == .at("*:0/10"))
        // The label is the one the estate would have written, so the spec carries none.
        #expect(result.service.job?.label == nil)
        #expect(result.importCommand.isEmpty)
        #expect(
            result.files.map(\.path) == [
                "dokku-reconcile.service", "dokku-reconcile.timer", "dokku-reconcile.config.json",
            ])
        #expect(try StackManifest.decode(from: result.manifest.encoded()) == result.manifest)
    }

    @Test("adopting a job the stack already declares is refused without --replace")
    func refusesADoubleDeclaration() throws {
        let read = try JobReader.agent(
            Data(try recordedJob("roost-node-report.agent.plist").utf8))
        var stack = macStack()
        stack.services = [
            ServiceSpec(
                name: "roost-node-report", kind: .job, image: "",
                configFile: "roost-node-report.config.json",
                job: JobSpec(program: ["x"]))
        ]
        let manifest = StackManifest(stacks: [stack])

        #expect(
            throws: AdoptError.alreadyDeclared(app: "roost-node-report", stack: "laptop-jobs")
        ) {
            try Adopter().planJob(
                read, kind: .job, into: "laptop-jobs", box: "jimmy@127.0.0.1", manifest: manifest,
                manifestPath: "/tmp/hatchery.json")
        }
    }

    @Test("a job declared on a dokku stack is refused, because dokku runs no supervisor for it")
    func refusesADokkuStack() throws {
        let read = try JobReader.agent(
            Data(try recordedJob("roost-node-report.agent.plist").utf8))
        let manifest = StackManifest(stacks: [
            StackSpec(name: "mwlab", backend: .dokku, host: "dokku@127.0.0.1")
        ])

        #expect(
            throws: AdoptError.stackNotOnHost(
                stack: "mwlab", backend: "dokku", box: "jimmy@127.0.0.1")
        ) {
            try Adopter().planJob(
                read, kind: .job, into: "mwlab", box: "jimmy@127.0.0.1", manifest: manifest,
                manifestPath: "/tmp/hatchery.json")
        }
    }

    // MARK: - the scan

    @Test("the scan reads every agent under the account and says which the supervisor holds")
    func listsTheAgents() throws {
        let answer = """
            \(Scanner.jobMarker)/Users/jimmyhoughjr/Library/LaunchAgents/net.jimmyhoughjr.roost-node-report.plist
            \(try recordedJob("roost-node-report.agent.plist"))
            \(Scanner.jobMarker)/Users/jimmyhoughjr/Library/LaunchAgents/com.google.keystone.agent.plist
            \(try recordedJob("hatchery-serve.agent.plist"))
            \(Scanner.supervisorMarker)
            PID\tStatus\tLabel
            -\t56\tnet.jimmyhoughjr.roost-node-report
            """
        let found = Scanner.jobInventory(from: answer, platform: .darwin)

        #expect(found.count == 2)
        #expect(found.map(\.label).contains("net.jimmyhoughjr.roost-node-report"))
        let report = found.first { $0.label == "net.jimmyhoughjr.roost-node-report" }
        #expect(report?.schedule == "every 30s")
        #expect(report?.lastExit == 56)
        #expect(report?.running == false)
        #expect(report?.log == "/tmp/roost-node-report.log")
    }

    @Test("the scan pairs a unit with its timer and does not list the timer as a job of its own")
    func listsTheUnits() throws {
        let answer = """
            \(Scanner.jobMarker)/home/jimmy/.config/systemd/user/dokku-reconcile.service
            \(try recordedJob("dokku-reconcile.service"))
            \(Scanner.jobMarker)/home/jimmy/.config/systemd/user/dokku-reconcile.timer
            \(try recordedJob("dokku-reconcile.timer"))
            \(Scanner.supervisorMarker)
            dokku-reconcile.timer loaded active waiting Reconcile dokku apps
            """
        let found = Scanner.jobInventory(from: answer, platform: .linux)

        #expect(found.count == 1)
        #expect(found[0].label == "dokku-reconcile")
        #expect(found[0].schedule == "*:0/10")
        #expect(found[0].program == "%h/opt/dokku-reconcile/dokku-reconcile.sh")
    }

    @Test("a job somebody else installed is not offered as one to declare")
    func leavesForeignJobsAlone() {
        #expect(!JobNames.isDeclarable("com.google.keystone.agent"))
        #expect(!JobNames.isDeclarable("com.apple.SafariBookmarksSyncAgent"))
        #expect(!JobNames.isDeclarable("launchpadlib-cache-clean"))
        #expect(JobNames.isDeclarable("net.jimmyhoughjr.roost-node-report"))
        #expect(JobNames.isDeclarable("dokku-reconcile"))
    }

    @Test("the scan asks each supervisor in its own command")
    func asksEachSupervisorItsOwnWay() {
        #expect(Scanner.jobCommand(platform: .darwin).contains("launchctl list"))
        #expect(Scanner.jobCommand(platform: .darwin).contains("Library/LaunchAgents"))
        #expect(Scanner.jobCommand(platform: .linux).contains("systemctl --user list-units"))
        #expect(Scanner.jobCommand(platform: .linux).contains(".config/systemd/user"))
    }

    @Test("adopt uses double quotes around $HOME so the remote shell expands it")
    func adopterQuotesHomeForExpansion() async throws {
        let capturedCommands = LockedBox<[String]>([])
        let mockExecutor: CommandExecutor = { argv, _ in
            if let command = argv.last {
                var current = capturedCommands.value
                current.append(command)
                capturedCommands.value = current
            }
            return CommandOutput(status: 0, standardOutput: "", standardError: "")
        }

        let adopter = Adopter(execute: mockExecutor)
        do {
            _ = try await adopter.job(named: "test", on: "example.com", platform: .darwin)
        } catch {
            // Expected to fail because the plist is empty; we only verify the command format.
        }

        let commands = capturedCommands.value
        #expect(commands.count == 1)
        let command = commands[0]
        #expect(command.contains("\"$HOME/Library/LaunchAgents/test.plist\""))
        #expect(command.contains("\"$HOME/Library/LaunchAgents/net.jimmyhoughjr.test.plist\""))
    }

    @Test("adopt uses double quotes around $HOME for Linux units")
    func adopterQuotesHomeForLinuxUnits() async throws {
        let capturedCommands = LockedBox<[String]>([])
        let mockExecutor: CommandExecutor = { argv, _ in
            if let command = argv.last {
                var current = capturedCommands.value
                current.append(command)
                capturedCommands.value = current
            }
            return CommandOutput(status: 0, standardOutput: "", standardError: "")
        }

        let adopter = Adopter(execute: mockExecutor)
        do {
            _ = try await adopter.job(named: "test", on: "example.com", platform: .linux)
        } catch {
            // Expected to fail because the unit is empty; we only verify the command format.
        }

        let commands = capturedCommands.value
        #expect(commands.count == 1)
        let command = commands[0]
        #expect(command.contains("\"$HOME/.config/systemd/user/test.service\""))
        #expect(command.contains("\"$HOME/.config/systemd/user/test.timer\""))
    }

    @Test("a local target builds commands with no ssh prefix")
    func localTargetNeedsNoSSH() async throws {
        let capturedArgs = LockedBox<[[String]]>([])
        let mockExecutor: CommandExecutor = { argv, _ in
            var current = capturedArgs.value
            current.append(argv)
            capturedArgs.value = current
            return CommandOutput(status: 0, standardOutput: "", standardError: "")
        }

        let adopter = Adopter(execute: mockExecutor)
        do {
            _ = try await adopter.job(named: "test", on: "local", platform: .linux)
        } catch {
            // Expected to fail because the unit is empty; we only verify the command format.
        }

        let args = capturedArgs.value
        #expect(args.count == 1)
        let argv = args[0]
        // Local target uses sh -c, not ssh
        #expect(argv.first == "sh")
        #expect(argv[1] == "-c")
        #expect(!argv.contains("ssh"))
    }
}

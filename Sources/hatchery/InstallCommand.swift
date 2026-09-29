import ArgumentParser
import Foundation
import HatcheryKit

/// Every host holds what its declaration says, from the forge's main.
///
/// A merge to hatchery, roost or the house skill changed nothing on a box until a hand ran an installer there, and
/// five traps in the house skill traced to that gap. This verb reads each declared job's program, finds the checkout,
/// binary or copy it runs from, reads what the host holds against the source's main, and brings the difference level.
struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Read what each host holds against its declaration and the forge's main, and with --yes install the difference.",
        discussion: """
            The declaration is the list: a declared job names its program, and the program lives in a checkout, is \
            a built binary, or is a copy of a file from a checkout. Each of those and the job's own plist or unit is \
            one row. Without --yes the table prints and nothing changes. With --yes every host is probed first, and \
            a silent host refuses the whole run before anything is written; then each row that is behind, missing or \
            differs is brought level: a checkout fetches the forge's main and fast-forwards, a binary is rebuilt from \
            its checkout by its own installer, a copy is placed by its tool's installer, and a missing job file is \
            written the way the executor writes it and the supervisor reads it again. A dirty checkout is never \
            touched, and a job file that differs is rewritten only with --jobs, because a hand-written file may hold \
            what the declaration cannot yet say.

            --publish sends the report to pulse beside the declaration, where the coop's Estate page reads it.
            """
    )

    @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
    var manifest: [String] = []

    @Flag(name: .long, help: "Install the difference. Without it the table prints and nothing changes.")
    var yes = false

    @Option(name: .long, help: "Only this host, as the manifest names it.")
    var host: String?

    @Flag(name: .long, help: "With --yes, rewrite a job file that differs from the rendering. Without it only a missing job file is written, because a hand-written file may hold what the declaration cannot yet say, such as a unit's OnFailure line.")
    var jobs = false

    @Flag(name: .long, help: "Print the report as one JSON document instead of the table.")
    var json = false

    @Flag(name: .long, help: "POST the report to pulse, with the roost node key.")
    var publish = false

    @Option(name: .long, help: "The pulse instance to publish to.")
    var pulse: String = "https://pulse.jimmyhoughjr.net"

    @Option(name: .long, help: "The file holding the pulse node key.")
    var keyFile: String = "~/.roost_node_key"

    func run() async throws {
        let requested = self.manifest.isEmpty ? [ManifestLocator.defaultName] : self.manifest
        let loaded = try requested.map { try ManifestLocator.load($0) }
        var plans = try InstallPlan.plans(in: loaded)
        if let host = self.host { plans = plans.filter { $0.host == host } }
        guard !plans.isEmpty else {
            print("  no host stack declares a job, so nothing is installed anywhere")
            return
        }
        let execute = ShellRunner.liveExecutor

        // Every host answers before anything is read, and before anything is written.
        var silent: [String] = []
        for plan in plans {
            guard let probe = plan.probe() else { continue }
            let answer = try? await execute(probe, nil)
            if answer == nil || answer?.status != 0 { silent.append(plan.host) }
        }
        if !silent.isEmpty {
            print("  silent: \(silent.joined(separator: ", ")); nothing was read and nothing was written")
            throw ExitCode.failure
        }

        var forgeMain: [String: String?] = [:]
        for tool in InstallPlan.tools(in: plans) {
            forgeMain[tool] = await InstallPlan.forgeMain(of: tool, execute: execute)
        }

        var rows: [InstallRow] = []
        var byHost: [(plan: InstallPlan, rows: [InstallRow])] = []
        for plan in plans {
            let output = try await execute(plan.command(plan.script()), nil)
            guard output.status == 0 else {
                print("  \(plan.host) refused the read: \(output.combined.trimmingCharacters(in: .whitespacesAndNewlines))")
                throw ExitCode.failure
            }
            let read = plan.rows(from: output.standardOutput, forgeMain: forgeMain)
            rows += read
            byHost.append((plan, read))
        }

        if self.json {
            print(String(decoding: try InstallReport(rows: rows).encoded(), as: UTF8.self))
        } else {
            InstallReport.lines(for: rows).forEach { print($0) }
            print("")
            let owed = rows.filter(\.needsInstall).count
            let dirty = rows.filter { $0.state == .dirty }.count
            print("  \(rows.count) thing(s) on \(plans.count) host(s), \(owed) to install" + (dirty > 0 ? ", \(dirty) dirty and left alone" : ""))
        }

        if self.yes {
            var failed = false
            for (plan, read) in byHost {
                for row in read where row.needsInstall {
                    if case .job = row.kind, row.state == .differs, !self.jobs {
                        print("  \(plan.host) \(row.name): the job file differs and stays; pass --jobs to rewrite it from the declaration")
                        continue
                    }
                    let steps = plan.steps(for: row, forgeMain: forgeMain)
                    guard !steps.isEmpty else {
                        print("  \(plan.host) \(row.name): nothing an install can do, a person places it first")
                        continue
                    }
                    let output = try await execute(plan.command(steps.joined(separator: " && ")), nil)
                    if output.status == 0 {
                        print("  \(plan.host) \(row.name): installed")
                    } else {
                        failed = true
                        print("  \(plan.host) \(row.name): failed, \(output.combined.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                }
            }
            // The report after the install is the one worth keeping.
            rows = []
            for (plan, _) in byHost {
                let output = try await execute(plan.command(plan.script()), nil)
                rows += plan.rows(from: output.standardOutput, forgeMain: forgeMain)
            }
            let left = rows.filter(\.needsInstall).count
            print("  after: \(left) thing(s) still to install")
            if failed { throw ExitCode.failure }
        }

        guard self.publish else { return }
        let key = try Declaration.nodeKey(at: self.keyFile)
        let data = try InstallReport(rows: rows).encoded()
        if let reason = await Declaration.publish(data, to: self.pulse, key: key, path: InstallReport.pulsePath) {
            FileHandle.standardError.write(Data("  publish: pulse did not take the report (\(reason))\n".utf8))
            throw ExitCode.failure
        }
        print("  published \(rows.count) row(s) to \(self.pulse)\(InstallReport.pulsePath)")
    }
}

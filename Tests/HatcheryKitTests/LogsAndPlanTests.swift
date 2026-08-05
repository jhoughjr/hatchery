import Foundation
import Testing

@testable import HatcheryKit

private let stack = StackSpec(
    name: "mwlab", backend: .dokku, host: "dokku@192.168.0.103",
    services: [
        ServiceSpec(name: "mwlab", kind: .mwserver, image: "i", configFile: "c.json")
    ])

private func service() -> ServiceSpec { stack.services[0] }

@Suite("Reading logs")
struct LogReaderTests {
    @Test("the command asks dokku for a bounded number of lines")
    func command() {
        #expect(
            LogReader.command(host: "dokku@h", app: "mwlab", lines: 200)
                == ["ssh", "-o", "BatchMode=yes", "dokku@h", "logs", "mwlab", "--num", "200"])
    }

    @Test("a request for more than the cap is clamped rather than passed through")
    func clampsLineCount() async throws {
        let seen = LockedBox<[String]>([])
        let reader = LogReader(run: { argv in
            seen.value = argv
            return Data()
        })
        _ = try await reader.logs(for: service(), in: stack, lines: 10_000)
        #expect(seen.value.last == String(LogReader.maximumLines))

        _ = try await reader.logs(for: service(), in: stack, lines: 0)
        #expect(seen.value.last == "1")
    }

    @Test("lines are classified by what they say about themselves")
    func classifies() {
        #expect(LogLine.classify("[ ERROR ] boom").level == .error)
        #expect(LogLine.classify("FATAL: gone").level == .error)
        #expect(LogLine.classify("[ WARNING ] careful").level == .warning)
        #expect(LogLine.classify("warn: careful").level == .warning)
        #expect(LogLine.classify("[ INFO ] fine").level == .info)
        #expect(LogLine.classify("just some text").level == .unknown)
    }

    @Test("colour codes are stripped, because a browser renders them as literal noise")
    func stripsANSI() {
        let raw = "\u{1B}[36m2026-08-05T15:31:17Z app[web.1]:\u{1B}[0m [ ERROR ] boom"
        let line = LogLine.classify(raw)
        #expect(!line.text.contains("\u{1B}"))
        #expect(!line.text.contains("[36m"))
        #expect(line.text.hasPrefix("2026-08-05"))
        // The bracketed app prefix is content, not colour, and must survive.
        #expect(line.text.contains("app[web.1]:"))
        #expect(line.level == .error)
    }

    @Test("a line with no escapes is returned untouched")
    func leavesPlainTextAlone() {
        #expect(LogLine.classify("plain line").text == "plain line")
    }

    @Test("blank lines at either end are trimmed, but the middle is left alone")
    func trimsEdges() async throws {
        let reader = LogReader(run: { _ in Data("\n\nfirst\n\nlast\n\n".utf8) })
        let lines = try await reader.logs(for: service(), in: stack)
        #expect(lines.map(\.text) == ["first", "", "last"])
    }

    @Test("a stack with no host is refused rather than shelling out to nothing")
    func requiresHost() async {
        var hostless = stack
        hostless.host = nil
        let reader = LogReader(run: { _ in Data() })
        await #expect(throws: LogError.noHost(stack: "mwlab")) {
            _ = try await reader.logs(for: service(), in: hostless)
        }
    }

    @Test("App Platform is refused rather than answered with dokku output")
    func refusesAppPlatform() async {
        var cloud = stack
        cloud.backend = .appPlatform
        let reader = LogReader(run: { _ in Data() })
        await #expect(throws: LogError.unsupportedBackend(.appPlatform)) {
            _ = try await reader.logs(for: service(), in: cloud)
        }
    }
}

/// A tiny mutable box, so a `@Sendable` closure can record what it saw.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite("Reading a plan")
struct PlanSummaryTests {
    private let sample = """
        OpenTofu will perform the following actions:

          # dokku_app.mwlab will be updated in-place
          ~ resource "dokku_app" "mwlab" {
              ~ deploy = {
                  ~ docker_image = "mwserver2:arm64-old" -> "mwserver2:arm64-new"
                }
            }

        Plan: 0 to add, 1 to change, 0 to destroy.
        """

    @Test("the summary counts are read from the line tofu prints them on")
    func readsCounts() {
        let summary = PlanSummary.parse(sample)
        #expect(summary.parsed)
        #expect(summary.add == 0)
        #expect(summary.change == 1)
        #expect(summary.destroy == 0)
        #expect(summary.headline == "0 to add, 1 to change, 0 to destroy")
    }

    @Test("a creation plan reads its own counts")
    func readsCreation() {
        let summary = PlanSummary.parse("Plan: 1 to add, 0 to change, 0 to destroy.")
        #expect(summary.add == 1)
        #expect(!summary.isEmpty)
    }

    @Test("change markers are classified, and a resource comment is a header")
    func classifiesLines() {
        let summary = PlanSummary.parse(sample)
        let kinds = Dictionary(grouping: summary.lines, by: \.kind).mapValues(\.count)
        #expect(kinds[.header, default: 0] >= 1)
        #expect(kinds[.change, default: 0] >= 2)
    }

    @Test("a rule or a bare dash is not mistaken for a destroy")
    func ignoresRules() {
        let summary = PlanSummary.parse("------\n--\n- \n+ real addition")
        let adds = summary.lines.filter { $0.kind == .add }
        let removes = summary.lines.filter { $0.kind == .remove }
        #expect(adds.count == 1)
        #expect(removes.isEmpty)
    }

    @Test("output with no summary line is still carried, so nothing is swallowed")
    func keepsUnparsedOutput() {
        let summary = PlanSummary.parse("Error: something went wrong\n  on main.tf line 3")
        #expect(!summary.parsed)
        #expect(summary.isEmpty)
        #expect(summary.lines.contains { $0.text.contains("something went wrong") })
        #expect(summary.headline == "plan output")
    }

    @Test("trailing blank lines are dropped but the text is otherwise untouched")
    func trimsTrailingBlanks() {
        let summary = PlanSummary.parse("one\ntwo\n\n\n")
        #expect(summary.lines.count == 2)
        #expect(summary.lines.last?.text == "two")
    }

    @Test("a no-change plan reports empty")
    func noChanges() {
        let summary = PlanSummary.parse("No changes. Your infrastructure matches the configuration.")
        #expect(summary.isEmpty)
    }
}

@Suite("Prerequisites")
struct PreflightTests {
    private func preflight(
        _ handler: @escaping @Sendable ([String]) -> CommandOutput
    ) -> Preflight {
        Preflight(execute: { argv, _ in handler(argv) })
    }

    private func allOK(_ argv: [String]) -> CommandOutput {
        if argv.first == "tofu" { return CommandOutput(status: 0, standardOutput: "OpenTofu v1.12.5") }
        if argv.contains("-V") { return CommandOutput(status: 0, standardOutput: "OpenSSH_10.2p1") }
        return CommandOutput(status: 0, standardOutput: "dokku version 0.38.19")
    }

    @Test("a healthy setup passes every check")
    func allPass() async {
        let checks = await preflight({ self.allOK($0) }).run(host: "dokku@h")
        #expect(checks.allPassed)
        #expect(checks.count == 4)
        #expect(checks.contains { $0.name == "dokku responds" && $0.status == .ok })
    }

    @Test("with no host the box checks are skipped rather than reported as passing")
    func skipsWithoutHost() async {
        let checks = await preflight({ self.allOK($0) }).run(host: nil)
        #expect(checks.filter { $0.status == .skipped }.count == 2)
        // Skipped is not failure — nothing is wrong, it just was not asked.
        #expect(checks.allPassed)
    }

    @Test("a missing tofu is reported with the command that installs it")
    func missingTofu() async {
        let checks = await preflight({ argv in
            argv.first == "tofu"
                ? CommandOutput(status: 127, standardOutput: "", standardError: "not found")
                : self.allOK(argv)
        }).run(host: "dokku@h")

        let tofu = checks.first { $0.name == "tofu installed" }
        #expect(tofu?.status == .failed)
        #expect(tofu?.remedy?.contains("opentofu") == true)
    }

    @Test("an unreachable box skips the dokku check instead of reporting a second failure")
    func unreachableSkipsDokku() async {
        let checks = await preflight({ argv in
            argv.first == "ssh" && !argv.contains("-V")
                ? CommandOutput(status: 255, standardOutput: "", standardError: "Operation timed out")
                : self.allOK(argv)
        }).run(host: "dokku@h")

        #expect(checks.first { $0.name == "box reachable" }?.status == .failed)
        // One cause, one failure. Reporting both would suggest two things to fix.
        #expect(checks.first { $0.name == "dokku responds" }?.status == .skipped)
        #expect(!checks.allPassed)
    }

    @Test("each common ssh failure maps to the thing to actually do about it")
    func remedies() {
        #expect(Preflight.remedy(for: "Permission denied (publickey)", host: "dokku@h")
            .contains("ssh-keys:add"))
        #expect(Preflight.remedy(for: "Could not resolve hostname", host: "dokku@h")
            .contains("does not resolve"))
        #expect(Preflight.remedy(for: "Operation timed out", host: "dokku@h")
            .contains("same network"))
        #expect(Preflight.remedy(for: "Connection refused", host: "dokku@h")
            .contains("port 22"))
        // Anything unrecognised still gets a next step rather than silence.
        #expect(!Preflight.remedy(for: "something odd", host: "dokku@h").isEmpty)
    }

    @Test("the ssh probe uses batch mode and a short timeout, so it fails fast")
    func sshFlags() {
        let argv = Preflight.sshCommand(host: "dokku@h", remote: ["version"])
        #expect(argv.contains("BatchMode=yes"))
        #expect(argv.contains("ConnectTimeout=5"))
        #expect(argv.last == "version")
    }
}

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

@Suite("Onboarding")
struct OnboardingTests {
    @Test("every step says where it runs and why it exists")
    func stepsAreComplete() {
        let steps = Onboarding.dokkuSteps
        #expect(!steps.isEmpty)
        for step in steps {
            #expect(!step.title.isEmpty)
            // The why is the point. A command with no reason is a command you cannot adapt.
            #expect(step.why.count > 40, "step '\(step.title)' does not explain itself")
            #expect(["box", "here"].contains(step.on))
            #expect(!step.commands.isEmpty)
        }
    }

    @Test("the guide covers the prerequisites doctor checks for")
    func coversWhatDoctorChecks() {
        let all = Onboarding.dokkuSteps
            .map { $0.title + " " + $0.why + " " + $0.commands.joined(separator: " ") }
            .joined(separator: "\n")
            .lowercased()

        // doctor reports these as failures; the guide has to say what to do about each.
        #expect(all.contains("dokku"))
        #expect(all.contains("ssh-keys:add"))
        #expect(all.contains("network"))
        #expect(all.contains("hatchery doctor"))
    }

    @Test("the dokku version is stated as a reference rather than silently pinned")
    func versionIsCalledOut() {
        let install = Onboarding.dokkuSteps.first { $0.title.contains("Install dokku") }
        #expect(install?.commands.contains { $0.contains(Onboarding.knownGoodDokku) } == true)
        // Saying where to check beats claiming this tag is current forever.
        #expect(install?.why.contains("dokku.com") == true)
    }

    @Test("the database step refuses to invent credentials, matching what the planner does")
    func databaseStepMatchesSecretPolicy() {
        // Matched on the whole phrase: the network step's title also ends "…need a database".
        let step = Onboarding.dokkuSteps.first { $0.title.contains("Provision the database") }
        #expect(step != nil)
        #expect(step?.why.contains("before the service does") == true)
    }
}

@Suite("The dokku SSH user")
struct DokkuSSHUserTests {
    @Test("a bare address gets the dokku user, because ssh would use the local login")
    func addsUser() {
        // `ssh 192.168.0.103` arrives as whoever is logged in here, fails on publickey, and
        // reads as a missing key rather than as the wrong account.
        #expect(DokkuProvider.sshTarget("192.168.0.103") == "dokku@192.168.0.103")
        #expect(DokkuProvider.sshTarget("opi.local") == "dokku@opi.local")
        #expect(DokkuProvider.sshTarget("  192.168.0.103  ") == "dokku@192.168.0.103")
    }

    @Test("a target that already names dokku is left alone")
    func keepsCorrectUser() {
        #expect(DokkuProvider.sshTarget("dokku@192.168.0.103") == "dokku@192.168.0.103")
    }

    @Test("a different user is not rewritten, because that would hide the mistake")
    func doesNotRewriteExplicitUser() {
        #expect(DokkuProvider.sshTarget("jimmyhoughjr@192.168.0.103") == "jimmyhoughjr@192.168.0.103")

        let warning = DokkuProvider.userWarning("jimmyhoughjr@192.168.0.103")
        #expect(warning?.contains("jimmyhoughjr") == true)
        #expect(warning?.contains("dokku@192.168.0.103") == true)
    }

    @Test("no warning for a correct or bare target")
    func warnsOnlyWhenWrong() {
        #expect(DokkuProvider.userWarning("dokku@h") == nil)
        #expect(DokkuProvider.userWarning("192.168.0.103") == nil)
        #expect(DokkuProvider.userWarning("") == nil)
    }

    @Test("an empty host stays empty rather than becoming dokku@")
    func emptyStaysEmpty() {
        #expect(DokkuProvider.sshTarget("") == "")
        #expect(DokkuProvider.sshTarget("   ") == "")
    }

    @Test("every command hatchery sends reaches the box as dokku")
    func everyCommandUsesTheDokkuUser() async throws {
        let seen = LockedBox<[[String]]>([])
        let record: @Sendable ([String]) async throws -> Data = { argv in
            seen.value = seen.value + [argv]
            return Data("true".utf8)
        }
        // A stack saved before this fix, holding a bare address.
        let bare = StackSpec(
            name: "lab", backend: .dokku, host: "192.168.0.103",
            services: [ServiceSpec(name: "app", kind: .mwserver, image: "i", configFile: "c.json")])
        let service = bare.services[0]

        _ = try? await LogReader(run: record).logs(for: service, in: bare)
        _ = await LifecycleRunner(run: record).perform(.restart, on: service, in: bare)
        _ = try? await LifecycleRunner(run: record).isRunning(service, in: bare)
        _ = try? await LiveConfigReader(run: record).config(for: service, in: bare)

        #expect(seen.value.count == 4)
        for argv in seen.value {
            #expect(argv.contains("dokku@192.168.0.103"), "a command went out as \(argv)")
            #expect(!argv.contains("192.168.0.103") || argv.contains("dokku@192.168.0.103"))
        }
    }

    @Test("a bare host is normalised into the manifest, not just at call time")
    func normalisesOnCreate() throws {
        let tool = StackBootstrapper(
            execute: { _, _ in CommandOutput(status: 0, standardOutput: "ok") },
            writeFile: { _, _ in }, fileExists: { _ in false }, createDirectory: { _ in },
            environment: [:])
        let result = try tool.plan(
            name: "lab", backend: .dokku, host: "192.168.0.103", tofuDir: "/infra/lab")

        #expect(result.stack.host == "dokku@192.168.0.103")
        #expect(result.stack.settings?["host"] == "dokku@192.168.0.103")
    }

    @Test("preflight blames the user rather than the key when the user is wrong")
    func preflightNamesTheRealCause() async {
        let checks = await Preflight(execute: { argv, _ in
            if argv.first == "tofu" { return CommandOutput(status: 0, standardOutput: "v1") }
            if argv.contains("-V") { return CommandOutput(status: 0, standardOutput: "OpenSSH") }
            return CommandOutput(
                status: 255, standardOutput: "",
                standardError: "jimmyhoughjr@192.168.0.103: Permission denied (publickey)")
        }).dokku(host: "jimmyhoughjr@192.168.0.103")

        let box = checks.first { $0.name == "box reachable" }
        #expect(box?.status == .failed)
        // The old advice sent people to authorize a key for the wrong account entirely.
        #expect(box?.remedy?.contains("not the dokku account") == true)
        #expect(box?.remedy?.contains("ssh-keys:add") != true)
    }
}

@Suite("Config completeness")
struct ConfigCompletenessTests {
    private let stack = StackSpec(
        name: "lab", backend: .dokku, host: "dokku@h",
        tofu: TofuBinding(directory: "/infra/lab"),
        services: [
            ServiceSpec(
                name: "svc", kind: .paymentGateway, image: "i", configFile: "svc.config.json")
        ])

    @Test("a config missing required keys is incomplete, and names them")
    func reportsMissing() {
        let status = ConfigCompleteness.check(
            service: stack.services[0], in: stack, manifestPath: "/infra/lab/hatchery.json",
            read: { _ in ["APP_URL": "http://x"] })

        #expect(!status.complete)
        #expect(status.missing.contains("DATABASE_PASSWORD"))
        #expect(status.summary?.contains("required keys missing") == true)
    }

    @Test("a complete config reports nothing to show")
    func completeIsSilent() {
        let contract = EnvContract.contract(for: .paymentGateway, backend: .dokku)!
        var full: [String: String] = [:]
        for key in contract.required { full[key] = "value" }

        let status = ConfigCompleteness.check(
            service: stack.services[0], in: stack, manifestPath: "/m.json", read: { _ in full })
        #expect(status.complete)
        #expect(status.summary == nil)
    }

    @Test("an empty value counts as missing, not as present")
    func emptyIsMissing() {
        let status = ConfigCompleteness.check(
            service: stack.services[0], in: stack, manifestPath: "/m.json",
            read: { _ in ["DATABASE_PASSWORD": ""] })
        #expect(status.missing.contains("DATABASE_PASSWORD"))
    }

    @Test("a config file that cannot be read is reported as absent rather than complete")
    func missingFileIsNotComplete() {
        let status = ConfigCompleteness.check(
            service: stack.services[0], in: stack, manifestPath: "/m.json",
            read: { _ in throw CocoaError(.fileNoSuchFile) })

        #expect(!status.found)
        #expect(!status.complete)
        #expect(status.summary == "no config file")
    }

    @Test("the browser is sent complete and summary, not left to recompute them")
    func encodesDerivedFields() throws {
        // Both are computed, and a computed property is not encoded by default — so the page
        // received neither and read every service as incomplete.
        let status = ConfigStatus(service: "s", missing: ["A"], unexpected: [], found: true)
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(status)) as? [String: Any]

        #expect(json?["complete"] as? Bool == false)
        #expect(json?["summary"] as? String == "1 required key missing")

        let ok = ConfigStatus(service: "s", missing: [], unexpected: [], found: true)
        let okJSON = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(ok)) as? [String: Any]
        #expect(okJSON?["complete"] as? Bool == true)
        // Nothing to say means the key is absent rather than an empty string.
        #expect(okJSON?["summary"] == nil)
    }

    @Test("singular and plural read correctly, because a dashboard shows this constantly")
    func summaryGrammar() {
        let one = ConfigStatus(service: "s", missing: ["A"], unexpected: [], found: true)
        let two = ConfigStatus(service: "s", missing: ["A", "B"], unexpected: [], found: true)
        #expect(one.summary == "1 required key missing")
        #expect(two.summary == "2 required keys missing")
    }
}

@Suite("Saved hosts")
struct HostRegistryTests {
    @Test("a reference resolves, and a literal target passes through untouched")
    func resolves() throws {
        let saved = ["opi": "dokku@192.168.0.103"]
        #expect(try HostRegistry.resolve("@opi", in: saved) == "dokku@192.168.0.103")
        // Nothing has to be saved before it can be used; the registry is a convenience.
        #expect(try HostRegistry.resolve("dokku@other", in: saved) == "dokku@other")
        #expect(try HostRegistry.resolve("", in: saved) == "")
    }

    @Test("an unknown reference lists what is saved rather than failing blankly")
    func unknownReference() {
        #expect(throws: HostError.unknown("nope", known: ["opi", "pi2"])) {
            _ = try HostRegistry.resolve("@nope", in: ["opi": "a", "pi2": "b"])
        }
    }

    @Test("hosts already in use are known even if nobody saved them")
    func includesHostsInUse() {
        let stacks = [
            StackSpec(name: "a", backend: .dokku, host: "dokku@192.168.0.103"),
            StackSpec(name: "b", backend: .dokku, host: "dokku@10.0.0.9"),
        ]
        let known = HostRegistry.known(saved: ["opi": "dokku@192.168.0.103"], stacks: stacks)

        #expect(known.count == 2)
        // The saved one keeps its name; the other is listed without one rather than omitted.
        #expect(known.first?.name == "opi")
        #expect(known.contains { $0.name == nil && $0.target == "dokku@10.0.0.9" })
    }

    @Test("saving and forgetting round-trips through the manifest")
    func savesAndForgets() throws {
        let manifest = StackManifest()
        let saved = try manifest.savingHost("opi", target: "dokku@192.168.0.103")
        #expect(saved.savedHosts["opi"] == "dokku@192.168.0.103")

        let decoded = try StackManifest.decode(from: try saved.encoded())
        #expect(decoded.savedHosts["opi"] == "dokku@192.168.0.103")

        #expect(try saved.removingHost("opi").savedHosts.isEmpty)
        #expect(throws: HostError.self) { _ = try manifest.removingHost("ghost") }
    }

    @Test("a name that would not round-trip is refused")
    func rejectsBadNames() {
        #expect(!HostRegistry.isValidName(""))
        #expect(!HostRegistry.isValidName("has space"))
        #expect(HostRegistry.isValidName("opi-2"))
        #expect(throws: HostError.invalidName("has space")) {
            _ = try StackManifest().savingHost("has space", target: "dokku@h")
        }
    }
}

@Suite("Tearing a stack down")
struct DestroyTests {
    @Test("the destroy plan is asked for with -destroy, not inferred")
    func destroyPlanCommand() {
        #expect(Deployer.destroyPlanCommand().contains("-destroy"))
        #expect(Deployer.destroyCommand() == ["tofu", "destroy", "-auto-approve", "-no-color", "-input=false"])
    }

    @Test("removing a stack leaves the others alone")
    func removesOnlyTheNamed() {
        let manifest = StackManifest(stacks: [
            StackSpec(name: "a", backend: .dokku, host: "h"),
            StackSpec(name: "b", backend: .dokku, host: "h"),
        ])
        let after = manifest.removing(stack: "a")
        #expect(after.stacks.map(\.name) == ["b"])
        // Removing something absent is not an error; the end state is what was asked for.
        #expect(after.removing(stack: "ghost").stacks.count == 1)
    }
}

@Suite("Hosts roost advertises")
struct RoostHostsTests {
    private let rc = """
        # roost config
        ROOST_DOKKU_HOST=dokku@192.168.0.103
        ROOST_DOMAIN=jimmyhoughjr.net
        ROOST_STATUS_SITE=/Users/x/status-site
        """

    @Test("only the host-shaped variables are taken, not every setting")
    func readsOnlyHosts() {
        let hosts = RoostHosts.hosts(read: { _ in rc })
        #expect(hosts.count == 1)
        #expect(hosts.first?.target == "dokku@192.168.0.103")
        // A domain and a path are not places to ssh to.
        #expect(!hosts.contains { $0.target.contains("jimmyhoughjr.net") })
    }

    @Test("the file is read rather than sourced")
    func doesNotExecute() {
        // Sourcing an rc file to learn one variable would run whatever else is in it.
        let hostile = "ROOST_DOKKU_HOST=dokku@h\nrm -rf /\n"
        #expect(RoostHosts.hosts(read: { _ in hostile }).first?.target == "dokku@h")
    }

    @Test("placeholders and unexpanded variables are skipped")
    func skipsPlaceholders() {
        #expect(RoostHosts.hosts(read: { _ in "ROOST_DOKKU_HOST=dokku@YOUR_HOST_IP" }).isEmpty)
        #expect(RoostHosts.hosts(read: { _ in "ROOST_DOKKU_HOST=$SOMETHING" }).isEmpty)
        #expect(RoostHosts.hosts(read: { _ in "ROOST_DOKKU_HOST=" }).isEmpty)
    }

    @Test("no roostrc is not an error; hatchery works without roost")
    func absentFileIsFine() {
        #expect(RoostHosts.hosts(read: { _ in throw CocoaError(.fileNoSuchFile) }).isEmpty)
    }

    @Test("an advertised host appears in the list, named for where it came from")
    func appearsInKnownHosts() {
        let known = HostRegistry.known(
            saved: [:], stacks: [],
            advertised: [(name: "roost dokku host", target: "dokku@10.0.0.5")])
        #expect(known.count == 1)
        #expect(known.first?.name == "roost dokku host")
    }

    @Test("a host already saved or in use is not listed twice")
    func dedupesAgainstWhatIsKnown() {
        let known = HostRegistry.known(
            saved: ["opi": "dokku@192.168.0.103"],
            stacks: [StackSpec(name: "a", backend: .dokku, host: "dokku@192.168.0.103")],
            advertised: [(name: "roost dokku host", target: "dokku@192.168.0.103")])

        #expect(known.count == 1)
        // The name someone chose wins over the one derived from roost's variable.
        #expect(known.first?.name == "opi")
    }
}

import Foundation
import Testing

@testable import HatcheryKit

private func job(_ program: [String], label: String? = nil) -> JobSpec {
    var job = JobSpec(program: program)
    job.label = label
    return job
}

@Suite("What a declared program names")
struct InstallClassifyTests {
    @Test("a script under repos names its checkout, and an interpreter's script is the thing")
    func checkoutFromRepos() {
        let plain = InstallPlan.classify("/Users/jimmyhoughjr/repos/roost/bin/node-report.sh", platform: .darwin, roost: "x")
        #expect(plain == [.checkout(name: "roost", root: "/Users/jimmyhoughjr/repos/roost")])

        let script = InstallPlan.program(of: job(["/usr/bin/python3", "/Users/jimmyhoughjr/repos/docs/bin/usage-report.py"]))
        #expect(script == "/Users/jimmyhoughjr/repos/docs/bin/usage-report.py")
        #expect(InstallPlan.program(of: job(["/usr/bin/python3", "-m", "http.server"])) == nil)
    }

    @Test("the hatchery binary names itself and the checkout it is built from")
    func binary() {
        let things = InstallPlan.classify("/Users/jimmyhoughjr/.local/bin/hatchery", platform: .darwin, roost: "x")
        #expect(
            things == [
                .checkout(name: "hatchery", root: "/Users/jimmyhoughjr/repos/hatchery"),
                .binary(tool: "hatchery", path: "/Users/jimmyhoughjr/.local/bin/hatchery", checkout: "/Users/jimmyhoughjr/repos/hatchery"),
            ])
    }

    @Test("a copy under opt names the roost checkout it came from and its installer, with the home as the host's")
    func copy() {
        let things = InstallPlan.classify("%h/opt/dokku-reconcile/dokku-reconcile.sh", platform: .linux, roost: "/home/jimmy/roost")
        #expect(
            things == [
                .checkout(name: "roost", root: "/home/jimmy/roost"),
                .copy(
                    destination: "$HOME/opt/dokku-reconcile/dokku-reconcile.sh",
                    source: "/home/jimmy/roost/bin/dokku-reconcile.sh",
                    installer: "/home/jimmy/roost/bin/install-dokku-reconcile.sh"),
            ])
    }

    @Test("a checkout directly under a home is known by its tool's name, and a stranger's program names nothing")
    func homeCheckout() {
        #expect(InstallPlan.checkout(in: "/home/jimmy/roost/bin/tapo-poll.py") == .checkout(name: "roost", root: "/home/jimmy/roost"))
        #expect(InstallPlan.classify("/opt/homebrew/bin/node", platform: .darwin, roost: "x").isEmpty)
        #expect(InstallPlan.classify("/Users/jimmyhoughjr/watts-site/monthly-refresh.sh", platform: .darwin, roost: "x").isEmpty)
    }
}

@Suite("The rows a host's facts make")
struct InstallRowsTests {
    private let plan = InstallPlan(
        host: "jimmy@opi",
        platform: .linux,
        things: [
            .checkout(name: "roost", root: "/home/jimmy/roost"),
            .binary(tool: "hatchery", path: "/home/jimmy/.local/bin/hatchery", checkout: "/home/jimmy/repos/hatchery"),
            .copy(destination: "$HOME/opt/r/r.sh", source: "/home/jimmy/roost/bin/r.sh", installer: "/home/jimmy/roost/bin/install-r.sh"),
            .job(label: "roost-node-report", file: ".config/systemd/user/roost-node-report.service"),
        ],
        rendered: [".config/systemd/user/roost-node-report.service": "[Unit]\n"])

    @Test("a checkout behind the forge's main, a binary with no sha, a stale copy and a level job")
    func states() {
        let output = """
            checkout\t/home/jimmy/roost\t876998f000000000000000000000000000000000\t0\tf065074000000000000000000000000000000000
            binary\t/home/jimmy/.local/bin/hatchery\tunknown
            copy\t$HOME/opt/r/r.sh\t676807740da1\t5e127985e63a
            job\t.config/systemd/user/roost-node-report.service\tabc123abc123\tabc123abc123
            """
        let rows = plan.rows(from: output, forgeMain: ["roost": "ab5fed7000000000000000000000000000000000", "hatchery": "2313a8f000000000000000000000000000000000"])

        #expect(rows.map(\.state) == [.behind, .unknown, .differs, .level])
        #expect(rows[0].installed == "876998f")
        #expect(rows[0].wanted == "ab5fed7")
        #expect(rows[1].installed == nil)
        #expect(rows.filter(\.needsInstall).count == 2)
    }

    @Test("the forge's main is what a checkout should hold, and its origin only when the forge has no such repo")
    func forgeOverOrigin() {
        let output = "checkout\t/home/jimmy/roost\tf065074000000000000000000000000000000000\t0\tf065074000000000000000000000000000000000\n"
        #expect(plan.rows(from: output, forgeMain: ["roost": "ab5fed7000000000000000000000000000000000"])[0].state == .behind)
        #expect(plan.rows(from: output, forgeMain: ["roost": nil])[0].state == .level)
        #expect(plan.rows(from: output, forgeMain: [:])[0].state == .level)
    }

    @Test("a checkout that holds the forge's main and more is ahead, and the forge is what wants a push")
    func ahead() {
        let output = "checkout\t/home/jimmy/roost\tf065074000000000000000000000000000000000\t0\t\nahead\t/home/jimmy/roost\tyes\n"
        let forge = ["roost": "ab5fed7000000000000000000000000000000000"] as [String: String?]
        let rows = plan.rows(from: output, forgeMain: forge)

        #expect(rows[0].state == .ahead)
        #expect(rows[0].needsInstall == false)
        #expect(plan.script(forgeMain: forge).contains("merge-base --is-ancestor ab5fed7000000000000000000000000000000000 HEAD"))
        #expect(!plan.script().contains("merge-base"))
    }

    @Test("a dirty checkout and a missing thing are named, and neither is installed over")
    func dirtyAndMissing() {
        let output = """
            checkout\t/home/jimmy/roost\tf065074000000000000000000000000000000000\t3\t
            binary\t/home/jimmy/.local/bin/hatchery\tmissing
            copy\t$HOME/opt/r/r.sh\tmissing\t5e127985e63a
            job\t.config/systemd/user/roost-node-report.service\tmissing\tabc123abc123
            """
        let rows = plan.rows(from: output, forgeMain: ["roost": "ab5fed7000000000000000000000000000000000", "hatchery": "2313a8f000000000000000000000000000000000"])

        #expect(rows.map(\.state) == [.dirty, .missing, .missing, .missing])
        #expect(plan.steps(for: rows[0], forgeMain: [:]).isEmpty)
        // A missing binary is built from its checkout; a missing copy is placed; a missing job file is written.
        #expect(plan.steps(for: rows[1], forgeMain: [:]).first?.contains("bin/install") == true)
        #expect(plan.steps(for: rows[2], forgeMain: [:]).first?.contains("install-r.sh") == true)
        let jobSteps = plan.steps(for: rows[3], forgeMain: [:])
        #expect(jobSteps.count == 3)
        #expect(jobSteps[0].contains("base64 --decode > \"$HOME/.config/systemd/user/roost-node-report.service\""))
        #expect(jobSteps[2] == "systemctl --user enable --now roost-node-report.service")
    }

    @Test("a checkout behind the forge fetches the forge by URL and fast-forwards, and pulls its origin when the forge has none")
    func checkoutSteps() {
        let behind = InstallRow(host: "h", kind: .checkout(name: "roost", root: "/home/jimmy/roost"), installed: "a", wanted: "b", state: .behind)
        #expect(
            plan.steps(for: behind, forgeMain: ["roost": "b"]) == [
                "git -C \"/home/jimmy/roost\" fetch -q https://forgejo.jimmyhoughjr.net/jimmy/roost.git main && git -C \"/home/jimmy/roost\" merge -q --ff-only FETCH_HEAD"
            ])
        #expect(plan.steps(for: behind, forgeMain: ["roost": nil]) == ["git -C \"/home/jimmy/roost\" pull -q --ff-only"])
    }

    @Test("the host's script asks once for every thing, hashes the rendered job file on the host, and a Mac's job restarts through launchd")
    func scriptAndDarwin() {
        let script = plan.script()
        #expect(script.contains("git -C \"/home/jimmy/roost\" rev-parse HEAD"))
        #expect(script.contains("cat \"/home/jimmy/.local/bin/hatchery.sha\""))
        #expect(script.contains("base64 --decode | c - | h"))
        #expect(script.contains("sed -e"))
        #expect(!script.contains("plutil"))
        #expect(plan.command("x") == ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "jimmy@opi", "x"])
        #expect(plan.probe() != nil)

        let mac = InstallPlan(host: "local", platform: .darwin, things: [.job(label: "l", file: "Library/LaunchAgents/l.plist")], rendered: ["Library/LaunchAgents/l.plist": "<plist/>"])
        let row = InstallRow(host: "local", kind: .job(label: "l", file: "Library/LaunchAgents/l.plist"), installed: "x", wanted: "y", state: .differs)
        #expect(mac.script().contains("plutil -convert xml1"))
        let steps = mac.steps(for: row, forgeMain: [:])
        #expect(steps[1] == "launchctl bootout gui/$(id -u)/l >/dev/null 2>&1 || true")
        #expect(steps[2] == "launchctl bootstrap gui/$(id -u) \"$HOME/Library/LaunchAgents/l.plist\"")
        #expect(mac.command("x") == ["sh", "-c", "x"])
        #expect(mac.probe() == nil)
    }

    @Test("a kept-alive job restarts when its checkout moves, and a job from another checkout does not")
    func restartsAfterCheckout() {
        let linux = InstallPlan(host: "jimmy@opi", platform: .linux, things: [], rendered: [:],
                                longRunning: ["box-watch": "/home/jimmy/roost/bin/box-watch.py", "other": "/home/jimmy/elsewhere/run.sh"])
        let steps = linux.restartSteps(afterCheckout: "/home/jimmy/roost")
        #expect(steps.map(\.label) == ["box-watch"])
        #expect(steps.first?.step == "systemctl --user restart box-watch.service")
        let mac = InstallPlan(host: "local", platform: .darwin, things: [], rendered: [:], longRunning: ["net.x.watch": "/Users/j/repos/roost/bin/box-watch.py"])
        #expect(mac.restartSteps(afterCheckout: "/Users/j/repos/roost").first?.step == "launchctl kickstart -k gui/$(id -u)/net.x.watch")
        #expect(mac.restartSteps(afterCheckout: "/Users/j/repos/hatchery").isEmpty)
    }

    @Test("the report groups rows by host and reads back whole")
    func report() throws {
        let rows = [
            InstallRow(host: "a", kind: .checkout(name: "roost", root: "/r"), installed: "1", wanted: "2", state: .behind),
            InstallRow(host: "b", kind: .job(label: "j", file: "Library/LaunchAgents/j.plist"), installed: nil, wanted: "x", state: .missing),
        ]
        let report = InstallReport(rows: rows)
        let back = try JSONDecoder().decode(InstallReport.self, from: try report.encoded())
        #expect(back == report)
        #expect(back.hosts.map(\.host) == ["a", "b"])
        #expect(back.hosts[1].rows[0].path == "$HOME/Library/LaunchAgents/j.plist")
        #expect(InstallReport.lines(for: rows).contains { $0.contains("roost") && $0.contains("behind") })
    }
}

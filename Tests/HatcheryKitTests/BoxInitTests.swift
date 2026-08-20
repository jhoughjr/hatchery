import Foundation
import Testing

@testable import HatcheryKit

@Suite("Asserting a box into readiness")
struct BoxInitTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var satisfied: Set<String>
        private var log: [String] = []
        private let fixesWork: Bool

        init(satisfied: Set<String>, fixesWork: Bool = true) {
            self.satisfied = satisfied
            self.fixesWork = fixesWork
        }

        func handle(_ argv: [String]) -> CommandOutput {
            let command = argv.last ?? ""
            lock.lock()
            defer { lock.unlock() }
            log.append(command)
            // Checks are recognised by content; a fix marks its assertion satisfied.
            if command.contains("command -v dokku") {
                return CommandOutput(status: satisfied.contains("dokku") ? 0 : 1, standardOutput: "")
            }
            if command.contains("bootstrap.sh"), command.contains("DOKKU_TAG") {
                if fixesWork { satisfied.insert("dokku") }
                return CommandOutput(status: fixesWork ? 0 : 1, standardOutput: "", standardError: "boom")
            }
            if command.contains("ssh-keys:list") {
                return CommandOutput(status: satisfied.contains("key") ? 0 : 1, standardOutput: "")
            }
            if command.contains("ssh-keys:add") {
                satisfied.insert("key")
                return CommandOutput(status: 0, standardOutput: "")
            }
            if command.contains("network:list") || command.contains("network inspect") {
                return CommandOutput(status: satisfied.contains("net") ? 0 : 1, standardOutput: "")
            }
            if command.contains("network:create") {
                satisfied.insert("net")
                return CommandOutput(status: 0, standardOutput: "")
            }
            // Reachability, apt, root: facts of the fake box.
            return CommandOutput(status: 0, standardOutput: "")
        }

        var commands: [String] {
            lock.lock()
            defer { lock.unlock() }
            return log
        }
    }

    private func initializer(_ box: Box) -> BoxInitializer {
        BoxInitializer(execute: { argv, _ in box.handle(argv) })
    }

    @Test("an empty box gets every fix, in order, and ends ready")
    func emptyBoxGetsFixed() async {
        let box = Box(satisfied: [])
        let steps = await initializer(box).run(
            host: "root@newbox",
            assertions: BoxInitializer.dokkuAssertions(operatorKey: "ssh-ed25519 AAAA key"),
            onProgress: { _ in })

        #expect(steps.count == 6)
        #expect(steps.allSatisfy { $0.outcome != .failed })
        #expect(steps.filter { $0.outcome == .fixed }.map(\.name).count == 3)
        // The bootstrap ran with the pinned version, and the key landed.
        #expect(box.commands.contains { $0.contains("DOKKU_TAG=v0.38.19") })
        #expect(box.commands.contains { $0.contains("ssh-keys:add hatchery-operator") })
    }

    @Test("a prepared box holds every assertion and nothing is fixed")
    func preparedBoxHolds() async {
        let box = Box(satisfied: ["dokku", "key", "net"])
        let steps = await initializer(box).run(
            host: "root@box",
            assertions: BoxInitializer.dokkuAssertions(operatorKey: "k"),
            onProgress: { _ in })

        #expect(steps.allSatisfy { $0.outcome == .held })
        #expect(!box.commands.contains { $0.contains("bootstrap.sh") })
    }

    @Test("a failed fix stops the run and names the remedy")
    func failedFixStops() async {
        let box = Box(satisfied: [], fixesWork: false)
        let steps = await initializer(box).run(
            host: "root@box",
            assertions: BoxInitializer.dokkuAssertions(operatorKey: "k"),
            onProgress: { _ in })

        let failed = steps.filter { $0.outcome == .failed }
        #expect(failed.count == 1)
        #expect(failed.first?.name.contains("dokku") == true)
        #expect(failed.first?.detail.contains("bootstrap") == true)
        // Nothing after the failure ran: the key and network steps depend on dokku.
        #expect(!box.commands.contains { $0.contains("ssh-keys:add") })
    }

    @Test("every remote command travels as one quoted sh -c through BatchMode ssh")
    func commandShape() async {
        let recorded = RecordedArgv()
        let initializer = BoxInitializer(execute: { argv, _ in
            recorded.note(argv)
            return CommandOutput(status: 0, standardOutput: "")
        })
        _ = await initializer.run(
            host: "root@box",
            assertions: [BoxAssertion(name: "x", check: "true")],
            onProgress: { _ in })

        let argv = recorded.all.first ?? []
        #expect(Array(argv.prefix(3)) == ["ssh", "-o", "BatchMode=yes"])
        #expect(argv.contains("root@box"))
        #expect(argv.contains("sh"))
    }

    @Test("a local command is a bare sh -c with no ssh in front")
    func localCommandShape() async {
        let recorded = RecordedArgv()
        let initializer = BoxInitializer(execute: { argv, _ in
            recorded.note(argv)
            return CommandOutput(status: 0, standardOutput: "")
        })
        _ = await initializer.run(
            at: .local,
            assertions: [BoxAssertion(name: "x", check: "true")],
            onProgress: { _ in })

        #expect(recorded.all.first == ["sh", "-c", "true"])
    }

    @Test("the App Platform recipe is check-only and names the cluster it was given")
    func appPlatformRecipeShape() {
        let anyCluster = BoxInitializer.appPlatformAssertions()
        #expect(anyCluster.allSatisfy { $0.fix.isEmpty })
        #expect(anyCluster.map(\.name).contains("DIGITALOCEAN_TOKEN is set"))
        #expect(anyCluster.last?.check.contains("\"pg\"") == true)

        let named = BoxInitializer.appPlatformAssertions(cluster: "mws-pg")
        #expect(named.last?.name == "managed Postgres cluster 'mws-pg' is visible")
        #expect(named.last?.check.contains("mws-pg") == true)
        #expect(named.last?.remedy.contains("mws-pg") == true)
    }

    @Test("a missing token stops the platform run at the token step and says the export")
    func missingTokenStops() async {
        let initializer = BoxInitializer(execute: { argv, _ in
            let command = argv.last ?? ""
            // curl is present. The token is not, so the token check and anything after fail.
            let status = command.contains("command -v curl") ? 0 : 1
            return CommandOutput(status: Int32(status), standardOutput: "")
        })
        let steps = await initializer.run(
            at: .local,
            assertions: BoxInitializer.appPlatformAssertions(),
            onProgress: { _ in })

        #expect(steps.map(\.outcome) == [.held, .failed])
        #expect(steps.last?.name == "DIGITALOCEAN_TOKEN is set")
        #expect(steps.last?.detail.contains("export DIGITALOCEAN_TOKEN") == true)
    }

    private final class RecordedArgv: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [[String]] = []
        func note(_ argv: [String]) {
            lock.lock()
            log.append(argv)
            lock.unlock()
        }
        var all: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return log
        }
    }
}

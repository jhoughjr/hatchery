import Foundation
import Testing

@testable import HatcheryKit

private func stack(
    settings: [String: String]? = nil, backend: Backend = .dokku
) -> StackSpec {
    StackSpec(
        name: "mwlab-2", backend: backend, environment: .staging,
        host: "dokku@192.168.0.103", tofu: TofuBinding(directory: "/infra/mwlab-2"),
        settings: settings,
        services: [
            ServiceSpec(
                name: "mwlab-2", kind: .mwserver, image: "img", domains: ["mwlab-2.opi"],
                configFile: "mwlab-2.config.json")
        ])
}

@Suite("Choosing and planning exposure")
struct ExposureTests {
    @Test("a dokku stack with no choice honestly resolves nowhere")
    func defaultsToNone() async {
        let provider = Exposure.provider(for: stack())
        #expect(provider.name == "none")
        let plans = await provider.plan(domains: ["mwlab-2.opi"], stack: stack())
        #expect(plans.allSatisfy { !$0.actionable })
    }

    @Test("a platform backend routes its own domains")
    func platformActs() async {
        let spec = stack(backend: .appPlatform)
        let provider = Exposure.provider(for: spec)
        #expect(provider.name == "platform")
        let plans = await provider.plan(domains: ["x.example"], stack: spec)
        #expect(plans.allSatisfy { $0.actionable })
    }

    @Test("cloudflare-local is actionable only with an admin channel, falling back to db_admin")
    func cloudflareNeedsAdmin() async {
        let bare = stack(settings: ["exposure": "cloudflare-local"])
        let barePlans = await Exposure.provider(for: bare)
            .plan(domains: ["mwlab-2.jimmyhoughjr.net"], stack: bare)
        #expect(barePlans.allSatisfy { !$0.actionable })
        #expect(barePlans.first?.action.contains("exposure_admin") == true)

        let granted = stack(
            settings: ["exposure": "cloudflare-local", "db_admin": "jimmy@opi.local"])
        let plans = await Exposure.provider(for: granted)
            .plan(domains: ["mwlab-2.jimmyhoughjr.net"], stack: granted)
        #expect(plans.allSatisfy { $0.actionable })
        #expect(plans.first?.action.contains("jimmy@opi.local") == true)
    }
}

@Suite("Speaking the wrapper's three verbs")
struct CloudflareLocalTests {
    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []
        private var lines: [String] = []
        func record(_ argv: [String]) {
            lock.lock()
            commands.append(argv)
            lock.unlock()
        }
        func note(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        var all: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }
        var narration: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    @Test("expose runs the wrapper once per domain, through ssh and sudo, and narrates")
    func exposeSpeaksAdd() async {
        let recorded = Recorded()
        let provider = CloudflareLocalExposure(run: { argv in
            recorded.record(argv)
            return Data("ingress now carries \(argv.last ?? "")\ndns routed\n".utf8)
        })
        let spec = stack(
            settings: ["exposure": "cloudflare-local", "db_admin": "jimmy@opi.local"])

        await provider.expose(
            domains: ["mwlab-2.opi", "mwlab-2.jimmyhoughjr.net"], stack: spec,
            onProgress: { recorded.note($0) })

        #expect(recorded.all.count == 2)
        for command in recorded.all {
            #expect(Array(command.prefix(4)) == ["ssh", "-o", "BatchMode=yes", "jimmy@opi.local"])
            #expect(command.contains("sudo"))
            #expect(command.contains("/usr/local/bin/hatchery-expose"))
            #expect(command.contains("add"))
        }
        #expect(recorded.narration.contains { $0.contains("dns routed") })
    }

    @Test("a refused grant narrates the fix instead of failing the job")
    func failureNamesTheGrant() async {
        let provider = CloudflareLocalExposure(run: { _ in
            throw CommandFailure(command: "ssh", status: 1, message: "sudo: a password is required")
        })
        let spec = stack(
            settings: ["exposure": "cloudflare-local", "db_admin": "jimmy@opi.local"])
        let recorded = Recorded()

        await provider.withdraw(
            domains: ["mwlab-2.opi"], stack: spec, onProgress: { recorded.note($0) })

        #expect(recorded.narration.count == 1)
        #expect(recorded.narration.first?.contains("could not remove") == true)
        #expect(recorded.narration.first?.contains("sudoers") == true)
    }
}

import Foundation
import Testing

@testable import HatcheryKit

/// The boot order: which dokku apps come up after which, asserted at boot.
///
/// Jimmy ruled on 2026-09-15 that a box must not deadlock itself after a reset, and that the order is declared and asserted, not repaired by hand.
@Suite("The boot order")
struct BootOrderTests {
    private let vault = BootOrder.App(name: "vault", domains: ["vault.example", "s3.example"], expectedStatus: "301")
    private let rookery = BootOrder.App(name: "rookery", domains: ["rookery.example"], expectedStatus: "302", after: ["vault"])
    private let forgejo = BootOrder.App(name: "forgejo", domains: ["forgejo.example"], after: ["vault"])
    private let blog = BootOrder.App(name: "blog", domains: ["blog.example"])

    @Test("An app comes after everything it names, and an app outside every order is left out")
    func dependenciesComeFirst() throws {
        let ordered = try BootOrder.ordered([self.rookery, self.blog, self.forgejo, self.vault])

        #expect(ordered.map(\.name) == ["vault", "forgejo", "rookery"])
    }

    @Test("An after list that names nothing declared is refused")
    func unknownIsRefused() {
        #expect(throws: BootOrder.Failure.unknown(service: "rookery", after: "vault")) {
            try BootOrder.ordered([self.rookery])
        }
    }

    @Test("After lists that loop are refused")
    func cycleIsRefused() {
        let a = BootOrder.App(name: "a", domains: [], after: ["b"])
        let b = BootOrder.App(name: "b", domains: [], after: ["a"])

        #expect(throws: BootOrder.Failure.cycle(["a", "b", "a"])) {
            try BootOrder.ordered([a, b])
        }
    }

    @Test("A manifest's after list is read, and a manifest without one still reads")
    func manifestCarriesAfter() throws {
        let json = #"""
        {"version": 1, "stacks": [{"name": "estate", "backend": "dokku", "host": "dokku@box", "services": [
          {"name": "vault", "kind": "vault", "image": "dokku/vault:latest", "domains": ["vault.example"], "configFile": "v.json"},
          {"name": "rookery", "kind": "rookery", "image": "dokku/rookery:latest", "domains": ["rookery.example"], "configFile": "r.json", "after": ["vault"]}
        ]}]}
        """#
        let manifest = try StackManifest.decode(from: Data(json.utf8))

        let apps = BootOrder.apps(from: [manifest])

        #expect(apps.first { $0.name == "rookery" }?.after == ["vault"])
        #expect(apps.first { $0.name == "vault" }?.after == [])
    }

    @Test("An app's assertion starts it, rebuilds its proxy and waits for it, through local dokku")
    func assertionFixesInOrder() throws {
        let assertions = BootOrder.assertions(for: try BootOrder.ordered([self.vault, self.rookery]))

        #expect(assertions.map(\.name) == ["vault is serving", "rookery is serving after vault"])
        #expect(assertions[1].fix[0] == "ssh -o BatchMode=yes dokku@localhost ps:start rookery || true")
        #expect(assertions[1].fix[1] == "ssh -o BatchMode=yes dokku@localhost proxy:build-config rookery")
        #expect(assertions[1].fix[2].contains("sleep 5"))
    }

    @Test("A redirect on port 80 is not enough, because nginx answers it while the app behind it is down")
    func redirectChecksTLS() {
        let check = BootOrder.serving(self.vault)

        #expect(check.contains("-H 'Host: vault.example' http://127.0.0.1/"))
        #expect(check.contains("-H 'Host: s3.example' http://127.0.0.1/"))
        #expect(check.contains("--resolve 'vault.example:443:127.0.0.1'"))
        #expect(check.contains("000|5??) exit 1"))
    }

    @Test("The rendered script holds, fixes and stops the way the runner does, under a real shell")
    func scriptRunsUnderSh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boot-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let flag = directory.appendingPathComponent("started").path
        let assertions = [
            BoxAssertion(name: "holds", check: "true", fix: ["exit 1"]),
            BoxAssertion(name: "gets fixed", check: "[ -f '\(flag)' ]", fix: ["touch '\(flag)'"]),
            BoxAssertion(name: "cannot be fixed", check: "false", fix: ["true"], remedy: "read the logs"),
            BoxAssertion(name: "never reached", check: "true"),
        ]
        let path = directory.appendingPathComponent("boot-order.sh")
        try BootOrder.script(assertions).write(to: path, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 1)
        #expect(output == "hold   holds\nfixed  gets fixed\nFAILED cannot be fixed - read the logs\n")
    }

    @Test("Installing writes each file only when its checksum differs, and enables the unit")
    func installIsConvergent() {
        let script = BootOrder.script(BootOrder.assertions(for: [self.vault]))

        let install = BootOrder.installAssertions(script: script)

        #expect(install.map(\.name).contains("the boot order unit is enabled"))
        #expect(install[1].check.contains(SHA256.hex(script)))
        #expect(install[1].fix[0].contains(Data(script.utf8).base64EncodedString()))
        #expect(BootOrder.unit().contains("Restart=on-failure"))
    }
}

import Foundation
import Testing

@testable import HatcheryKit

@Suite("Knowing when apply would change the running code")
struct ImageDriftTests {
    private func stack(settings: [String: String]? = nil) -> StackSpec {
        StackSpec(
            name: "mwlab-2", backend: .dokku, environment: .staging,
            host: "dokku@192.168.0.103", settings: settings,
            services: [
                ServiceSpec(
                    name: "mwlab-2", kind: .mwserver, image: "mhehmsoth/mwserver2:tag",
                    domains: ["mwlab-2.opi"], configFile: "c.json")
            ])
    }

    /// A fake box: answers by what the command asks for.
    private func drift(
        localDigest: String = "img@sha256:aaa",
        derivedCreated: String = "2026-08-09T10:00:00Z",
        tagCreated: String = "2026-08-01T10:00:00Z",
        registryDigest: String? = "sha256:aaa"
    ) -> ImageDrift {
        ImageDrift(run: { argv in
            let joined = argv.joined(separator: " ")
            if joined.contains("hatchery-inspect") {
                guard let registryDigest else {
                    throw CommandFailure(command: "ssh", status: 1, message: "sudo refused")
                }
                return Data(registryDigest.utf8)
            }
            if joined.contains("RepoDigests") { return Data(localDigest.utf8) }
            if joined.contains(".web.1") { return Data(derivedCreated.utf8) }
            return Data(tagCreated.utf8)
        })
    }

    private let granted = [
        "exposure": "cloudflare-local", "db_admin": "jimmy@opi.local",
    ]

    @Test("everything in sync says nothing")
    func inSyncIsSilent() async {
        let lines = await drift().check(stack: stack(settings: granted))
        #expect(lines.isEmpty)
    }

    @Test("a registry that moved past the box names the deploy for what it is")
    func registryMoved() async {
        let lines = await drift(registryDigest: "sha256:bbb")
            .check(stack: stack(settings: granted))
        #expect(lines.count == 1)
        #expect(lines.first?.contains("registry") == true)
        #expect(lines.first?.contains("new code") == true)
    }

    @Test("a local tag newer than the running container is a pending change")
    func localTagMoved() async {
        let lines = await drift(
            derivedCreated: "2026-08-07T17:00:00Z", tagCreated: "2026-08-09T11:00:00Z"
        ).check(stack: stack(settings: granted))
        #expect(lines.contains { $0.contains("newer than the running container") })
    }

    @Test("no admin channel says the question is unanswerable, not answered")
    func noAdminIsHonest() async {
        let lines = await drift().check(stack: stack(settings: nil))
        #expect(lines.count == 1)
        #expect(lines.first?.contains("drift not checkable") == true)
        #expect(lines.first?.contains("hatchery-inspect") == true)
    }

    @Test("a refused grant reports the wrapper, not silence")
    func refusedGrant() async {
        let lines = await drift(registryDigest: nil)
            .check(stack: stack(settings: granted))
        #expect(lines.contains { $0.contains("did not answer") })
    }

    @Test("platform backends are not asked")
    func platformSkipped() async {
        let spec = StackSpec(name: "x", backend: .appPlatform, services: [])
        let lines = await ImageDrift(run: { _ in
            Issue.record("no command should run for a platform backend")
            return Data()
        }).check(stack: spec)
        #expect(lines.isEmpty)
    }
}

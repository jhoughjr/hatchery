import Foundation
import Testing

@testable import HatcheryKit

@Suite("Drift on App Platform, asked of the platform and the registry")
struct AppPlatformDriftTests {
    @Test("an image reference knows its registry, repository, and tag")
    func references() {
        #expect(ImageReference("registry.digitalocean.com/macworkstack/mwserver:staging").registry
            == .docr(registry: "macworkstack", repository: "mwserver"))
        #expect(ImageReference("mhehmsoth/mwserver2:arm64-9cb6e4c-dev").registry
            == .dockerHub(repository: "mhehmsoth/mwserver2"))
        #expect(ImageReference("mhehmsoth/mwserver2:arm64-9cb6e4c-dev").tag == "arm64-9cb6e4c-dev")
        #expect(ImageReference("postgres").registry == .dockerHub(repository: "library/postgres"))
        #expect(ImageReference("postgres").tag == "latest")
        #expect(ImageReference("ghcr.io/x/y:1").registry == .unknown(host: "ghcr.io"))
    }

    private static func fake(_ argv: [String]) throws -> Data {
        let url = argv.last ?? ""
        if url.hasSuffix("/v2/apps?per_page=200") {
            return Data(#"{"apps": [{"spec": {"name": "mwcloud"}, "active_deployment": {"services": [{"name": "mwcloud", "source_image_digest": "sha256:aaa"}]}}, {"spec": {"name": "quiet"}, "active_deployment": {"services": [{"name": "quiet"}]}}]}"#.utf8)
        }
        if url.contains("/v2/registry/macworkstack/repositories/mwserver/tags/staging") {
            return Data(#"{"tag": {"manifest_digest": "sha256:bbb"}}"#.utf8)
        }
        if url.contains("hub.docker.com/v2/repositories/mhehmsoth/mwserver2/tags/dev") {
            return Data(#"{"digest": "sha256:aaa"}"#.utf8)
        }
        throw CommandFailure(command: "curl", status: 22, message: "404")
    }

    @Test("a moved DOCR tag is drift, an unmoved Hub tag is quiet, and no digest is not checkable")
    func checks() async {
        let drift = AppPlatformDrift(run: { argv in try Self.fake(argv) }, environment: ["DIGITALOCEAN_TOKEN": "t"])
        let moved = await drift.check(stack: StackSpec(
            name: "mwcloud", backend: .appPlatform,
            services: [ServiceSpec(name: "mwcloud", kind: .mwserver, image: "registry.digitalocean.com/macworkstack/mwserver:staging", configFile: "c")]))
        #expect(moved == ["mwcloud: the registry's tag staging has moved past what the platform deployed — applying pulls and runs new code"])

        let quiet = await drift.check(stack: StackSpec(
            name: "mwcloud", backend: .appPlatform,
            services: [ServiceSpec(name: "mwcloud", kind: .mwserver, image: "mhehmsoth/mwserver2:dev", configFile: "c")]))
        #expect(quiet.isEmpty)

        let noDigest = await drift.check(stack: StackSpec(
            name: "quiet", backend: .appPlatform,
            services: [ServiceSpec(name: "quiet", kind: .mwserver, image: "mhehmsoth/mwserver2:dev", configFile: "c")]))
        #expect(noDigest.first?.contains("reports no deployed digest") == true)
    }

    @Test("without a token every service says so, and a dokku stack is not its business")
    func tokenAndBackend() async {
        let drift = AppPlatformDrift(run: { _ in Data() }, environment: [:])
        let lines = await drift.check(stack: StackSpec(
            name: "s", backend: .appPlatform,
            services: [ServiceSpec(name: "a", kind: .mwserver, image: "x:y", configFile: "c")]))
        #expect(lines == ["a: drift not checkable — DIGITALOCEAN_TOKEN is not set"])
        #expect(await drift.check(stack: StackSpec(name: "s", backend: .dokku)).isEmpty)
    }
}

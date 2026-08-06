import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

private func sealStack() -> StackSpec {
    StackSpec(
        name: "mwlab",
        backend: .dokku,
        host: "dokku@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/mwserver-tf"),
        services: [
            ServiceSpec(
                name: "mwlab", kind: .mwserver, image: "mwserver2:arm64-abc",
                domains: ["mwlab.opi"], configFile: "mwlab.config.json",
                imageVariable: "mwlab_image")
        ]
    )
}

/// Mirrors `Wire.SetConfigBody`, which is Decodable only.
private struct SetConfigFixture: Encodable {
    let stack: String
    let service: String
    let values: [String: String]
    let confirm: String
}

private func setConfigRequest() -> WebRequest {
    let body = try! JSONEncoder().encode(
        SetConfigFixture(
            stack: "mwlab", service: "mwlab", values: ["LOG_LEVEL": "debug"], confirm: "mwlab"))
    return WebRequest(method: "POST", path: "/api/config/set", body: body)
}

/// The `detail` field, decoded — the response escapes slashes, so raw substring matching on a
/// path is unreliable.
private func detail(of response: WebResponse) -> String? {
    let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    return json?["detail"] as? String
}

@Suite("Writing config re-seals the backup")
struct WebSealTests {
    /// The file a config write lands in is gitignored, so the encrypted bundle is its only copy.
    /// A write that does not seal leaves a secret on one disk — which is what actually happened.
    @Test("a config write seals the directory it wrote into")
    func sealsAfterWrite() async {
        actor Sealed {
            var paths: [String] = []
            func record(_ path: String) { paths.append(path) }
        }
        let sealed = Sealed()
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [sealStack()]) },
            manifestPath: { "/infra/mwserver-tf/hatchery.json" },
            writeConfig: { _, _ in },
            sealState: { path in
                await sealed.record(path)
                return "sealed secrets in /infra"
            }
        )

        let response = await api.handle(setConfigRequest())

        #expect(response.status == 200)
        await #expect(sealed.paths == ["/infra/mwserver-tf/mwlab.config.json"])
        // The person clicking is told the backup moved, rather than left to assume it.
        // Read the decoded field: JSON escapes the slashes, so a raw substring match on the
        // path would pass or fail for the wrong reason.
        #expect(detail(of: response)?.contains("sealed secrets in /infra") == true)
    }

    /// A backup problem must not read as a failed config write — the value *was* written, and
    /// telling someone it failed invites them to write it again.
    @Test("a seal failure is reported without failing the write")
    func sealFailureDoesNotFailTheWrite() async {
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [sealStack()]) },
            manifestPath: { "/infra/hatchery.json" },
            writeConfig: { _, _ in },
            sealState: { _ in "warning: could not seal /infra: age: no recipient" }
        )

        let response = await api.handle(setConfigRequest())

        #expect(response.status == 200)
        #expect(detail(of: response)?.contains("could not seal") == true)
    }
}

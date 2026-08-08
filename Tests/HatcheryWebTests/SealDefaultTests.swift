import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

/// Exercises the *default* seal and verify closures, which no other test does — every other
/// test injects them, which is exactly how issue #36 hid: a closure literal in those
/// default-argument positions crashed the task allocator at the first await through it, and
/// the injections meant the first await ever taken through a default was in production.
///
/// The defaults walk the real filesystem, so each test points the manifest at a temp path
/// where the walk finds what the test intends and nothing runs a shell: no `.age-recipient`
/// means the seal returns before executing anything, and a marker without an archive means
/// the verify does too.
struct SealDefaultTests {
    private func stack() -> StackSpec {
        StackSpec(
            name: "mwlab",
            backend: .dokku,
            host: "dokku@192.168.0.103",
            tofu: TofuBinding(directory: "/infra/mwserver-tf"),
            services: [
                ServiceSpec(
                    name: "mwlab", kind: .mwserver, image: "mwserver2:arm64-abc",
                    domains: ["mwlab.opi"], configFile: "mwlab.config.json")
            ])
    }

    @Test func savingConfigThroughTheDefaultSealSurvives() async throws {
        // The #36 crash: built with the default sealState, the first save aborted the process
        // with "freed pointer was not the last allocation". The manifest path is a temp
        // directory that does not exist, so the walk finds no marker and seals nothing.
        let manifest = NSTemporaryDirectory() + "seal-default-\(UUID().uuidString)/hatchery.json"
        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            manifestPath: { manifest },
            readConfig: { _ in [:] },
            writeConfig: { _, _ in })

        let response = await api.handle(
            WebRequest(
                method: "POST", path: "/api/config/set", query: [:], headers: [:],
                body: try JSONSerialization.data(withJSONObject: [
                    "stack": "mwlab", "service": "mwlab",
                    "values": ["DATABASE_URL": "postgres://staging"],
                    "confirm": "mwlab",
                ])))

        #expect(response.status == 200)
    }

    @Test func verifyingThroughTheDefaultSurvives() async throws {
        // Same shape for the other default. The route only awaits once a sealed root exists,
        // so this one needs a real marker on disk — but no archive, which stops the verify at
        // "nothing sealed yet" before it would run `unseal.sh`.
        let root = NSTemporaryDirectory() + "verify-default-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "age1testrecipient".write(
            toFile: root + "/" + SealedState.marker, atomically: true, encoding: .utf8)

        let api = HatcheryAPI(
            loadManifest: { StackManifest(stacks: [self.stack()]) },
            manifestPath: { root + "/hatchery.json" })

        let response = await api.handle(
            WebRequest(
                method: "POST", path: "/api/state/verify", query: [:], headers: [:],
                body: Data()))

        #expect(response.status == 200)
        let body = String(decoding: response.body, as: UTF8.self)
        #expect(body.contains("nothing sealed yet"))
    }
}

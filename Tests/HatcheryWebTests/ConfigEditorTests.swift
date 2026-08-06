import Foundation
import HatcheryKit
import Testing

@testable import HatcheryWeb

private func editorStack() -> StackSpec {
    StackSpec(
        name: "mwlab-2",
        backend: .dokku,
        host: "dokku@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/staging"),
        services: [
            ServiceSpec(
                name: "mwserver-staging", kind: .mwserver, image: "mwserver2:arm64-abc",
                domains: ["staging.opi"], configFile: "staging.config.json",
                imageVariable: "staging_image")
        ]
    )
}

/// An API whose live read fails, so the route falls back to the declared file — which is the
/// case that matters here: a service scaffolded but never configured.
private func editorAPI(declared: [String: String]) -> HatcheryAPI {
    HatcheryAPI(
        loadManifest: { StackManifest(stacks: [editorStack()]) },
        manifestPath: { "/infra/staging/hatchery.json" },
        liveConfig: LiveConfigReader(run: { _ in
            throw CommandFailure(command: "ssh", status: 255, message: "unreachable")
        }),
        readConfig: { _ in declared }
    )
}

private func configView(_ response: WebResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
}

@Suite("Editing config for keys that are missing")
struct ConfigEditorTests {
    /// The defect this fixes: a required key with no value has nothing in `declared`, so the
    /// editor had no field to render and the only way in was typing its name from memory.
    @Test("the route names the required keys that have no value")
    func reportsMissingKeys() async {
        let response = await editorAPI(declared: ["LOG_LEVEL": "debug"])
            .handle(WebRequest(method: "GET", path: "/api/config",
                               query: ["stack": "mwlab-2", "service": "mwserver-staging"]))

        #expect(response.status == 200)
        let missing = configView(response)["missingKeys"] as? [String] ?? []
        #expect(!missing.isEmpty)
        // Named, so the browser can build a field per key rather than one blank pair.
        #expect(missing.contains("DATABASE_URL"))
        #expect(missing.contains("APP_ID"))
        // A key that does have a value is not missing.
        #expect(!missing.contains("LOG_LEVEL"))
        #expect(missing == missing.sorted())
    }

    @Test("a key present but empty counts as missing")
    func emptyIsMissing() async {
        let response = await editorAPI(declared: ["DATABASE_URL": ""])
            .handle(WebRequest(method: "GET", path: "/api/config",
                               query: ["stack": "mwlab-2", "service": "mwserver-staging"]))

        // An empty value is why the service will not boot, so it belongs in the editor with the
        // rest — dokku rejects zero-length values outright.
        let missing = configView(response)["missingKeys"] as? [String] ?? []
        #expect(missing.contains("DATABASE_URL"))
    }

    @Test("nothing is missing when every required key has a value")
    func completeConfig() async {
        // Build a full config from the contract itself, so this does not drift as keys change.
        guard let contract = EnvContract.contract(for: .mwserver, backend: .dokku) else {
            Issue.record("no contract for mwserver on dokku")
            return
        }
        let full = Dictionary(uniqueKeysWithValues: contract.required.map { ($0, "set") })

        let response = await editorAPI(declared: full)
            .handle(WebRequest(method: "GET", path: "/api/config",
                               query: ["stack": "mwlab-2", "service": "mwserver-staging"]))

        #expect((configView(response)["missingKeys"] as? [String] ?? ["x"]).isEmpty)
    }

    /// A secret's value never reaches the browser, only a fingerprint. A missing secret has no
    /// value to fingerprint, so it must still be listed — otherwise the one key a person cannot
    /// guess is the one with no field.
    @Test("missing secrets are listed like any other missing key")
    func missingSecretsListed() async {
        let response = await editorAPI(declared: [:])
            .handle(WebRequest(method: "GET", path: "/api/config",
                               query: ["stack": "mwlab-2", "service": "mwserver-staging"]))

        let view = configView(response)
        let missing = view["missingKeys"] as? [String] ?? []
        let secrets = Set(view["secretKeys"] as? [String] ?? [])
        guard let contract = EnvContract.contract(for: .mwserver, backend: .dokku) else {
            Issue.record("no contract for mwserver on dokku")
            return
        }

        // Only the secrets the contract *requires*. An optional secret that is unset is not
        // missing, and offering it as though the service will not boot without it would be a
        // lie — that distinction is the contract's to make, not the editor's.
        let requiredSecrets = contract.required.filter(secrets.contains)
        #expect(!requiredSecrets.isEmpty)
        for secret in requiredSecrets {
            #expect(missing.contains(secret), "\(secret) is required and unset, so it must be offered")
        }
        // KEYPAIR_JWKS has no value in the browser, only a fingerprint — so if it were left out
        // of this list it would be the one key with no field and no way to guess it.
        #expect(missing.contains("KEYPAIR_JWKS"))
    }
}

@Suite("Reaching the config editor")
struct ConfigEditorReachabilityTests {
    /// It was only at the foot of the panel `config` opens, under every declared value. On a
    /// service with twenty keys the fix was further away than the problem.
    @Test("edit sits beside config on the service row")
    func editIsOnTheRow() {
        let markup = Page.markup
        guard let row = markup.range(of: "button('config', 'config', stack.name, svc.name)") else {
            Issue.record("the service row no longer renders a config button")
            return
        }
        let after = markup[row.upperBound...].prefix(400)
        #expect(after.contains("button('edit-config', 'edit'"))
    }
}

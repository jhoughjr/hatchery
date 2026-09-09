import ArgumentParser
import Foundation
import HatcheryKit

/// The vault registration step of authoring a service, shared by `service new` and `box adopt`.
///
/// It runs after the declaration and the two config files are on disk. Registration mints a key vault shows
/// once, and the file that key is written to has to exist before the key is asked for.
enum VaultStep {
    /// Whether this service asks to be registered.
    ///
    /// `service new --gated` asks directly, and an adopted service asks through its kind file's
    /// `capabilities`. A built-in kind declares no capability, so adopt registers nothing by itself.
    static func wanted(gated: Bool = false, contract: EnvContract?) -> Bool {
        gated || contract?.declaresVault == true
    }

    /// Registers the service with vault and records the three vault keys in its own files.
    ///
    /// The registration is idempotent, so a second run against a service vault already holds changes nothing.
    /// A dry run prints the same plan and calls no route.
    static func run(
        service: ServiceSpec,
        in stack: StackSpec,
        manifestPath: String,
        contract: EnvContract,
        dryRun: Bool
    ) async throws {
        let configURL = ConfigSync.configURL(for: service, in: stack, manifestPath: manifestPath)
        let secretsURL = ConfigSync.secretsURL(for: service, in: stack, manifestPath: manifestPath)
        let config = (try? ConfigSync.readDeclared(at: configURL)) ?? [:]
        let secrets = secretsURL.flatMap { try? ConfigSync.readDeclared(at: $0) } ?? [:]
        let declared = config.merging(secrets) { _, secret in secret }

        let document = VaultRegistrar.documentSecrets(in: declared, contract: contract)
        let held = declared[VaultRegistrar.appKeyKey]
        let baseURL = declared[VaultRegistrar.urlKey].flatMap { $0.isEmpty ? nil : $0 }
            ?? VaultAdmin.defaultBaseURL

        if dryRun {
            print("    vault    register \(service.name) at \(baseURL)")
            print(
                (held ?? "").isEmpty
                    ? "    vault    mint an app key into \(VaultRegistrar.appKeyKey)"
                    : "    vault    the config holds an app key, so mint none")
            let names = document.keys.sorted().joined(separator: " + ")
            print("    vault    set \(names.isEmpty ? "no secret-marked key" : names)")
            return
        }

        guard let session = VaultSession.read() else { throw RotationRefusal.noVaultSession }
        let registrar = VaultRegistrar(
            vault: VaultAdmin(baseURL: baseURL, session: session), baseURL: baseURL)
        let registration = try await registrar.register(
            app: service.name, secrets: document, holding: held)
        registration.lines().forEach { print($0) }

        // The app key is a secret and goes to the secrets file. The other two are how the app finds vault
        // before it has read anything, so they are ordinary config.
        let split = ConfigSync.split(registration.keys, by: contract.knowing(VaultRegistrar.appKeyKey))
        if !split.config.isEmpty {
            try ConfigSync.encoded(ConfigSync.applying(split.config, to: config))
                .write(to: configURL, options: .atomic)
        }
        if !split.secrets.isEmpty, let secretsURL {
            try ConfigSync.encoded(ConfigSync.applying(split.secrets, to: secrets))
                .write(to: secretsURL, options: .atomic)
        }
    }
}

extension EnvContract {
    /// The same contract with one more key marked secret.
    ///
    /// `VAULT_APP_KEY` is a secret whatever a kind file says about it, and no built-in kind names it at all.
    /// Marking it here keeps the split rule in one place rather than special-casing the key at the write.
    func knowing(_ key: String) -> EnvContract {
        var contract = self
        contract.secret.insert(key)
        return contract
    }
}

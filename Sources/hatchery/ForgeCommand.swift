import ArgumentParser
import Foundation
import HatcheryKit

/// The forge's CI secrets, kept once in vault and set on repositories.
struct Forge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep the forge's CI secrets in vault and set them on repositories.",
        subcommands: [Seed.self, Secrets.self]
    )

    /// Stores a value in vault's forge app once, read from standard input so it never enters an argument or the history.
    struct Seed: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Store a CI secret in vault's forge app, with the value on standard input.",
            discussion: "For example: pbpaste | hatchery forge seed FORGE_PACKAGE_TOKEN"
        )

        @Argument(help: "The secret's name, such as FORGE_PACKAGE_TOKEN.")
        var name: String

        func run() async throws {
            let value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw ValidationError("give the value on standard input") }
            guard let credential = VaultAdminCredential.resolve() else {
                throw ValidationError("no vault operator token: hatchery vault login")
            }
            try await ForgeSecrets(vault: VaultAdmin(credential: credential)).seed(name: self.name, value: value)
            print("stored \(self.name) in vault's forge app")
        }
    }

    /// Makes repositories hold the forge's CI secrets, writing only what each one lacks.
    struct Secrets: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the forge's CI secrets from vault on repositories that lack them.",
            discussion: """
                Each repository is checked first, and only a name it does not hold is written, so a second run changes nothing. \
                The values come from vault's forge app and never reach the terminal. With --replace, every name is written again.
                """
        )

        @Argument(help: "Repositories as owner/name, such as jimmy/vault-hb.")
        var repos: [String]

        @Option(name: .long, help: "A secret name to set. Repeat it for several. Defaults to FORGE_PACKAGE_TOKEN.")
        var name: [String] = []

        @Flag(name: .long, help: "Write every name again, even where the repository holds it.")
        var replace = false

        func run() async throws {
            guard let credential = VaultAdminCredential.resolve() else {
                throw ValidationError("no vault operator token: hatchery vault login")
            }
            let secrets = ForgeSecrets(vault: VaultAdmin(credential: credential))
            let names = self.name.isEmpty ? ForgeSecrets.defaultNames : self.name
            for repo in self.repos {
                do {
                    for step in try await secrets.apply(repo: repo, names: names, replace: self.replace) {
                        print("  \(step.outcome == .held ? "hold " : "set  ") \(repo) \(step.name)")
                    }
                } catch let failure as ForgeSecrets.Failure {
                    print("  FAILED \(repo): \(failure)")
                    throw ExitCode.failure
                }
            }
        }
    }
}

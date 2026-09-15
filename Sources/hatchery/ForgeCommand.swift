import ArgumentParser
import Foundation
import HatcheryKit

/// The forge's CI secrets, kept once in vault and set on repositories.
struct Forge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep the forge's CI secrets in vault and set them on repositories.",
        subcommands: [Seed.self, Secrets.self, Prune.self]
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

    /// Keeps container packages to their newest versions and the ones a deployment runs.
    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete old versions of forge container packages, keeping the newest and the protected ones.",
            discussion: """
                CI pushes one image a commit, and the forge keeps every one, on the box's own disk. \
                Without --yes this lists what it would delete and deletes nothing. The newest --keep versions, latest, \
                every digest-named version, and every version that starts with a --protect prefix stay.
                """
        )

        @Argument(help: "Package names, such as rookery and vault-hb.")
        var packages: [String]

        @Option(name: .long, help: "The package owner.")
        var owner = "jimmy"

        @Option(name: .long, help: "How many of the newest versions to keep.")
        var keep = 5

        @Option(name: .long, help: "A version prefix to keep, such as the commit a deployment runs. Repeat it for several.")
        var protect: [String] = []

        @Option(name: .long, help: "A dokku app whose deployed image stays, as dokku@host:app. Repeat it for several.")
        var protectDeployed: [String] = []

        @Flag(name: .long, help: "Delete. Without it, only list.")
        var yes = false

        func run() async throws {
            guard let credential = VaultAdminCredential.resolve() else {
                throw ValidationError("no vault operator token: hatchery vault login")
            }
            // The deployed tags are read before anything is deleted, and a deployment that cannot be read stops the run.
            var protect = self.protect
            for target in self.protectDeployed {
                guard let tag = ForgePackages.deployedTag(target) else {
                    print("  FAILED: could not read the image \(target) runs, so nothing was deleted")
                    throw ExitCode.failure
                }
                print("  \(target) runs \(tag), which stays")
                protect.append(tag)
            }
            let packages = ForgePackages(secrets: ForgeSecrets(vault: VaultAdmin(credential: credential)))
            do {
                let token = try await packages.packageToken()
                for name in self.packages {
                    let versions = try await packages.versions(owner: self.owner, package: name, token: token)
                    let doomed = ForgePackages.plan(versions, keep: self.keep, protect: protect)
                    print("  \(name): \(versions.count) versions, \(doomed.count) to delete, \(versions.count - doomed.count) kept")
                    guard self.yes else {
                        for version in doomed.prefix(10) { print("    would delete \(version.version)") }
                        if doomed.count > 10 { print("    and \(doomed.count - 10) more") }
                        continue
                    }
                    for version in doomed {
                        try await packages.delete(owner: self.owner, version, token: token)
                    }
                    print("  \(name): deleted \(doomed.count)")
                }
            } catch let failure as ForgePackages.Failure {
                print("  FAILED: \(failure)")
                throw ExitCode.failure
            }
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

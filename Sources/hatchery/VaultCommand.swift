import ArgumentParser
import Foundation
import HatcheryKit
import HatcheryWeb

/// The door on this machine's own credential for vault's admin routes.
///
/// Nothing here reads or writes a service. It signs this machine in, says who it is signed in as, and signs it out, so
/// every other vault call in the tool has a credential to find.
struct Vault: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Sign this machine in to vault, and say who it is signed in as.",
        discussion: """
            Sign-in runs vault's own browser sign-in and redirects the operator token back to a loopback \
            port this process owns for the length of the sign-in. The token never passes through an \
            argument or the shell history, and it lands in a file only this account can read.

            Every admin call the tool makes looks for a credential in one order: VAULT_OPERATOR_TOKEN in \
            the environment, then the token file for the vault's host, then VAULT_SESSION in the \
            environment.
            """,
        subcommands: [Login.self, Status.self, Logout.self, Requires.self]
    )

    /// The address of the vault a subcommand acts on, which every one of them takes.
    struct Address: ParsableArguments {
        @Option(name: .long, help: "The vault to act on.")
        var vault: String = VaultAdmin.defaultBaseURL
    }

    /// Signs this machine in through the browser and stores the token vault answers.
    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "Run vault's browser sign-in and store the operator token it answers."
        )

        @OptionGroup var address: Address

        @Option(name: .long, help: "The label the token is signed in under. Defaults to this machine's name.")
        var name: String?

        func run() async throws {
            let vault = self.address.vault
            let label = self.name ?? Vault.machineName()
            let outcome = try await VaultLogin.run(
                vault: vault,
                name: label,
                show: { url in
                    print("  sign in at:")
                    print("    \(url.absoluteString)")
                    Vault.openInBrowser(url)
                },
                confirm: { credential in
                    try await VaultAdmin(baseURL: vault, credential: credential).whoami()
                })

            print("  signed in to \(vault) as \(outcome.identity.email)")
            print("  the token is at \(outcome.path)")
        }
    }

    /// Says who this machine is signed in as, and asks vault rather than trusting the file.
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Say who this machine is signed in to vault as."
        )

        @OptionGroup var address: Address

        func run() async throws {
            let vault = self.address.vault
            guard let credential = VaultAdminCredential.resolve(vault: vault) else {
                print("  not signed in; \(VaultAdminCredential.recipe)")
                return
            }
            let identity = try await VaultAdmin(baseURL: vault, credential: credential).whoami()
            print("  \(vault): signed in as \(identity.email) (\(Vault.label(credential, identity)))")
        }
    }

    /// Sets on vault what a declared app requires of a person, from the service's `vaultRequires`.
    struct Requires: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "requires",
            abstract: "Set on vault what a declared app requires of a person.",
            discussion: """
                The requirement comes from the service's vaultRequires in the manifest, for example \
                [{"provider": "github", "orgs": ["acme"]}]. A service that declares none requires nothing, and \
                this clears any requirement vault held. The call replaces the whole list, so a second run changes nothing.
                """
        )

        @OptionGroup var address: Address

        @Argument(help: "The service, as <stack>/<service>.")
        var target: String

        @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
        var manifest: [String] = []

        @Flag(name: .long, help: "Print what would be set and call no route.")
        var dryRun = false

        func run() async throws {
            let resolved = try Secrets.resolve(self.target, manifest: self.manifest)
            let requires = resolved.service.vaultRequires ?? []
            print("  \(resolved.service.name)")
            guard !self.dryRun else {
                print(VaultRegistration.requiresLine(requires))
                return
            }
            guard let credential = VaultAdminCredential.resolve(vault: self.address.vault) else {
                print("  not signed in; \(VaultAdminCredential.recipe)")
                throw ExitCode.failure
            }
            let stored = try await VaultAdmin(baseURL: self.address.vault, credential: credential)
                .setRequirements(app: resolved.service.name, requires: requires)
            print(VaultRegistration.requiresLine(stored))
        }
    }

    /// Removes this machine's token file.
    struct Logout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "logout",
            abstract: "Remove this machine's vault token file.",
            discussion: """
                This removes the file and calls no route. Vault's console is where a token is revoked, so a \
                token that is loose stays loose until it is revoked there.
                """
        )

        @OptionGroup var address: Address

        func run() async throws {
            let store = VaultTokenStore()
            let had = try store.delete(vault: self.address.vault)
            print(
                had
                    ? "  the token for \(self.address.vault) is gone from this machine"
                    : "  this machine held no token for \(self.address.vault)")
            if had {
                print("  revoke it in vault's console when it must stop working everywhere.")
            }
        }
    }

    /// How a status line names the credential in use.
    static func label(_ credential: VaultAdminCredential, _ identity: VaultIdentity) -> String {
        switch credential.source {
        case .sessionVariable:
            return "browser session"

        case .operatorVariable, .tokenFile:
            guard let name = identity.tokenName else { return "token" }
            return "token \(name)"
        }
    }

    /// This machine's name, which is the label a token carries when none is given.
    static func machineName() -> String {
        let name = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "this machine" : name
    }

    /// Opens the sign-in page, on the one platform that has a command for it.
    ///
    /// Elsewhere the address is printed and nothing else happens, because a person on a headless box copies the line
    /// into their own browser.
    static func openInBrowser(_ url: URL) {
        #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.absoluteString]
            try? process.run()
        #endif
    }
}

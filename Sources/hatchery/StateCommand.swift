import ArgumentParser
import Foundation
import HatcheryKit

/// The state directory itself, as opposed to what is deployed from it.
struct State: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Check and re-seal the encrypted backup of a state directory.",
        subcommands: [Init.self, Status.self, Seal.self, Verify.self]
    )

    /// Opens the archive, rather than trusting that it would open.
    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Decrypt the backup and check it against the manifest.",
            discussion: """
                `state status` compares what is on disk against secrets.manifest and never opens \
                the archive, so a corrupt or unopenable secrets.tar.age passes it. This opens it.

                Needs the age identity, which is the point: a backup that cannot be opened on \
                this machine is one you find out about now rather than during a restore.
                """
        )

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        func run() async throws {
            let root = try State.root(manifest: manifest)
            let result = await SealVerifier().verify(pathInside: root)

            print(root)
            switch result {
            case .verified(let files):
                print("  ok           \(result.summary)")
                _ = files
            case .mismatch(let missing, let differing):
                print("  MISMATCH     \(result.summary)")
                for path in missing { print("    missing    \(path)") }
                for path in differing { print("    differs    \(path)") }
            case .unopenable, .noIdentity, .noArchive, .notSealed:
                print("  \(result.isProblem ? "FAILED" : "--")         \(result.summary)")
            }
            if result.isProblem { throw ExitCode(1) }
        }
    }

    /// Turns a directory into one that backs itself up.
    struct Init: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set up a state directory that encrypts its secrets and backs them up.",
            discussion: """
                Generates an age key, writes seal.sh/unseal.sh and the ignore rules that keep \
                plaintext secrets out of version control, and starts a git repository. With \
                --remote it creates a private GitHub repository and pushes.

                Safe to re-run. An existing key is reused rather than replaced — a new key would \
                leave any existing archive unopenable.
                """
        )

        @Option(name: .shortAndLong, help: "Directory to set up.")
        var directory: String

        @Option(name: .long, help: "Where the age private key lives. Defaults to ~/.config/age/<dir>.txt.")
        var identity: String?

        @Option(name: .long, help: "GitHub repository as owner/name. Created private.")
        var remote: String?

        @Flag(name: .long, help: "Commit and push. Without it, nothing leaves this machine.")
        var push: Bool = false

        @Flag(name: .long, help: "Show what would be done without writing anything.")
        var dryRun: Bool = false

        func run() async throws {
            let plan = StateInitPlanner.plan(
                StateInitRequest(directory: directory, identityPath: identity, remote: remote))
            let initializer = StateInitializer()

            print(plan.directory)
            print("  key          \(plan.identityPath)\(plan.reusesIdentity ? " (existing, reused)" : " (will be generated)")")
            if let remote = plan.remote { print("  remote       \(remote) (private)") }
            for file in plan.files { print("  write        \(file.path)") }

            let checks = await initializer.preflight(plan)
            for check in checks where check.status != .ok {
                print("  MISSING      \(check.name): \(check.detail ?? "")")
                if let remedy = check.remedy { print("               → \(remedy)") }
            }
            guard !checks.contains(where: { $0.status == .failed }) else {
                throw ExitCode(1)
            }

            if dryRun {
                print("")
                print("  dry run; nothing written")
                return
            }

            let result = try await initializer.run(plan)
            print("")
            if result.generatedIdentity { print("  generated key at \(plan.identityPath)") }
            for path in result.created { print("  wrote \(path)") }
            for path in result.preserved { print("  kept  \(path) (already present)") }
            if result.gitInitialised { print("  git init") }
            print("  encrypts to \(result.recipient)")

            if push {
                let published = try await initializer.publish(plan, message: "Set up encrypted infrastructure state")
                if published.committed { print("  committed") }
                if published.pushed { print("  pushed to \(plan.remote ?? "origin")") }
            } else if plan.remote != nil {
                print("  nothing pushed; re-run with --push")
            }

            print("")
            for warning in result.warnings { print("  ! \(warning)") }
        }
    }

    /// Where the state directory is, given a manifest path.
    static func root(manifest: String) throws -> String {
        let resolved = try ManifestLocator.resolve(manifest)
        // Symlinked into place from ~/.config/hatchery, so resolve it before walking up —
        // otherwise the walk climbs out of ~/.config and finds nothing.
        let real = URL(fileURLWithPath: resolved).resolvingSymlinksInPath()
            .deletingLastPathComponent().path
        guard let root = SealedState.root(containing: real) else {
            throw ValidationError(
                """
                \(real) is not inside a sealed state directory.

                A sealed directory holds \(SealedState.marker), naming the age key its backup
                encrypts to. Without one, secrets there are stored in plaintext and hatchery
                has nothing to back up.
                """)
        }
        return root
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report secrets that are not in the encrypted backup."
        )

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        func run() throws {
            let root = try State.root(manifest: manifest)
            let status = try SealAudit().status(root: root)

            print(status.root)
            print("  last sealed  \(status.sealedAt ?? "never")")

            if status.sealed {
                print("  ok           every secret on disk is in the backup")
                return
            }

            for path in status.unsealed {
                print("  UNSEALED     \(path)")
            }
            for path in status.stale {
                print("  gone         \(path)  (in the backup, no longer on disk)")
            }
            if !status.unsealed.isEmpty {
                print("")
                print("These exist only on this machine. Run `hatchery state seal`.")
            }
        }
    }

    struct Seal: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-encrypt the backup so it matches what is on disk."
        )

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        func run() async throws {
            let root = try State.root(manifest: manifest)
            let sealer = StateSealer(execute: ShellRunner.liveExecutor)

            let outcome = await sealer.seal(pathInside: root)
            if let message = outcome.message { print(message) }

            switch outcome {
            case .sealed:
                let after = try SealAudit().status(root: root)
                if !after.sealed {
                    print("warning: still unsealed after sealing: \(after.unsealed.joined(separator: ", "))")
                    throw ExitCode(1)
                }
                // Opening what was just written is the only thing that makes the archive a
                // backup rather than a belief. Cheap, and the one moment it is certain to be
                // openable if it ever will be.
                let verified = await SealVerifier().verify(pathInside: root)
                print("  \(verified.isProblem ? "warning: " : "")\(verified.summary)")
                if case .unopenable = verified { throw ExitCode(1) }
            case .failed, .noScript:
                throw ExitCode(1)
            case .notSealed:
                break
            }
        }
    }
}

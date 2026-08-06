import ArgumentParser
import Foundation
import HatcheryKit

/// The state directory itself, as opposed to what is deployed from it.
struct State: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Check and re-seal the encrypted backup of a state directory.",
        subcommands: [Status.self, Seal.self]
    )

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
            case .failed, .noScript:
                throw ExitCode(1)
            case .notSealed:
                break
            }
        }
    }
}

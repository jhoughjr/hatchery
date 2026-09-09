import ArgumentParser
import Foundation
import HatcheryKit

/// The door on the rotations a service declares.
///
/// A secret's rotation is a declaration in the service's own kind file: what issues the value, who holds it,
/// and how each holder takes a new one. `holders` reads that declaration, and `rotate` executes it.
struct Secrets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Read and execute the rotations a service declares.",
        discussion: """
            A value read once at boot rotates by a config change and a restart. A value reissued \
            elsewhere rotates in order: the issuer first, then the config, then the restart. A value \
            fetched per use is not config at all and needs no restart. A shared bearer invalidates every \
            holder at once, so a rotation names its holders before it turns the value over.

            The vault session is read from VAULT_SESSION in the environment and never from an argument, \
            because an argument lands in the shell history and in ps.
            """,
        subcommands: [Holders.self, Rotate.self]
    )

    /// What a `<stack>/<service>` target resolves to: the service, and the kind file that declares its rotations.
    struct Target {
        var service: ServiceSpec
        var stack: StackSpec
        var kind: KindFile
        var apps: Set<String>
        var hosts: Set<String>
        var manifestPath: String
    }

    /// Reads no box. Every fact here is in the manifests and the kind registry beside them.
    static func resolve(_ text: String, manifest: [String]) throws -> Target {
        guard let target = DeclaredProvision.target(text) else {
            throw ValidationError("name the service as <stack>/<service>, for example rookery/rookery")
        }
        let requested = manifest.isEmpty ? [ManifestLocator.defaultName] : manifest
        let loaded = try requested.map { try ManifestLocator.load($0) }

        for entry in loaded {
            guard let stack = entry.manifest.stack(named: target.stack),
                let service = stack.service(named: target.service)
            else { continue }
            let registry = KindRegistry(manifestPath: entry.path)
            guard let kind = try registry.kindFile(for: service.kind) else {
                throw RotationRefusal.noKindFile(
                    service: service.name, kind: service.kind.rawValue)
            }
            let manifests = loaded.map(\.manifest)
            return Target(
                service: service,
                stack: stack,
                kind: kind,
                apps: RotationPlanner.apps(in: manifests),
                hosts: RotationPlanner.hosts(in: manifests),
                manifestPath: entry.path)
        }
        throw ValidationError("no manifest declares \(target.stack)/\(target.service)")
    }

    /// Every bearer of every rotatable secret, and nothing else.
    ///
    /// A holder the manifest does not know is marked rather than refused, because this command writes nothing
    /// and a person asking who holds a value is owed the whole list, gap and all.
    struct Holders: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "holders",
            abstract: "Print who holds each of a service's rotatable secrets."
        )

        @Argument(help: "The service, as <stack>/<service>.")
        var target: String

        @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
        var manifest: [String] = []

        func run() async throws {
            let resolved = try Secrets.resolve(self.target, manifest: self.manifest)
            let groups = resolved.kind.rotationGroups()
            guard !groups.isEmpty else {
                print("  \(resolved.service.name) declares no secret with a rotation")
                return
            }

            for group in groups {
                print("  \(group.keys.joined(separator: " + "))")
                print("    issues   \(group.rotation.issuer.label(service: resolved.service.name))")
                for holder in group.rotation.holders {
                    print("    holds    \(holder.label)\(Self.gap(holder, in: resolved))")
                }
                if group.rotation.holders.isEmpty {
                    print("    holds    nobody hatchery can reach")
                }
            }
            let missing = resolved.kind.secretRotations().filter { $0.rotation == nil }
            for entry in missing {
                print("  \(entry.key)")
                print("    issues   nothing; this secret declares no rotation")
            }
        }

        /// The note beside a holder the manifest cannot reach, or nothing when it can.
        static func gap(_ holder: KindFile.Holder, in resolved: Secrets.Target) -> String {
            switch holder.target {
            case .dokkuApp(let app):
                return resolved.apps.contains(app) ? "" : "   (no app \(app) in the manifest)"

            case .host(let host):
                return resolved.hosts.contains(host) ? "" : "   (no host \(host) in the manifest)"

            case .vaultApp:
                return ""
            }
        }
    }

    /// Replaces a declared secret, in the order the declaration rules.
    ///
    /// The plan prints first, always. Without `--yes` that is the whole run, so the default is a dry run and
    /// executing is the thing a person has to ask for.
    struct Rotate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rotate",
            abstract: "Replace a declared secret: the issuer, then every holder, then every restart.",
            discussion: """
                Name the keys to rotate, or name none and every rotatable key of the service is planned. \
                A key issued by a person refuses the run and prints the recipe instead, and a holder the \
                manifest does not know refuses it too, because a bearer nothing can reach keeps the old \
                value after the new one is issued.
                """
        )

        @Argument(help: "The service, as <stack>/<service>.")
        var target: String

        @Argument(help: "The keys to rotate. Every rotatable key of the service when none are named.")
        var keys: [String] = []

        @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
        var manifest: [String] = []

        @Flag(name: .long, help: "Print the plan and stop, whatever else is given.")
        var dryRun = false

        @Flag(name: .long, help: "Execute the plan. Without it the plan prints and nothing changes.")
        var yes = false

        func run() async throws {
            let resolved = try Secrets.resolve(self.target, manifest: self.manifest)
            let plans = try RotationPlanner.plans(
                service: resolved.service.name,
                keys: self.keys,
                in: resolved.kind,
                apps: resolved.apps,
                hosts: resolved.hosts)

            print("  \(resolved.stack.name)/\(resolved.service.name), \(plans.count) rotation(s):")
            plans.flatMap { $0.lines() }.forEach { print($0) }

            guard self.yes, !self.dryRun else {
                print("  nothing changed. Run it again with --yes to execute this plan.")
                return
            }
            if plans.contains(where: { $0.rotation.issuer.needsVaultSession }),
                VaultSession.read() == nil
            {
                throw RotationRefusal.noVaultSession
            }
            print("  --yes is not accepted by this build, which carries the plan only.")
            throw ExitCode.failure
        }
    }
}

import ArgumentParser
import Foundation
import HatcheryKit

extension Stack {
    /// Builds a new stack from an existing one, carrying its configuration forward.
    struct Clone: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Plan what cloning a stack carries, then create it with --create.",
            discussion: """
                Reads the source stack's config — live from the box when the backend allows it, \
                the declared sidecar otherwise, and it says which — and works out, key by key, \
                what a copy into another environment should do with it. Optional keys the \
                source sets ride along; unset ones are not mentioned.

                Three things are never copied. Anything pointing at the source's database, \
                because a staging stack silently writing to production is worse than one that \
                will not start. Anything granting the source's authority — gateway tokens, \
                signing keys — which is regenerated instead. And anything the source itself \
                never had, which is reported rather than passed along as though it were set.

                Without --create this only reports. With --create --tofu-dir --yes it \
                bootstraps the stack, scaffolds each service, layers the carried values on, \
                and prints the `config set` commands for what still needs a person.
                """
        )

        @Argument(help: "Stack to clone from.")
        var source: String

        @Argument(help: "Name the clone would have.")
        var target: String

        @Option(name: .shortAndLong, help: "Environment for the clone.")
        var environment: String = "staging"

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        @Flag(name: .long, help: "Show secret values. Off by default; they are printed to a terminal.")
        var showSecrets: Bool = false

        @Option(name: .long, help: "Tofu directory for the clone. Required with --create.")
        var tofuDir: String?

        @Option(name: .long, help: "Backend for the clone. Defaults to the source's. appPlatform and cloudRun need --cluster.")
        var backend: String?

        @Option(name: .long, help: "appPlatform: the managed Postgres cluster, cloudRun: the Cloud SQL instance, the clone's databases are created in. Defaults to the source's db_cluster setting.")
        var cluster: String?

        @Option(name: .long, help: "Host for the clone. Defaults to the source's.")
        var host: String?

        @Flag(name: .long, help: "Actually create the stack, rather than reporting what it would carry.")
        var create: Bool = false

        @Flag(name: .long, help: "Required with --create, and to clone from a production stack.")
        var yes: Bool = false

        @Flag(name: .long, help: "After creating, run `tofu apply` so the clone lands on the box — the one-click path.")
        var apply: Bool = false

        @Option(name: .long, help: "What each database starts with: full (schema and data — the default; a clone of a running stack behaves like one), schema (tables, no rows), or none (empty).")
        var db: String = DatabaseCloneMode.full.rawValue

        // These three live in the source's tofu files, and are read from there. The flags
        // remain as overrides for a clone that should deliberately differ from its source.
        @Option(name: .long, help: "Container port override. Read from the source's tofu when not given.")
        var port: Int?

        @Option(name: .long, help: "Docker network override. Read from the source's tofu when not given.")
        var network: String?

        @Flag(name: .long, help: "Force gating behind enable_<name> variables. Read from the source's tofu when not given.")
        var gated: Bool = false

        func run() async throws {
            let path = try ManifestLocator.resolve(manifest)
            let parsed = try StackManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let spec = parsed.stack(named: source) else {
                throw ValidationError("no stack named '\(source)' in \(path)")
            }
            let env = Environment(rawValue: environment)

            if create, !yes {
                throw ValidationError("--create writes a new stack and mints keys; pass --yes as well")
            }
            if create, tofuDir == nil {
                throw ValidationError("--create needs --tofu-dir for the clone's declarations")
            }
            // The help always said this; now it is true. Reading a production stack's live
            // config deserves the same deliberate flag as every other production action.
            if spec.resolvedEnvironment.isProduction, !yes {
                throw ValidationError(
                    "'\(source)' is \(spec.resolvedEnvironment.rawValue); pass --yes to clone from it")
            }
            if apply, !create {
                throw ValidationError("--apply only means something with --create")
            }
            guard let databaseMode = DatabaseCloneMode(rawValue: db) else {
                throw ValidationError(
                    "--db must be one of: "
                        + DatabaseCloneMode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            if parsed.stack(named: target) != nil {
                throw ValidationError(
                    "'\(target)' already exists in \(path); clone to a name that does not")
            }

            let destination: Backend?
            if let backend {
                guard let parsedBackend = Backend(rawValue: backend) else {
                    throw ValidationError("unknown backend '\(backend)'")
                }
                destination = parsedBackend
            } else {
                destination = nil
            }
            let clusterName = cluster ?? spec.settings?["db_cluster"]
            if destination == .appPlatform || destination == .cloudRun, (clusterName ?? "").isEmpty {
                throw ValidationError(
                    "a clone onto \(destination!.rawValue) needs a managed Postgres "
                        + "\(destination == .cloudRun ? "instance" : "cluster"): pass --cluster, "
                        + "or set db_cluster on the source stack")
            }

            let arrow = destination.map { " → \($0.rawValue)" } ?? ""
            print("\(source) → \(target)  [\(spec.backend.rawValue)\(arrow) · \(env.rawValue)]")

            // The reading, rewriting and classifying live in the planner, shared with the
            // dashboard's clone — two implementations of this loop is how the CLI and the
            // browser come to promise different clones.
            let planned: PlannedClone
            do {
                planned = try await StackClonePlanner().plan(
                    stack: spec, into: target, environment: env, manifestPath: path,
                    databaseMode: databaseMode, targetBackend: destination, cluster: clusterName)
            } catch let error as StackClonePlanner.UnreadableConfig {
                throw ValidationError("\(error)")
            }

            for service in planned.plan.services {
                let origin = planned.origins[service.name] ?? "declared file"
                print("")
                // The rename is part of the plan: the clone's apps must not collide with the
                // source's on the same box, and the arrow is where that is shown.
                print("  \(service.sourceName) → \(service.name)  [\(service.kind.rawValue)]  from \(origin)")
                if !service.domains.isEmpty {
                    print("    domains  \(service.domains.joined(separator: ", "))")
                }

                for key in service.keys.sorted(by: { $0.key < $1.key }) {
                    switch key.disposition {
                    case .carried:
                        print("    carry    \(key.key)\(display(key))")
                    case .rewritten(let from, let to):
                        print("    rewrite  \(key.key)")
                        print("             \(from)")
                        print("          →  \(to)")
                    case .minted(let how):
                        print("    mint     \(key.key)  (\(how); the source's would grant its authority)")
                    case .provisioned(let how):
                        print("    db       \(key.key)  (\(how))")
                    case .refused(let why):
                        if key.required {
                            print("    NEEDS    \(key.key) — \(why)")
                        } else {
                            // The source sets it, the clone won't, and nothing breaks: worth a
                            // line, not a place on the boot checklist.
                            print("    skip     \(key.key) — \(why) (optional)")
                        }
                    }
                }

            }

            if !planned.exposure.isEmpty {
                print("")
                for door in planned.exposure {
                    if door.actionable {
                        print("  expose   \(door.domain) — \(door.action)")
                    } else {
                        print("  NOWHERE  \(door.domain) — \(door.action)")
                    }
                }
            }

            if !planned.costs.isEmpty {
                print("")
                for line in planned.costs {
                    print("  cost     \(line.text)")
                }
            }

            if !planned.warnings.isEmpty {
                print("")
                for warning in planned.warnings {
                    print("  WARNING  \(warning)")
                }
            }

            let carried = planned.plan.carriedCount
            let unresolved = planned.plan.unresolvedCount
            print("")
            print("  \(carried) key(s) resolved, \(unresolved) still need a person")
            if unresolved > 0 {
                print("  those are the ones that point at something only \(source) has")
            }

            guard create else {
                print("")
                print("  nothing written; re-run with --create --tofu-dir <dir> --yes")
                return
            }

            try await build(
                planned: planned, from: spec, manifest: parsed, at: path,
                environment: env, backend: destination, cluster: clusterName)
        }

        /// Creates the stack through the shared builder — the same code path the dashboard
        /// uses, so the two cannot promise different clones.
        private func build(
            planned: PlannedClone,
            from source: StackSpec,
            manifest: StackManifest,
            at path: String,
            environment: Environment,
            backend: Backend?,
            cluster: String?
        ) async throws {
            print("")
            let outcome = try await StackCloneBuilder().build(
                planned: planned, source: source, manifest: manifest, manifestPath: path,
                options: StackCloneBuilder.Options(
                    target: target, tofuDir: tofuDir!, host: host, environment: environment,
                    port: port, network: network, gated: gated ? true : nil, apply: apply,
                    backend: backend, cluster: cluster))

            print("  created \(target) in \(tofuDir!)")
            print("  tofu init: ok")

            for service in outcome.services {
                print("  \(service.name): \(service.resolved) value(s) resolved, "
                    + "\(service.unresolved.count) still needed")
                for line in service.databaseReport {
                    print("    db  \(line)")
                }
            }

            if let line = outcome.sealed {
                print("  \(line)")
            }

            if let plan = outcome.plan {
                switch plan.verdict {
                case .clean: print("  tofu plan: nothing to change")
                case .changes: print("  tofu plan: changes ready to apply")
                case .failed: print("  tofu plan FAILED — the clone is written but will not deploy as is")
                }
            }
            if let applied = outcome.applied {
                let lastLine = applied.split(separator: "\n").last.map(String.init) ?? "done"
                print("  tofu apply: \(lastLine)")
            } else if let skipped = outcome.applySkipped {
                print("  apply skipped: \(skipped)")
            } else if outcome.plan?.verdict == .changes {
                print("  nothing applied; re-run with --apply, or `hatchery apply \(target)`")
            }

            // Named per service. Flattening lost that, so two services each missing
            // DATABASE_PASSWORD printed the same unusable line twice.
            let outstanding = outcome.services.filter { !$0.unresolved.isEmpty }
            if !outstanding.isEmpty {
                print("")
                print("  before it will boot:")
                for service in outstanding {
                    for key in service.unresolved {
                        print("    hatchery config set \(target) \(service.name) \(key.key)=…")
                    }
                }
            }
            // The source set these and the clone dropped them. Nothing breaks, but a person
            // should decide that rather than never hear about it.
            let skippedOptional = outcome.services.filter { !$0.optionalSkipped.isEmpty }
            if !skippedOptional.isEmpty {
                print("")
                print("  optional, set on \(source.name) but not carried:")
                for service in skippedOptional {
                    for key in service.optionalSkipped {
                        print("    \(service.name)  \(key.key)")
                    }
                }
            }
        }

        /// Secret values are withheld unless asked for, because this prints to a terminal that
        /// keeps scrollback.
        private func display(_ key: ClonedKey) -> String {
            guard let value = key.value else { return "" }
            if key.secret && !showSecrets { return "  (secret, hidden)" }
            return "  \(value)"
        }
    }
}

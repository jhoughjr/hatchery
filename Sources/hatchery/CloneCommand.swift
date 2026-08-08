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

        @Option(name: .long, help: "Host for the clone. Defaults to the source's.")
        var host: String?

        @Flag(name: .long, help: "Actually create the stack, rather than reporting what it would carry.")
        var create: Bool = false

        @Flag(name: .long, help: "Required with --create, and to clone from a production stack.")
        var yes: Bool = false

        // The manifest does not record these three — they live in the source's tofu files —
        // so the clone cannot recover them and asks instead of silently guessing.
        @Option(name: .long, help: "Container port for the clone's services. The source's is not recorded; say what it used.")
        var port: Int = 8080

        @Option(name: .long, help: "Docker network for the clone's services, when the source used one.")
        var network: String?

        @Flag(name: .long, help: "Gate each service behind its enable_<name> tofu variable, as the source may have.")
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
            if parsed.stack(named: target) != nil {
                throw ValidationError(
                    "'\(target)' already exists in \(path); clone to a name that does not")
            }

            print("\(source) → \(target)  [\(spec.backend.rawValue) · \(env.rawValue)]")

            // The reading, rewriting and classifying live in the planner, shared with the
            // dashboard's clone — two implementations of this loop is how the CLI and the
            // browser come to promise different clones.
            let planned: PlannedClone
            do {
                planned = try await StackClonePlanner().plan(
                    stack: spec, into: target, environment: env, manifestPath: path)
            } catch let error as StackClonePlanner.UnreadableConfig {
                throw ValidationError("\(error)")
            }

            for service in planned.plan.services {
                let origin = planned.origins[service.name] ?? "declared file"
                print("")
                print("  \(service.name)  [\(service.kind.rawValue)]  from \(origin)")
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
                clone: planned.plan.services, from: spec, manifest: parsed, at: path,
                environment: env)
        }

        /// Creates the stack, its services, and their config.
        ///
        /// Minting is left to the scaffolder rather than done from the clone plan. The scaffolder
        /// already decides what is minted, shared from a sibling, or composed — running a second
        /// implementation beside it is how the two drift. The clone contributes only the values
        /// it carried or rewrote, layered on afterwards.
        private func build(
            clone: [ClonedService],
            from source: StackSpec,
            manifest: StackManifest,
            at path: String,
            environment: Environment
        ) async throws {
            print("")
            var settings = source.settings ?? [:]
            let resolvedHost = host ?? source.host ?? settings["host"] ?? ""
            settings["host"] = resolvedHost

            let bootstrapper = StackBootstrapper()
            let plan = try bootstrapper.plan(
                name: target, backend: source.backend, host: resolvedHost,
                tofuDir: tofuDir!, environment: environment, settings: settings,
                into: manifest, manifestPath: path)

            let created = try await bootstrapper.create(plan)
            try created.manifest.encoded().write(to: URL(fileURLWithPath: created.manifestPath))
            print("  created \(target) in \(tofuDir!)")
            print("  tofu init: ok")

            var current = created.manifest
            let scaffolder = Scaffolder()

            var written: [String] = []
            for service in clone {
                guard let stack = current.stack(named: target) else {
                    // Half a stack with no explanation is the worst outcome this command has.
                    throw ValidationError(
                        "'\(target)' vanished from the manifest mid-clone after "
                            + "[\(written.joined(separator: ", "))] were written; inspect \(path)")
                }

                // Siblings are the services already added to *this* clone, so the signing key is
                // shared within the new stack rather than carried from the source.
                var siblings: [String: [String: String]] = [:]
                for existing in stack.services {
                    let url = ConfigSync.configURL(
                        for: existing, in: stack, manifestPath: created.manifestPath)
                    if let config = try? ConfigSync.readDeclared(at: url) {
                        siblings[existing.name] = config
                    }
                }

                // The shape the source declared travels with the clone: its base URL (already
                // rewritten by the planner) and its readiness path. Losing the health path
                // meant a clone of a service with a custom route probed the default and read
                // as `responding` forever.
                let spec = ServiceSpec(
                    name: service.name, kind: service.kind, image: service.image,
                    domains: service.domains, configFile: "\(service.name).config.json",
                    baseURL: service.baseURL, healthPath: service.healthPath)

                let result = try await scaffolder.plan(
                    service: spec, into: target, manifest: current,
                    containerPort: port, network: network, gated: gated, siblings: siblings)
                _ = try scaffolder.write(result, in: stack)
                current = result.manifest
                try current.encoded().write(to: URL(fileURLWithPath: created.manifestPath))

                // The carried and rewritten values, layered over what the scaffolder wrote.
                if let target = current.stack(named: target),
                    let written = target.service(named: service.name) {
                    let url = ConfigSync.configURL(
                        for: written, in: target, manifestPath: created.manifestPath)
                    let existing = (try? ConfigSync.readDeclared(at: url)) ?? [:]
                    let merged = ConfigSync.applying(service.values, to: existing)
                    try ConfigSync.encoded(merged).write(to: url)
                }

                written.append(service.name)
                print("  \(service.name): \(service.values.count) value(s) carried, "
                    + "\(service.unresolved.count) still needed")
            }

            if let line = await StateMaintenance.seal(after: created.manifestPath) {
                print("  \(line)")
            }

            // Named per service. Flattening lost that, so two services each missing
            // DATABASE_PASSWORD printed the same unusable line twice.
            let outstanding = clone.filter { !$0.unresolved.isEmpty }
            if !outstanding.isEmpty {
                print("")
                print("  before it will boot:")
                for service in outstanding {
                    for key in service.unresolved {
                        print("    hatchery config set \(target) \(service.name) \(key.key)=…")
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

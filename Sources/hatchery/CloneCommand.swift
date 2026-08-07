import ArgumentParser
import Foundation
import HatcheryKit

extension Stack {
    /// Builds a new stack from an existing one, carrying its configuration forward.
    struct Clone: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show what cloning a stack would carry, regenerate and refuse.",
            discussion: """
                Reads the source stack's declared config and works out, key by key, what a copy \
                into another environment should do with it.

                Three things are never copied. Anything pointing at the source's database, \
                because a staging stack silently writing to production is worse than one that \
                will not start. Anything granting the source's authority — gateway tokens, \
                signing keys — which is regenerated instead. And anything the source itself \
                never had, which is reported rather than passed along as though it were set.

                This reports; it does not create. Use the values with `hatchery config set`, or \
                create the stack with `stack new` and `service new` first.
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

            let cloner = StackCloner()
            print("\(source) → \(target)  [\(spec.backend.rawValue) · \(env.rawValue)]")

            var totalUnresolved = 0
            var totalCarried = 0
            var cloned: [ClonedService] = []

            for service in spec.services {
                let url = ConfigSync.configURL(for: service, in: spec, manifestPath: path)
                let config = (try? ConfigSync.readDeclared(at: url)) ?? [:]
                // Through the planner's rewrite, not a plain stack-name substitution. A sibling
                // service's domain (`paylab.opi`) contains no stack name, so the naive version
                // left it untouched — and a clone claiming production's domain is not a clone.
                let domains = service.domains.map {
                    StackCloner.rewrite($0, from: spec, to: target, environment: env) ?? $0
                }

                let planned = try await cloner.plan(
                    service: service, from: spec, into: target, environment: env,
                    sourceConfig: config, domains: domains)

                print("")
                print("  \(planned.name)  [\(planned.kind.rawValue)]")
                if !planned.domains.isEmpty {
                    print("    domains  \(planned.domains.joined(separator: ", "))")
                }

                for key in planned.keys.sorted(by: { $0.key < $1.key }) {
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
                        print("    NEEDS    \(key.key) — \(why)")
                    }
                }

                totalUnresolved += planned.unresolved.count
                totalCarried += planned.keys.count - planned.unresolved.count
                cloned.append(planned)
            }

            print("")
            print("  \(totalCarried) key(s) resolved, \(totalUnresolved) still need a person")
            if totalUnresolved > 0 {
                print("  those are the ones that point at something only \(source) has")
            }

            guard create else {
                print("")
                print("  nothing written; re-run with --create --tofu-dir <dir> --yes")
                return
            }

            try await build(clone: cloned, from: spec, manifest: parsed, at: path, environment: env)
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

            for service in clone {
                guard let stack = current.stack(named: target) else { break }

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

                let spec = ServiceSpec(
                    name: service.name, kind: service.kind, image: service.image,
                    domains: service.domains, configFile: "\(service.name).config.json")

                let result = try await scaffolder.plan(
                    service: spec, into: target, manifest: current,
                    containerPort: 8080, network: nil, gated: false, siblings: siblings)
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

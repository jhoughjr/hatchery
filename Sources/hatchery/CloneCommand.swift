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

        func run() async throws {
            let path = try ManifestLocator.resolve(manifest)
            let parsed = try StackManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let spec = parsed.stack(named: source) else {
                throw ValidationError("no stack named '\(source)' in \(path)")
            }
            let env = Environment(rawValue: environment)

            let cloner = StackCloner()
            print("\(source) → \(target)  [\(spec.backend.rawValue) · \(env.rawValue)]")

            var totalUnresolved = 0
            var totalCarried = 0

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
            }

            print("")
            print("  \(totalCarried) key(s) resolved, \(totalUnresolved) still need a person")
            if totalUnresolved > 0 {
                print("  those are the ones that point at something only \(source) has")
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

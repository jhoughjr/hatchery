import ArgumentParser
import Foundation
import HatcheryKit

@main
struct Hatchery: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hatchery",
        abstract: "Configure, deploy and monitor MWServer stacks.",
        subcommands: [Config.self, Stack.self]
    )
}

extension Backend: ExpressibleByArgument {}

struct ServiceKindArgument: ExpressibleByArgument {
    let kind: ServiceKind

    init?(argument: String) {
        self.kind = ServiceKind(rawValue: argument)
    }

    static var allValueStrings: [String] {
        ServiceKind.known.map(\.rawValue)
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and check service configuration.",
        subcommands: [Validate.self]
    )

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check a resolved config against the service's environment contract."
        )

        @Argument(help: "Path to a JSON config map, as produced by `dokku config:export --format json`.")
        var path: String

        @Option(name: .shortAndLong, help: "Service kind. One of: \(ServiceKind.known.map(\.rawValue).joined(separator: ", ")).")
        var service: ServiceKindArgument

        @Option(name: .shortAndLong, help: "Backend the config targets. One of: \(Backend.allCases.map(\.rawValue).joined(separator: ", ")).")
        var backend: Backend

        func run() throws {
            guard let contract = EnvContract.contract(for: service.kind, backend: backend) else {
                throw ValidationError("no contract known for \(service.kind.rawValue) on \(backend.rawValue)")
            }

            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let config = try JSONDecoder().decode([String: String].self, from: data)
            let issues = ConfigValidator.validate(config, against: contract)

            for issue in issues {
                let label = issue.severity == .error ? "error" : "warning"
                print("\(label): \(issue.key): \(issue.message)")
            }

            let errors = issues.filter { $0.severity == .error }.count
            let warnings = issues.count - errors
            print("\(config.count) keys checked, \(errors) error(s), \(warnings) warning(s)")

            if !ConfigValidator.passes(issues) {
                throw ExitCode.failure
            }
        }
    }
}

struct Stack: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Work with declared stacks.",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List stacks declared in a manifest."
        )

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        func run() throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
            let parsed = try StackManifest.decode(from: data)

            guard !parsed.stacks.isEmpty else {
                print("no stacks declared in \(manifest)")
                return
            }

            for stack in parsed.stacks {
                let target = stack.host.map { " \($0)" } ?? ""
                print("\(stack.name)  [\(stack.backend.rawValue)]\(target)")
                for service in stack.services {
                    print("  \(service.name)  \(service.kind.rawValue)  \(service.image)")
                }
            }
        }
    }
}

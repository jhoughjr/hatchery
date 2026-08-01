import ArgumentParser
import Foundation
import HatcheryKit

@main
struct Hatchery: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hatchery",
        abstract: "Configure, deploy and monitor MWServer stacks.",
        subcommands: [Config.self, Stack.self, Status.self, Up.self, Down.self, Restart.self]
    )
}

/// Shared by the lifecycle verbs, which differ only in the action they perform.
struct LifecycleOptions: ParsableArguments {
    @Argument(help: "Stack to act on.")
    var stack: String

    @Option(name: .shortAndLong, help: "Path to the stack manifest.")
    var manifest: String = "hatchery.json"

    @Option(name: .shortAndLong, help: "Act on one service instead of every service.")
    var service: String?

    @Flag(name: .long, help: "Required to act on a production stack.")
    var yes: Bool = false

    func resolve() throws -> (StackSpec, [ServiceSpec]) {
        let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
        let parsed = try StackManifest.decode(from: data)

        guard let spec = parsed.stack(named: stack) else {
            throw ValidationError("no stack named '\(stack)' in \(manifest)")
        }
        // A production stack needs the flag. The environment is declared, so this is not a guess.
        if spec.resolvedEnvironment.isProduction, !yes {
            throw ValidationError(
                "stack '\(spec.name)' is in \(spec.resolvedEnvironment.rawValue); pass --yes to act on it")
        }

        guard let service else { return (spec, spec.services) }
        guard let only = spec.services.first(where: { $0.name == service }) else {
            throw ValidationError("stack '\(spec.name)' declares no service named '\(service)'")
        }
        return (spec, [only])
    }
}

/// Run one action and print a line for each service, failing the exit code if any did.
private func runLifecycle(_ action: LifecycleRunner.Action, _ options: LifecycleOptions) async throws {
    let (spec, services) = try options.resolve()
    let runner = LifecycleRunner()

    var failed = false
    for service in services {
        let result = await runner.perform(action, on: service, in: spec)
        if result.succeeded {
            print("\(service.name): \(action.label) ok")
        } else {
            failed = true
            print("\(service.name): \(action.label) failed: \(result.reason ?? "unknown")")
        }
    }
    if failed { throw ExitCode.failure }
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the services a stack declares.")
    @OptionGroup var options: LifecycleOptions
    func run() async throws { try await runLifecycle(.start, options) }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the services a stack declares.")
    @OptionGroup var options: LifecycleOptions
    func run() async throws { try await runLifecycle(.stop, options) }
}

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart the services a stack declares.")
    @OptionGroup var options: LifecycleOptions
    func run() async throws { try await runLifecycle(.restart, options) }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report the live state of the services a manifest declares."
    )

    @Option(name: .shortAndLong, help: "Path to the stack manifest.")
    var manifest: String = "hatchery.json"

    @Option(name: .shortAndLong, help: "Report one stack instead of every stack.")
    var stack: String?

    @Option(name: .shortAndLong, help: "Seconds to wait for each service.")
    var timeout: Int = 5

    func run() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
        let parsed = try StackManifest.decode(from: data)

        let stacks: [StackSpec]
        if let stack {
            guard let found = parsed.stack(named: stack) else {
                throw ValidationError("no stack named '\(stack)' in \(manifest)")
            }
            stacks = [found]
        } else {
            stacks = parsed.stacks
        }

        let reporter = StatusReporter(timeout: .seconds(timeout))
        var worst: HealthState = .ready

        for spec in stacks {
            let report = await reporter.status(of: spec)
            worst = min(worst, report.state)

            print("\(report.stack)  [\(spec.backend.rawValue)]  \(report.state.rawValue)")
            for service in report.services {
                var line = "  \(service.service.padding(toLength: 24, withPad: " ", startingAt: 0))"
                line += service.state.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
                if let latency = service.latencyMs {
                    line += "\(latency)ms".padding(toLength: 8, withPad: " ", startingAt: 0)
                } else {
                    line += "        "
                }
                if let rev = service.gitRev {
                    line += "rev=\(rev.prefix(7))  "
                }
                line += service.reasons.joined(separator: "; ")
                print(line.trimmingCharacters(in: .whitespaces).isEmpty ? line : line)
            }
        }

        // A script reads the exit code. `responding` is not a failure, because a service
        // without a readiness route still answers, and an older image is not an outage.
        if worst == .unreachable || worst == .degraded {
            throw ExitCode.failure
        }
    }
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
        subcommands: [Validate.self, Audit.self, Sync.self]
    )

    /// Write what a service is running with into the file that declares it.
    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy live config into the declared sidecar, so the two agree."
        )

        @Argument(help: "Stack to sync.")
        var stack: String

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        @Option(name: .shortAndLong, help: "Sync one service instead of every service.")
        var service: String?

        @Flag(name: .long, help: "Report the difference without writing anything.")
        var dryRun: Bool = false

        func run() async throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
            let parsed = try StackManifest.decode(from: data)

            guard let spec = parsed.stack(named: stack) else {
                throw ValidationError("no stack named '\(stack)' in \(manifest)")
            }
            let services: [ServiceSpec]
            if let service {
                guard let only = spec.services.first(where: { $0.name == service }) else {
                    throw ValidationError("stack '\(spec.name)' declares no service named '\(service)'")
                }
                services = [only]
            } else {
                services = spec.services
            }

            let reader = LiveConfigReader()
            var failed = false

            for service in services {
                do {
                    let live = try await reader.config(for: service, in: spec)
                    let url = ConfigSync.configURL(for: service, manifestPath: manifest)
                    let declared = try ConfigSync.readDeclared(at: url)
                    let difference = ConfigSync.diff(live: live, declared: declared)
                    let needsWrite = ConfigSync.needsWrite(live: live, declared: declared)

                    print("\(service.name): \(difference.summary)\(difference.isEmpty && needsWrite ? " (platform keys moved)" : "")")
                    // Key names only. The values are why the sidecar is gitignored.
                    for key in difference.added { print("    + \(key)") }
                    for key in difference.changed { print("    ~ \(key)") }
                    for key in difference.removed { print("    - \(key)") }

                    guard needsWrite else { continue }
                    if dryRun {
                        print("    (dry run, \(url.lastPathComponent) not written)")
                    } else {
                        try ConfigSync.encode(ConfigSync.merged(live: live, declared: declared))
                            .write(to: url, options: .atomic)
                        print("    wrote \(url.lastPathComponent)")
                    }
                } catch {
                    failed = true
                    print("\(service.name): could not read live config: \(error)")
                }
            }

            if failed { throw ExitCode.failure }
        }
    }

    /// Check what each service is *running with*, rather than what a file claims.
    struct Audit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read live config from every declared service and check it against its contract."
        )

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        @Option(name: .shortAndLong, help: "Audit one stack instead of every stack.")
        var stack: String?

        func run() async throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
            let parsed = try StackManifest.decode(from: data)

            let stacks: [StackSpec]
            if let stack {
                guard let found = parsed.stack(named: stack) else {
                    throw ValidationError("no stack named '\(stack)' in \(manifest)")
                }
                stacks = [found]
            } else {
                stacks = parsed.stacks
            }

            let reader = LiveConfigReader()
            var errors = 0
            var warnings = 0

            for spec in stacks {
                print("\(spec.name)  [\(spec.backend.rawValue)]")
                for service in spec.services {
                    do {
                        let config = try await reader.config(for: service, in: spec)
                        guard let contract = EnvContract.contract(for: service.kind, backend: spec.backend) else {
                            print("  \(service.name): no contract known for \(service.kind.rawValue)")
                            continue
                        }
                        let issues = ConfigValidator.validate(config, against: contract)
                        errors += issues.filter { $0.severity == .error }.count
                        warnings += issues.filter { $0.severity == .warning }.count

                        print("  \(service.name): \(config.count) keys, "
                            + "\(issues.filter { $0.severity == .error }.count) error(s), "
                            + "\(issues.filter { $0.severity == .warning }.count) warning(s)")
                        for issue in issues {
                            print("    \(issue.severity.rawValue): \(issue.key): \(issue.message)")
                        }
                    } catch {
                        // A service we cannot read is not a passing service.
                        errors += 1
                        print("  \(service.name): could not read live config: \(error)")
                    }
                }
            }

            print("\(errors) error(s), \(warnings) warning(s)")
            if errors > 0 {
                throw ExitCode.failure
            }
        }
    }

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

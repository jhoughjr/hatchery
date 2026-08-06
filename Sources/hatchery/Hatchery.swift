import ArgumentParser
import Foundation
import HatcheryKit
import HatcheryWeb

@main
struct Hatchery: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hatchery",
        abstract: "Configure, deploy and monitor MWServer stacks.",
        subcommands: [
            Config.self, Deploy.self, Doctor.self, Host.self, Serve.self, Service.self,
            Setup.self, Stack.self, State.self, Status.self,
            Up.self, Down.self, Restart.self,
        ]
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
        // Resolve before reading, so a bare invocation finds the manifest from anywhere.
        let manifest = try ManifestLocator.resolve(self.manifest)
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

struct Deploy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move a service to a new image through the declaration that owns it.",
        discussion: """
            Writes the image into the stack's tofu variables file and its manifest entry, then \
            runs `tofu plan` and shows what that would do. Nothing is applied unless --apply is \
            passed. If the plan stops evaluating, the variables file is put back as it was.

            Passing no --image reconciles tofu to the image the manifest already declares.
            """
    )

    @Argument(help: "Stack the service belongs to.")
    var stack: String

    @Argument(help: "Service to deploy.")
    var service: String

    @Option(name: .shortAndLong, help: "Image to deploy. Defaults to what the manifest declares.")
    var image: String?

    @Option(name: .shortAndLong, help: "Path to the stack manifest.")
    var manifest: String = "hatchery.json"

    @Flag(name: .long, help: "Run `tofu apply` once the plan is shown.")
    var apply: Bool = false

    @Flag(name: .long, help: "Required to deploy to a production stack, and to apply.")
    var yes: Bool = false

    @Flag(name: .long, help: "Show what would change without writing anything.")
    var dryRun: Bool = false

    func run() async throws {
        // Resolve before reading, so a bare invocation finds the manifest from anywhere.
        let manifest = try ManifestLocator.resolve(self.manifest)
        let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
        let parsed = try StackManifest.decode(from: data)
        guard let spec = parsed.stack(named: stack) else {
            throw ValidationError("no stack named '\(stack)' in \(manifest)")
        }
        if spec.resolvedEnvironment.isProduction, !yes {
            throw ValidationError(
                "stack '\(spec.name)' is in \(spec.resolvedEnvironment.rawValue); pass --yes to deploy to it")
        }
        // Applying touches the world, so it is confirmed even outside production. Writing the
        // file and planning are both reversible; an apply is not.
        if apply, !yes {
            throw ValidationError("--apply changes running infrastructure; pass --yes as well")
        }

        let deployer = Deployer()
        let intent = try deployer.plan(service: service, in: spec, image: image)

        print("\(intent.service): \(intent.variable)")
        if intent.wasDrifted {
            print("  manifest declares \(intent.declared), but the variable reads \(intent.current)")
        }
        if intent.needsWrite {
            print("  \(intent.current) -> \(intent.target)")
        } else {
            print("  already \(intent.target)")
        }

        if dryRun {
            print("  dry run; nothing written")
            return
        }

        let result = try await deployer.deploy(
            service: service, in: spec, image: image, apply: apply)

        if result.reverted {
            print("  plan failed; variables file put back")
            print(result.outcome.output)
            throw ExitCode.failure
        }

        // The manifest moves only once tofu has agreed the write evaluates. Writing it first
        // would leave the declaration claiming an image that never planned.
        if result.plan.updatesManifest {
            let updated = parsed.settingImage(stack: stack, service: service, to: result.plan.target)
            try updated.encoded().write(to: URL(fileURLWithPath: manifest))
            print("  manifest updated to \(result.plan.target)")
        }

        switch result.outcome.verdict {
        case .clean:
            print("  tofu plan: no changes")
        case .changes:
            print("  tofu plan: changes pending")
            print(result.outcome.output)
        case .failed:
            print(result.outcome.output)
            throw ExitCode.failure
        }

        if let applied = result.applied {
            print(applied)
            // An apply rewrites terraform.tfstate, which carries every value the provider has
            // seen in cleartext. It is the single most important file in the directory to have
            // a backup of, and the one most certain to have just changed.
            if let line = await StateMaintenance.seal(after: manifest) { print("  \(line)") }
        } else if result.outcome.verdict == .changes {
            print("  nothing applied; re-run with --apply --yes, or apply from \(spec.tofu?.directory ?? "the tofu directory")")
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the prerequisites for managing a stack.",
        discussion: """
            Checks the things that otherwise fail halfway through `tofu init`, or after a stack \
            has been half-written, as a provider error that says nothing about the missing SSH \
            key that actually caused it.
            """
    )

    @Option(name: .shortAndLong, help: "Backend to check. One of: \(Backend.allCases.map(\.rawValue).joined(separator: ", ")).")
    var backend: String = Backend.dokku.rawValue

    @Option(name: .long, help: "SSH target to test, e.g. dokku@192.168.0.103.")
    var host: String?

    @Option(name: .shortAndLong, help: "Check the host of a stack in the manifest instead.")
    var stack: String?

    @Option(name: .shortAndLong, help: "Path to the stack manifest.")
    var manifest: String = "hatchery.json"

    func run() async throws {
        guard let kind = Backend(rawValue: backend) else {
            throw ValidationError("unknown backend '\(backend)'")
        }
        var target = host
        var resolved = kind
        if target == nil, let name = stack {
            let path = try ManifestLocator.resolve(manifest)
            let parsed = try StackManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let spec = parsed.stack(named: name) else {
                throw ValidationError("no stack named '\(name)' in \(path)")
            }
            target = spec.host
            // The stack knows its own backend; asking for one on the command line as well
            // would let the two disagree silently.
            resolved = spec.backend
        }

        print("  \(Providers.support(for: resolved).displayName)")
        let checks = await Preflight().run(backend: resolved, host: target)
        for check in checks {
            let mark: String
            switch check.status {
            case .ok: mark = "ok  "
            case .failed: mark = "FAIL"
            case .skipped: mark = "--  "
            }
            print("  \(mark) \(check.name): \(check.detail)")
            if let remedy = check.remedy {
                print("       -> \(remedy)")
            }
        }
        if !checks.allPassed { throw ExitCode.failure }
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "How to get a box to the point hatchery can manage it.",
        discussion: """
            `hatchery doctor` tells you dokku is not answering. It cannot tell you how to put \
            dokku there. This is that half.

            A checklist rather than a script on purpose: these steps touch a machine package \
            manager, its firewall and its SSH configuration, and running that blind is not \
            something hatchery should do on your behalf.
            """
    )

    @Option(name: .shortAndLong, help: "Backend to explain. One of: \(Backend.allCases.map(\.rawValue).joined(separator: ", ")).")
    var backend: String = Backend.dokku.rawValue

    func run() throws {
        guard let kind = Backend(rawValue: backend) else {
            throw ValidationError("unknown backend '\(backend)'")
        }
        let support = Providers.support(for: kind)
        print("Setting up \(support.displayName)")
        print("")

        if !support.settings.isEmpty {
            print("Settings this backend takes:")
            for setting in support.settings {
                let origin: String
                switch setting.source {
                case .declared:
                    origin = setting.defaultValue.map { "default \($0)" } ?? "no default"
                case .environment:
                    origin = "from $\(setting.environmentKey ?? "")"
                }
                print("  --set \(setting.key)=<value>")
                print("      \(setting.label) · \(setting.required ? "required" : "optional") · \(origin)")
            }
            print("")
        }
        for (index, step) in support.setupSteps.enumerated() {
            let where_ = step.on == "box" ? "on the box" : "on this machine"
            print("\(index + 1). \(step.title)   [\(where_)]")
            print("")
            for line in step.why.split(separator: "\n") {
                print("   \(line)")
            }
            print("")
            for command in step.commands {
                print("     \(command)")
            }
            if let verify = step.verify {
                print("")
                print("   check: \(verify)")
            }
            print("")
        }
    }
}

struct Host: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save SSH targets by name, so a box is written once.",
        discussion: """
            An address is the same thing in six places — the stack that runs on it, the preflight \
            check, every logs and restart call — and retyping it is how 192.168.0.103 becomes \
            192.168.0.130 in exactly one of them.

            Refer to a saved host anywhere a target is taken, with a leading @.
            """,
        subcommands: [Add.self, List.self, Remove.self]
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a target under a name.")

        @Argument(help: "Name to save it as.")
        var name: String

        @Argument(help: "SSH target, e.g. dokku@192.168.0.103.")
        var target: String

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        func run() throws {
            let path = try ManifestLocator.resolve(manifest)
            let parsed = try StackManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
            // Normalised on the way in, so `@opi` cannot resolve to something that fails auth.
            let normalised = DokkuProvider.sshTarget(target)
            let updated = try parsed.savingHost(name, target: normalised)
            try updated.encoded().write(to: URL(fileURLWithPath: path))

            print("  @\(name) -> \(normalised)")
            if let warning = DokkuProvider.userWarning(normalised) {
                print("  note: \(warning)")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show saved and in-use targets.")

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        func run() throws {
            let path = try ManifestLocator.resolve(manifest)
            let parsed = try StackManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
            let known = HostRegistry.known(saved: parsed.savedHosts, stacks: parsed.stacks)

            guard !known.isEmpty else {
                print("  no hosts saved, and no stack declares one")
                return
            }
            for entry in known {
                // Targets already in use are shown too: they are known whether or not anyone
                // saved them, and leaving them out hides the box you are most likely to pick.
                let label = entry.name.map { "@\($0)" } ?? "(in use)"
                print("  \(label.padding(toLength: max(14, label.count), withPad: " ", startingAt: 0)) \(entry.target)")
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm", abstract: "Forget a saved target.")

        @Argument(help: "Name to forget.")
        var name: String

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        func run() throws {
            let path = try ManifestLocator.resolve(manifest)
            let parsed = try StackManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
            let updated = try parsed.removingHost(name)
            try updated.encoded().write(to: URL(fileURLWithPath: path))
            print("  forgot @\(name)")
        }
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve the dashboard on this machine.",
        discussion: """
            hatchery manages deployments, so it deliberately does not run inside one. If it were \
            a service on the box it manages, restarting that stack would kill it mid-action, and \
            the moment you most need it — the box wedged, the apps down — is exactly when it \
            would not be there. It runs as a local process instead.

            It binds 127.0.0.1 by default, which nothing off this machine can reach. Binding \
            anything else requires --token, because this process holds SSH access to every stack \
            it manages.
            """
    )

    @Option(name: .shortAndLong, help: "Path to the stack manifest.")
    var manifest: String = "hatchery.json"

    @Option(name: .long, help: "Address to bind.")
    var bind: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Port to listen on.")
    var port: Int = 7878

    @Option(name: .long, help: "Require this token on every API request. Required to bind off-host.")
    var token: String?

    func run() async throws {
        // Resolved once, at boot: the server should keep reading the same file it started with
        // rather than follow the working directory somewhere else mid-session.
        //
        // A missing manifest is not fatal here. Refusing to start without one would mean the
        // wizard that creates the first stack could never be reached — you would need a manifest
        // to get the tool that writes your first manifest.
        let resolved = (try? ManifestLocator.resolve(manifest))
            ?? Paths.join(NSHomeDirectory(), ".config/hatchery/\(ManifestLocator.defaultName)")
        let existed = FileManager.default.fileExists(atPath: resolved)

        // Read per request rather than held in memory, so editing the manifest or creating a
        // service shows up without a restart. An absent file reads as an empty manifest, which
        // is what the page renders its empty state from.
        let load: @Sendable () throws -> StackManifest = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else {
                return StackManifest()
            }
            return try StackManifest.decode(from: data)
        }
        _ = try load()  // Fail now on a malformed file rather than on the first request.

        let save: @Sendable (StackManifest, String) throws -> Void = { manifest, path in
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try manifest.encoded().write(to: URL(fileURLWithPath: path))
        }

        let api = HatcheryAPI(
            loadManifest: load, saveManifest: save, manifestPath: { resolved }, token: token)
        let server = try WebServer(api: api, host: bind, port: port, hasToken: token != nil)

        print("hatchery serving http://\(bind):\(port)")
        if BindAddress.isLoopback(bind) {
            print("  bound to loopback — not reachable from the LAN")
            print("  from elsewhere: ssh -L \(port):localhost:\(port) <this-host>")
        } else {
            print("  reachable from the network — token required on every API request")
        }
        if existed {
            print("  manifest: \(resolved)")
        } else {
            print("  no manifest yet — open the page to create your first stack")
            print("  one will be written to \(resolved)")
        }
        try await server.run()
    }
}

struct Service: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Work with the services in a stack.",
        subcommands: [New.self]
    )

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Author a new service into a stack.",
            discussion: """
                Writes the backend declaration, its image variable, and a config seeded with \
                everything hatchery is entitled to generate, then adds the service to the \
                manifest and runs `tofu plan`. Nothing is applied.

                Secrets follow three rules. A signing key is shared from a sibling service when \
                the stack already has one, because the services verify each other's tokens; it \
                is minted only when there is nothing to share with, or when --mint-keypair says \
                so. Database credentials are never invented, because the role exists before the \
                service does. Third-party credentials are never invented, and are reported as \
                needing a value.
                """
        )

        @Argument(help: "Stack to add the service to.")
        var stack: String

        @Argument(help: "Name of the new service.")
        var name: String

        @Option(name: .shortAndLong, help: "Service kind. One of: \(ServiceKind.known.map(\.rawValue).joined(separator: ", ")).")
        var kind: ServiceKindArgument

        @Option(name: .long, help: "A domain for the service. Repeat for more than one.")
        var domain: [String] = []

        @Option(name: .shortAndLong, help: "Image to deploy.")
        var image: String

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        @Option(name: .long, help: "Port the container listens on.")
        var port: Int = 8080

        @Option(name: .long, help: "Docker network the app must join to reach its database.")
        var network: String?

        @Flag(name: .long, help: "Gate the declaration behind an enable_<name> variable.")
        var gated: Bool = false

        @Flag(name: .long, help: "Mint a fresh signing key instead of sharing the stack's.")
        var mintKeypair: Bool = false

        @Flag(name: .long, help: "Show what would be written without writing anything.")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Required to author into a production stack.")
        var yes: Bool = false

        func run() async throws {
            // Resolve before reading, so a bare invocation finds the manifest from anywhere.
            let manifest = try ManifestLocator.resolve(self.manifest)
            let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
            let parsed = try StackManifest.decode(from: data)
            guard let spec = parsed.stack(named: stack) else {
                throw ValidationError("no stack named '\(stack)' in \(manifest)")
            }
            if spec.resolvedEnvironment.isProduction, !yes {
                throw ValidationError(
                    "stack '\(spec.name)' is in \(spec.resolvedEnvironment.rawValue); pass --yes")
            }
            guard !domain.isEmpty else {
                throw ValidationError("pass at least one --domain")
            }

            // Sibling config is what makes sharing possible, and it is read from the running
            // services rather than from the declared files, because the box is the source of
            // truth for what a value actually is.
            var siblings: [String: [String: String]] = [:]
            let reader = LiveConfigReader()
            for existing in spec.services {
                if let config = try? await reader.config(for: existing, in: spec) {
                    siblings[existing.name] = config
                }
            }

            let service = ServiceSpec(
                name: name,
                kind: kind.kind,
                image: image,
                domains: domain,
                configFile: "\(name).config.json"
            )

            let scaffolder = Scaffolder()
            let result = try await scaffolder.plan(
                service: service, into: stack, manifest: parsed,
                containerPort: port, network: network, gated: gated,
                siblings: siblings, mintKeypair: mintKeypair)

            for file in result.files {
                let verb = file.role == .variableAppend ? "append to" : "write"
                print("  \(verb) \(file.path)")
            }
            for secret in result.secrets {
                print("    \(secret.key.padding(toLength: max(24, secret.key.count), withPad: " ", startingAt: 0)) \(secret.origin.label)")
            }

            if dryRun {
                print("  dry run; nothing written")
                return
            }

            let written = try scaffolder.write(result, in: spec)
            print("  wrote \(written.count) file(s)")

            try result.manifest.encoded().write(to: URL(fileURLWithPath: manifest))
            print("  manifest updated")

            // Scaffolding mints secrets — a signing key among them. This is exactly the write
            // that went unsealed before, so it seals before anything else can go wrong.
            if let line = await StateMaintenance.seal(after: manifest) { print("  \(line)") }

            let unresolved = result.unresolved
            if !unresolved.isEmpty {
                print("")
                print("  \(unresolved.count) key(s) need values before this will boot:")
                for secret in unresolved {
                    if case .supplied(let reason) = secret.origin {
                        print("    \(secret.key) — \(reason)")
                    }
                }
            }

            // The plan runs last, so what it reports is the declaration as it now stands.
            guard let updatedStack = result.manifest.stack(named: stack) else { return }
            let outcome = try await Deployer().tofuPlan(in: updatedStack)
            switch outcome.verdict {
            case .clean:
                print("  tofu plan: no changes")
            case .changes:
                print("  tofu plan: changes pending")
            case .failed:
                print("  tofu plan failed:")
                print(outcome.output)
                throw ExitCode.failure
            }
        }
    }
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
        // Resolve before reading, so a bare invocation finds the manifest from anywhere.
        let manifest = try ManifestLocator.resolve(self.manifest)
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
        subcommands: [Validate.self, Audit.self, Sync.self, Set.self]
    )

    /// Fill in a value hatchery could not invent.
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set config values on a service, merging rather than replacing.",
            discussion: """
                This is how a key reported as needing a value gets one. Other keys are left \
                alone, so the minted and composed values written when the service was created \
                survive. Passing KEY= with no value removes the key.
                """
        )

        @Argument(help: "Stack the service belongs to.")
        var stack: String

        @Argument(help: "Service to set values on.")
        var service: String

        @Argument(help: "One or more KEY=VALUE pairs.")
        var values: [String]

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        func run() async throws {
            let manifestPath = try ManifestLocator.resolve(manifest)
            let parsed = try StackManifest.decode(
                from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
            guard let spec = parsed.stack(named: stack) else {
                throw ValidationError("no stack named '\(stack)' in \(manifestPath)")
            }
            guard let target = spec.service(named: service) else {
                throw ValidationError("stack '\(stack)' declares no service named '\(service)'")
            }

            var updates: [String: String] = [:]
            for pair in values {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw ValidationError("expected KEY=VALUE, got '\(pair)'")
                }
                updates[String(parts[0])] = String(parts[1])
            }

            let url = ConfigSync.configURL(for: target, in: spec, manifestPath: manifestPath)
            let declared = (try? ConfigSync.readDeclared(at: url)) ?? [:]
            let merged = ConfigSync.applying(updates, to: declared)
            try ConfigSync.encoded(merged).write(to: url)

            // Names only. The values are the reason this file is gitignored.
            for key in updates.keys.sorted() {
                print("  \(key): \(updates[key]!.isEmpty ? "removed" : "set")")
            }
            print("  wrote \(url.path)")

            if let contract = EnvContract.contract(for: target.kind, backend: spec.backend) {
                let missing = contract.required.filter { (merged[$0] ?? "").isEmpty }.sorted()
                if missing.isEmpty {
                    print("  every required key now has a value")
                } else {
                    print("  still needs: \(missing.joined(separator: ", "))")
                }
            }

            // The file just written is gitignored, so the encrypted bundle is the only copy.
            if let line = await StateMaintenance.seal(after: url.path) { print("  \(line)") }
        }
    }

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
            // Resolve before reading, so a bare invocation finds the manifest from anywhere.
            let manifest = try ManifestLocator.resolve(self.manifest)
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
            var wrote = false

            for service in services {
                do {
                    let live = try await reader.config(for: service, in: spec)
                    let url = ConfigSync.configURL(for: service, in: spec, manifestPath: manifest)
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
                        wrote = true
                    }
                } catch {
                    failed = true
                    print("\(service.name): could not read live config: \(error)")
                }
            }

            // Once for the whole run, not once per service — sealing is a whole-directory
            // operation, and doing it per service would re-tar everything each time.
            if wrote, let line = await StateMaintenance.seal(after: manifest) { print(line) }

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
            // Resolve before reading, so a bare invocation finds the manifest from anywhere.
            let manifest = try ManifestLocator.resolve(self.manifest)
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
        subcommands: [New.self, List.self, Destroy.self]
    )

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a stack where there was nothing.",
            discussion: """
                Writes a tofu configuration into an empty directory, runs `tofu init`, and \
                records the stack in a manifest beside it. This is the step that used to need \
                hand-written HCL.

                An existing configuration is never written over.
                """
        )

        @Argument(help: "Name for the new stack.")
        var name: String

        @Option(name: .long, help: "SSH target for the box. Shorthand for --set host=<value>.")
        var host: String = ""

        @Option(name: .long, help: "Directory to write the tofu configuration into.")
        var tofuDir: String

        @Option(name: .shortAndLong, help: "Backend. One of: \(Backend.allCases.map(\.rawValue).joined(separator: ", ")).")
        var backend: String = Backend.dokku.rawValue

        @Option(name: .shortAndLong, help: "Environment this stack is for: prod, staging, or dev.")
        var environment: String = Environment.dev.rawValue

        @Option(
            name: .long,
            help: "Backend setting as key=value. Repeat for more than one; `hatchery setup --backend <name>` lists them.")
        var set: [String] = []

        @Option(name: .shortAndLong, help: "Manifest to add the stack to. Defaults to one beside the tofu directory.")
        var manifest: String?

        func run() async throws {
            guard let kind = Backend(rawValue: backend) else {
                throw ValidationError("unknown backend '\(backend)'")
            }

            // An existing manifest is extended rather than replaced, so a second stack does not
            // wipe out the first.
            let path = manifest ?? StackBootstrapper.manifestPath(inTofuDirectory: tofuDir)
            let existing = try? StackManifest.decode(
                from: Data(contentsOf: URL(fileURLWithPath: Paths.expanded(path))))

            let bootstrapper = StackBootstrapper()
            var values: [String: String] = [:]
            for pair in set {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw ValidationError("expected key=value, got '\(pair)'")
                }
                values[String(parts[0])] = String(parts[1])
            }
            // Unknown keys are refused rather than silently ignored, so a typo does not look
            // like a setting that did nothing.
            let declared = Set(Providers.support(for: kind).settings.map(\.key))
            for key in values.keys where !declared.contains(key) {
                throw ValidationError(
                    "\(kind.rawValue) has no setting '\(key)'; it declares: "
                        + declared.sorted().joined(separator: ", "))
            }

            let resolvedHost = try HostRegistry.resolve(host, in: existing?.savedHosts ?? [:])
            let planned = try bootstrapper.plan(
                name: name, backend: kind, host: resolvedHost, tofuDir: tofuDir,
                environment: Environment(rawValue: environment), settings: values,
                into: existing, manifestPath: Paths.expanded(path))

            for file in planned.files {
                print("  write \(Paths.join(planned.stack.tofu?.directory ?? "", file.path))")
            }

            let created = try await bootstrapper.create(planned)
            try created.manifest.encoded().write(to: URL(fileURLWithPath: created.manifestPath))
            print("  wrote \(created.manifestPath)")
            print("  tofu init: ok")
            if let line = await StateMaintenance.seal(after: created.manifestPath) {
                print("  \(line)")
            }
            print("")
            print("  next: hatchery service new \(name) <service> --kind <kind> --domain <d> --image <ref>")
        }
    }

    struct Destroy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Destroy a stack's infrastructure and forget it.",
            discussion: """
                Shows what `tofu destroy` would remove, and does nothing without --yes. This is \
                the one action with no undo, so the stack name has to be repeated back with \
                --confirm before anything is destroyed.

                The tofu directory and the config files are left on disk. They hold the state \
                file and real secrets, and forgetting a declaration should not also delete the \
                only record of what was there.
                """
        )

        @Argument(help: "Stack to destroy.")
        var stack: String

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        @Option(name: .long, help: "Repeat the stack name to confirm.")
        var confirm: String?

        @Flag(name: .long, help: "Actually destroy. Without it, only the plan is shown.")
        var yes: Bool = false

        func run() async throws {
            let path = try ManifestLocator.resolve(manifest)
            let parsed = try StackManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let spec = parsed.stack(named: stack) else {
                throw ValidationError("no stack named '\(stack)' in \(path)")
            }

            let deployer = Deployer()
            let summary = try await deployer.destroyPlan(in: spec)
            print("\(spec.name)  [\(spec.backend.rawValue) · \(spec.resolvedEnvironment.rawValue)]")
            if summary.isNoop {
                // Declared but never applied. Listing the services here would read as though
                // they were about to be torn off a box that has never heard of them.
                print("  nothing to destroy — this stack owns no infrastructure")
                print("  removing it drops the declaration only")
            } else {
                print("  would destroy: \(summary.headline)")
                for service in spec.services {
                    print("    \(service.name)  \(service.image)")
                }
            }

            guard yes else {
                print("")
                print("  nothing destroyed; re-run with --yes --confirm \(spec.name)")
                return
            }
            guard confirm == spec.name else {
                throw ValidationError(
                    "confirmation did not match; pass --confirm \(spec.name) to destroy it")
            }

            let output = try await deployer.tofuDestroy(in: spec)
            print(output)
            try parsed.removing(stack: spec.name).encoded()
                .write(to: URL(fileURLWithPath: path))
            print("  removed '\(spec.name)' from \(path)")
            print("  left in place: \(spec.tofu?.directory ?? "the tofu directory") (state and config)")
            // A destroy empties tfstate. Sealing keeps the backup matching what is on disk, so
            // the next status call does not read a torn-down stack as unsealed drift.
            if let line = await StateMaintenance.seal(after: path) { print("  \(line)") }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List stacks declared in a manifest."
        )

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        func run() throws {
            // Resolve before reading, so a bare invocation finds the manifest from anywhere.
            let manifest = try ManifestLocator.resolve(self.manifest)
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

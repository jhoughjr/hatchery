import Foundation
import HatcheryKit

/// What a dokku app says about itself, read as the dokku user. Everything a manifest
/// entry needs, and nothing that needs an admin channel.
public struct AppFacts: Sendable, Equatable {
    public let name: String
    /// The image the app was deployed from. dokku retags every deploy as
    /// `dokku/<app>:latest`, so the real reference comes from the alternate-tags label it
    /// keeps on the container, with the retag as the fallback.
    public let image: String
    public let domains: [String]
    /// The port the container listens on, from the http port map.
    public let containerPort: Int
    /// The host-facing port of the same mapping, e.g. `"80"` in `http:80:8080`.
    public let hostPort: String
    public let network: String?
    public let config: [String: String]
    /// Whether the box currently disables this app's zero-downtime checks.
    public let checksDisabled: Bool

    public init(
        name: String, image: String, domains: [String], containerPort: Int, hostPort: String = "80",
        network: String?, config: [String: String], checksDisabled: Bool = false
    ) {
        self.name = name
        self.image = image
        self.domains = domains
        self.containerPort = containerPort
        self.hostPort = hostPort
        self.network = network
        self.config = config
        self.checksDisabled = checksDisabled
    }
}

public enum AdoptError: Error, Equatable, CustomStringConvertible {
    case notOnBox(app: String, box: String)
    case alreadyDeclared(app: String, stack: String)
    case stackNotOnBox(stack: String, box: String)
    case kindUnknown(app: String, image: String)
    case unreadable(String)
    /// A container is declared on a stack of the `host` backend, and the named stack is on another.
    case stackNotOnHost(stack: String, backend: String, box: String)
    /// The file the box holds under a job's name is neither a launchd agent nor a systemd unit.
    /// The value names the shape that was expected.
    case notAJobFile(String)

    public var description: String {
        switch self {
        case .notOnBox(let app, let box):
            return "no app named '\(app)' on \(box)"
        case .alreadyDeclared(let app, let stack):
            return "'\(app)' is already declared by stack '\(stack)'"
        case .stackNotOnBox(let stack, let box):
            return "stack '\(stack)' is not a dokku stack on \(box)"
        case .kindUnknown(let app, let image):
            return "cannot tell the kind of '\(app)' from its image \(image); "
                + "pass --kind-file, add it to the registry, or pass --kind"
        case .unreadable(let what):
            return "the box did not answer \(what)"
        case .stackNotOnHost(let stack, let backend, let box):
            return """
                stack '\(stack)' is on the \(backend) backend, and a container is declared on a host \
                stack. A host stack for \(box) is made with: hatchery stack new <name> --backend host \
                --host \(box) --tofu-dir <dir>
                """
        case .notAJobFile(let shape):
            return "the box holds no job by that name; adopt reads \(shape)"
        }
    }
}

/// The outcome of an adopt plan: the files to write, the manifest with the service in it,
/// and the import the declaration needs before tofu agrees the app already exists.
public struct AdoptResult: Sendable, Equatable {
    public let service: ServiceSpec
    public let files: [GeneratedFile]
    public let manifest: StackManifest
    /// The tofu import that binds the written declaration to the running app. Adopt does
    /// not run it, because it needs the stack's tofu state, and that is apply's domain.
    public let importCommand: String
}

/// Turns a find from a scan into a manifest entry.
///
/// Adopt reads what the box knows and writes what hatchery would have written had it
/// authored the app itself: the tofu declaration, the config file, and the manifest line.
/// The config comes from the box rather than from minting, because the values that run
/// are the truth and inventing new ones would break a working app.
public struct Adopter: Sendable {
    private let execute: CommandExecutor

    public init(execute: @escaping CommandExecutor = ShellRunner.liveExecutor) {
        self.execute = execute
    }

    /// Everything the box will say about one app, as the dokku user.
    public func facts(for app: String, on box: String) async throws -> AppFacts {
        let domains = try await self.answer("domains:report \(app) --domains-app-vhosts", on: box)
        let ports = try await self.answer("ports:report \(app) --ports-map", on: box)
        let network = try await self.answer(
            "network:report \(app) --network-attach-post-create", on: box)
        let inspect = try await self.answer("ps:inspect \(app)", on: box)
        let exported = try await self.answer("config:export --format json \(app)", on: box)
        // Best-effort: an older dokku without the checks plugin's report flag answers nothing
        // useful here, and that is not a reason to fail the whole read.
        let checksDisabled = (try? await self.answer(
            "checks:report \(app) --checks-disabled-list", on: box)) ?? ""

        let config = (try? JSONDecoder().decode([String: String].self, from: Data(exported.utf8)))
            ?? [:]
        return AppFacts(
            name: app,
            image: Self.image(fromInspect: inspect, app: app),
            domains: domains.split(separator: " ").map(String.init),
            containerPort: Self.containerPort(fromPortMap: ports),
            hostPort: Self.hostPort(fromPortMap: ports),
            network: network.isEmpty ? nil : network,
            config: config,
            checksDisabled: !checksDisabled.isEmpty)
    }

    /// The kind an image name implies. The kinds hatchery knows carry their name in their
    /// image, so a match is a strong signal. No match is a question for the operator.
    public static func inferKind(fromImage image: String) -> ServiceKind? {
        let lowered = image.lowercased()
        if lowered.contains("mwserver") { return .mwserver }
        if lowered.contains("payment") { return .paymentGateway }
        if lowered.contains("communication") || lowered.contains("comlab") {
            return .communicationGateway
        }
        if lowered.contains("gsx") { return .gsxGateway }
        return nil
    }

    /// Resolves the kind for `app`, trying each source in this order and refusing only when
    /// none of them says: a kind file named directly, one the registry already holds under
    /// the app's own name, `--kind`, then the image. A resolution from a file carries it, so
    /// `plan` can take the file's `healthcheck` and `port`.
    public static func resolveKind(
        app: String, kindFilePath: String?, kindOption: ServiceKind?, image: String,
        registry: KindRegistry
    ) throws -> (kind: ServiceKind, kindFile: KindFile?) {
        if let kindFilePath {
            let file = try KindFile.load(atPath: kindFilePath)
            return (ServiceKind(rawValue: file.kind), file)
        }
        if let found = try? registry.kindFile(for: ServiceKind(rawValue: app)) {
            return (ServiceKind(rawValue: found.kind), found)
        }
        if let kindOption {
            return (kindOption, nil)
        }
        if let inferred = inferKind(fromImage: image) {
            return (inferred, nil)
        }
        throw AdoptError.kindUnknown(app: app, image: image)
    }

    /// The plan: the service joins `stackName`, with the box's config in place of minted
    /// values. The stack must be a dokku stack on the same box, because the declaration
    /// the scaffolder writes targets the stack's host.
    ///
    /// `kindFile`, when present, wins for `healthcheck` and `port` (when it has one): the
    /// service's own word about its own contact surface. The config sidecar still carries the
    /// box's measured keys either way.
    public func plan(
        _ facts: AppFacts, kind: ServiceKind, into stackName: String, box: String,
        manifest: StackManifest, kindFile: KindFile? = nil
    ) async throws -> AdoptResult {
        guard let stack = manifest.stack(named: stackName), stack.backend == .dokku,
            let host = stack.hostAddress, box.hasSuffix(host)
        else {
            throw AdoptError.stackNotOnBox(stack: stackName, box: box)
        }
        for declared in manifest.stacks
        where declared.services.contains(where: { $0.name == facts.name }) {
            throw AdoptError.alreadyDeclared(app: facts.name, stack: declared.name)
        }

        let service = ServiceSpec(
            name: facts.name, kind: kind, image: facts.image, domains: facts.domains,
            configFile: "\(facts.name).config.json",
            healthPath: kindFile?.healthcheck)
        let scaffolded = try await Scaffolder().plan(
            service: service, into: stackName, manifest: manifest,
            containerPort: kindFile?.port ?? facts.containerPort, network: facts.network,
            hostPort: facts.hostPort, checksDisabled: facts.checksDisabled)

        // The scaffolder minted a config. The box's config replaces it wholesale: keys the
        // contract does not know are kept too, because the running app reads them.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configJSON = String(decoding: try encoder.encode(facts.config), as: UTF8.self)
        let files = scaffolded.files.map { file -> GeneratedFile in
            guard file.role == .config else { return file }
            return GeneratedFile(path: file.path, contents: configJSON + "\n", role: .config)
        }

        return AdoptResult(
            service: scaffolded.service, files: files, manifest: scaffolded.manifest,
            importCommand: "tofu import dokku_app.\(tofuIdentifier(for: facts.name)) \(facts.name)")
    }

    // MARK: containers

    /// Everything the box will say about one container, as an account that can drive the daemon.
    ///
    /// One `docker inspect` carries the whole run: the image, the network, the mounts, the ports, the
    /// restart policy and the environment. A dokku app takes six calls to say as much, because dokku keeps
    /// each of those in a report of its own. For local targets, the command runs without SSH.
    public func container(named name: String, on box: String) async throws -> ContainerInspection {
        let output: CommandOutput
        do {
            let argv = Self.isLocalTarget(box)
                ? ["docker", "inspect", name]
                : ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", box,
                   "docker inspect \(name)"]
            output = try await self.execute(argv, nil)
        } catch {
            throw AdoptError.unreadable("docker inspect \(name)")
        }
        guard output.status == 0 else {
            throw AdoptError.notOnBox(app: name, box: box)
        }
        return try ContainerInspection.decode(Data(output.standardOutput.utf8))
    }

    /// What the image itself sets, so adopt can tell the run's own environment from the image's.
    ///
    /// A container's inspect reports the image's environment and the run's as one list.
    /// This second call is the only way to separate them.
    /// Without it a sidecar records the image's build facts as declarations.
    /// For local targets, the command runs without SSH.
    public func imageEnvironment(for image: String, on box: String) async throws -> [String: String] {
        let output: CommandOutput
        do {
            let argv = Self.isLocalTarget(box)
                ? ["docker", "image", "inspect", image, "--format", "{{json .Config.Env}}"]
                : ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", box,
                   "docker image inspect \(image) --format '{{json .Config.Env}}'"]
            output = try await self.execute(argv, nil)
        } catch {
            throw AdoptError.unreadable("docker image inspect \(image)")
        }
        guard output.status == 0 else {
            throw AdoptError.unreadable("docker image inspect \(image)")
        }
        return try ContainerInspection.imageEnvironment(Data(output.standardOutput.utf8))
    }

    /// The plan for a container: the service joins `stackName` on the host backend, with the box's own
    /// environment in place of minted values, and a declaration that imports what is already running.
    ///
    /// `kindFile`, when the registry holds one under the container's name, wins for `healthcheck`. Without
    /// one the service records no health path, and the container's own HEALTHCHECK is what status reads.
    /// `imageEnvironment` is what `imageEnvironment(for:on:)` read, and the sidecar keeps only what the run adds to it.
    /// `replacing` regenerates a service the named stack already declares.
    /// Without `refreshConfig` the sidecar and the secrets file it already has are left alone.
    public func planContainer(
        _ facts: ContainerInspection, kind: ServiceKind, into stackName: String, box: String,
        manifest: StackManifest, manifestPath: String, kindFile: KindFile? = nil,
        imageEnvironment: [String: String] = [:], replacing: Bool = false,
        refreshConfig: Bool = false
    ) async throws -> AdoptResult {
        guard let stack = manifest.stack(named: stackName) else {
            throw AdoptError.stackNotOnBox(stack: stackName, box: box)
        }
        guard stack.backend == .host else {
            throw AdoptError.stackNotOnHost(
                stack: stackName, backend: stack.backend.rawValue, box: box)
        }
        guard let host = stack.hostAddress, box.hasSuffix(host) else {
            throw AdoptError.stackNotOnBox(stack: stackName, box: box)
        }
        for declared in manifest.stacks
        where declared.services.contains(where: { $0.name == facts.name }) {
            // A replace regenerates the service where it already stands.
            // A service declared in another stack is still a refusal, because moving it is not what this door does.
            guard replacing, declared.name == stackName else {
                throw AdoptError.alreadyDeclared(app: facts.name, stack: declared.name)
            }
        }

        let service = ServiceSpec(
            name: facts.name, kind: kind, image: facts.image,
            configFile: "\(facts.name).config.json",
            healthPath: kindFile?.healthcheck,
            container: facts.spec)
        let scaffolded = try await Scaffolder().plan(
            service: service, into: stackName, manifest: manifest, containerID: facts.id,
            manifestPath: manifestPath, replacing: replacing)

        // The scaffolder minted nothing, because a container's kind carries no built-in contract. The box's
        // environment replaces the empty sidecar, split by whatever contract the kind does have.
        let contract = EnvContract.contract(
            for: kind, backend: .host, registry: KindRegistry(manifestPath: manifestPath))
        let declared = facts.declaredEnvironment(against: imageEnvironment, contract: contract)
        let split = contract.map { ConfigSync.split(declared, by: $0) }
            ?? (config: declared, secrets: [:])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configJSON = String(decoding: try encoder.encode(split.config), as: UTF8.self)
        var files = try scaffolded.files.map { file -> GeneratedFile in
            guard file.role == .config else { return file }
            let contents = file.path == service.configFile
                ? configJSON
                : String(decoding: try encoder.encode(split.secrets), as: UTF8.self)
            return GeneratedFile(path: file.path, contents: contents + "\n", role: .config)
        }
        // The scaffolder writes a secrets file only when it minted something, and a container mints nothing,
        // so the file the split needs is added here.
        let secretsName = ConfigSync.secretsURL(
            for: service, in: stack, manifestPath: manifestPath)?.lastPathComponent
        if !split.secrets.isEmpty, let secretsFile = secretsName,
            !files.contains(where: { $0.path == secretsFile })
        {
            let secretsJSON = String(decoding: try encoder.encode(split.secrets), as: UTF8.self)
            files.append(
                GeneratedFile(path: secretsFile, contents: secretsJSON + "\n", role: .config))
        }

        // A replace rewrites the declaration and the manifest entry.
        // The sidecar and the secrets file hold what the service is running with, so they stay as they are until --refresh-config asks for them.
        if replacing, !refreshConfig {
            files.removeAll { $0.role == .config }
        }

        return AdoptResult(
            service: scaffolded.service, files: files, manifest: scaffolded.manifest,
            importCommand: "tofu import docker_container.\(tofuIdentifier(for: facts.name)) \(facts.id)")
    }

    // MARK: jobs

    /// The plist or the unit the box holds under this name, read as one job.
    ///
    /// A Mac is asked for the label as given and then for the label with the estate's prefix, because a person
    /// naming a job at the command line names the service and not the reverse-domain label.
    /// Linux is asked for the service, and then for its timer if one exists.
    /// On Linux, a label `cron:<n>` reads line n (1-based, counting non-comment, non-empty lines) from the crontab.
    public func job(
        named label: String, on box: String, platform: HostPlatform, name: String? = nil
    ) async throws -> ReadJob {
        if platform == .linux, label.hasPrefix("cron:") {
            guard let lineStr = label.dropFirst("cron:".count) as Substring?, let lineNum = Int(lineStr), lineNum > 0 else {
                throw AdoptError.notAJobFile("a systemd user unit named \(label)")
            }
            return try await self.jobFromCrontab(lineNum: lineNum, on: box, name: name)
        }

        switch platform {
        case .darwin:
            let agents = "$HOME/Library/LaunchAgents"
            let text = try await self.read(
                "cat \"\(agents)/\(label).plist\" 2>/dev/null "
                    + "|| cat \"\(agents)/net.jimmyhoughjr.\(label).plist\"",
                on: box, what: "a launchd agent named \(label)")
            return try JobReader.agent(Data(text.utf8))

        case .linux:
            let units = "$HOME/.config/systemd/user"
            let service = try await self.read(
                "cat \"\(units)/\(label).service\"",
                on: box, what: "a systemd user unit named \(label)")
            let timerCommand = "cat \"\(units)/\(label).timer\" 2>/dev/null || echo ''"
            let timer = await self.readOptional(timerCommand, on: box)
            return try JobReader.unit(
                named: label, service: service, timer: timer.isEmpty ? nil : timer)
        }
    }

    /// One crontab line at the given 1-based index, read from the box and parsed into a job.
    ///
    /// The job's name is derived from the command's basename without extension, unless the caller provides one.
    /// The schedule is converted from cron fields to systemd OnCalendar format.
    private func jobFromCrontab(lineNum: Int, on box: String, name: String?) async throws -> ReadJob {
        let crontabText = try await self.read("crontab -l 2>/dev/null || echo ''", on: box, what: "the crontab")
        var nonCommentLines: [(index: Int, line: String)] = []
        for (fullIndex, line) in crontabText.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            nonCommentLines.append((index: nonCommentLines.count + 1, line: String(line)))
        }

        guard lineNum > 0, lineNum <= nonCommentLines.count else {
            throw AdoptError.unreadable("crontab line \(lineNum); the crontab has \(nonCommentLines.count) non-comment, non-empty line(s)")
        }

        let cronLine = nonCommentLines[lineNum - 1].line
        guard let parsed = Scanner.parseCrontabLine(cronLine) else {
            throw AdoptError.unreadable("crontab line \(lineNum): failed to parse")
        }

        var program = parsed.program
        if let redirectIndex = program.range(of: ">>") {
            let beforeRedirect = String(program[program.startIndex..<redirectIndex.lowerBound]).trimmingCharacters(in: .whitespaces)
            program = beforeRedirect
        }

        let programWords = JobReader.words(program)
        guard !programWords.isEmpty else {
            throw AdoptError.unreadable("crontab line \(lineNum): no program")
        }

        let serviceName = name ?? Self.serviceName(for: programWords[0])
        let job = JobSpec(
            program: programWords,
            workingDirectory: nil,
            schedule: parsed.schedule.map { .at($0) },
            keepAlive: false,
            log: parsed.log,
            runAtLoad: false,
            label: nil)

        return ReadJob(label: "cron:\(lineNum)", name: serviceName, job: job, environment: [:])
    }

    /// The service name derived from a program path: the basename without extension.
    private static func serviceName(for program: String) -> String {
        let expanded = program.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        let lastComponent = (expanded as NSString).lastPathComponent
        let noExtension = (lastComponent as NSString).deletingPathExtension
        return noExtension.isEmpty ? lastComponent : noExtension
    }

    /// The line between a unit and its timer, in the one command both are asked for.
    static let unitMarker = "--- hatchery timer ---"

    /// The plan for a job: the service joins `stackName` on the host backend, and the plist or the unit is the
    /// declaration's artifact beside it.
    ///
    /// No tofu file is written and no import is needed. A job's declaration is the manifest, and the artifact is what
    /// the box follows, so `importCommand` is empty and the caller prints nothing after the write.
    /// The supervisor's own environment lands in the sidecar, split by whatever contract the kind has. A key the
    /// contract does not speak for is split by ``isSecretEnvironmentName(_:)`` instead, so a credential nobody
    /// declared still reaches the secrets file. The plist and the unit carry `${NAME}` for every secret key, and
    /// the value reaches neither of them.
    public func planJob(
        _ read: ReadJob, kind: ServiceKind, into stackName: String, box: String,
        manifest: StackManifest, manifestPath: String, replacing: Bool = false
    ) throws -> AdoptResult {
        guard let stack = manifest.stack(named: stackName) else {
            throw AdoptError.stackNotOnBox(stack: stackName, box: box)
        }
        guard stack.backend == .host else {
            throw AdoptError.stackNotOnHost(
                stack: stackName, backend: stack.backend.rawValue, box: box)
        }
        guard let host = stack.hostAddress, box.hasSuffix(host) else {
            throw AdoptError.stackNotOnBox(stack: stackName, box: box)
        }
        for declared in manifest.stacks
        where declared.services.contains(where: { $0.name == read.name }) {
            guard replacing, declared.name == stackName else {
                throw AdoptError.alreadyDeclared(app: read.name, stack: declared.name)
            }
        }

        var job = read.job
        // A label the estate itself would write adds nothing to the declaration, and one it would not is the only
        // handle the box answers to.
        if job.label == HostProvider.jobLabel(
            for: ServiceSpec(name: read.name, kind: kind, image: "", configFile: ""),
            platform: stack.platform)
        {
            job.label = nil
        }

        // Extract secrets from the job's command line before adding to the service.
        let (cleanProgram, programSecrets) = Self.extractSecrets(from: job.program)
        job.program = cleanProgram

        let service = ServiceSpec(
            name: read.name, kind: kind, image: "",
            configFile: "\(read.name).config.json",
            job: job)

        let contract = EnvContract.contract(
            for: kind, backend: .host, registry: KindRegistry(manifestPath: manifestPath))
        let split = contract.map { ConfigSync.split(read.environment, by: $0) }
            ?? (config: read.environment, secrets: [:])
        var config = split.config
        var jobSecrets = split.secrets
        // The contract wins in both directions for a key it knows, and the name rule answers for every other key.
        for (key, value) in config {
            guard contract?.recognizes(key) != true, Self.isSecretEnvironmentName(key) else { continue }
            jobSecrets[key] = value
            config[key] = nil
        }
        jobSecrets.merge(programSecrets) { _, new in new }

        var files = try HostProvider.jobFiles(
            for: service, platform: stack.platform,
            environment: read.environment, secretKeys: Set(jobSecrets.keys))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        files.append(
            GeneratedFile(
                path: service.configFile,
                contents: String(decoding: try encoder.encode(config), as: UTF8.self) + "\n",
                role: .config))
        if !jobSecrets.isEmpty {
            files.append(
                GeneratedFile(
                    path: "\(read.name).secrets.json",
                    contents: String(decoding: try encoder.encode(jobSecrets), as: UTF8.self) + "\n",
                    role: .config))
        }

        var updated = manifest
        for index in updated.stacks.indices where updated.stacks[index].name == stackName {
            updated.stacks[index].services.removeAll { $0.name == read.name }
            updated.stacks[index].services.append(service)
        }
        return AdoptResult(service: service, files: files, manifest: updated, importCommand: "")
    }

    /// One command on the box, whose output is the answer and whose nonzero status is a refusal.
    /// For local targets, the command runs on this machine without SSH.
    private func read(_ command: String, on box: String, what: String) async throws -> String {
        let output: CommandOutput
        do {
            let argv = Self.isLocalTarget(box)
                ? ["sh", "-c", command]
                : ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", box, command]
            output = try await self.execute(argv, nil)
        } catch {
            throw AdoptError.unreadable(what)
        }
        guard output.status == 0 else { throw AdoptError.notAJobFile(what) }
        return output.standardOutput
    }

    /// One command on the box, whose output is returned even if the command fails.
    /// For local targets, the command runs on this machine without SSH.
    private func readOptional(_ command: String, on box: String) async -> String {
        do {
            let argv = Self.isLocalTarget(box)
                ? ["sh", "-c", command]
                : ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", box, command]
            let output = try await self.execute(argv, nil)
            return output.standardOutput
        } catch {
            return ""
        }
    }

    /// Whether a target refers to the local machine.
    static func isLocalTarget(_ target: String) -> Bool {
        let normalized = target.trimmingCharacters(in: .whitespaces).lowercased()
        return ["local", "localhost", "127.0.0.1"].contains(normalized)
    }

    // MARK: parsing

    /// Extracts credential flags and their values from a program's argument array.
    /// Replaces the values with `${KEY}` references and returns both the cleaned program and a dictionary of secrets.
    /// Flag names are upper-cased and dashes converted to underscores for the secret key.
    public static func extractSecrets(from program: [String]) -> (program: [String], secrets: [String: String]) {
        let credentialFlags = [
            "--token", "--password", "--secret", "--api-key", "--apikey", "--auth", "--key",
        ]
        var result = program
        var secrets: [String: String] = [:]
        var indexesToRemove: [Int] = []

        for (index, argument) in result.enumerated() {
            let parts = argument.split(separator: "=", maxSplits: 1)
            let flag = parts.first.map(String.init) ?? ""
            let flagLower = flag.lowercased()

            guard credentialFlags.contains(flagLower) else { continue }

            if parts.count == 2 {
                // Format: --token=value
                let value = String(parts[1])
                let secretKey = Self.secretKeyName(for: flag)
                secrets[secretKey] = value
                result[index] = "\(flag)=${\(secretKey)}"
            } else if index + 1 < result.count {
                // Format: --token value
                let value = result[index + 1]
                let secretKey = Self.secretKeyName(for: flag)
                secrets[secretKey] = value
                result[index + 1] = "${\(secretKey)}"
            }
        }

        return (result, secrets)
    }

    /// Converts a flag name to a secret key name.
    /// `--token` becomes `TOKEN`, `--api-key` becomes `API_KEY`.
    public static func secretKeyName(for flag: String) -> String {
        var name = flag
        if name.hasPrefix("--") {
            name = String(name.dropFirst(2))
        }
        return name.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    /// The words that make an environment name a credential.
    ///
    /// These are the words the credential flags carry, read as names rather than as flags.
    static let secretEnvironmentWords = [
        "KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "API_KEY", "APIKEY", "AUTH",
    ]

    /// Whether an environment name says its value is a credential.
    ///
    /// The name is read in its `_`-separated parts, and one of the words above must be the whole name, its first parts, or its last parts.
    /// `VAULT_APP_KEY` and `AUTH_HEADER` are credentials, and `VAULT_APP` is not.
    /// A name ending `_FILE` is never a credential, because it holds a path and the file at that path holds the value.
    /// This is the fallback for a name no kind file speaks for, and a kind file's own word wins over it.
    public static func isSecretEnvironmentName(_ name: String) -> Bool {
        let upper = name.uppercased()
        guard !upper.hasSuffix("_FILE") else { return false }
        let parts = upper.split(separator: "_").map(String.init)
        for word in Self.secretEnvironmentWords {
            let wordParts = word.split(separator: "_").map(String.init)
            guard parts.count >= wordParts.count else { continue }
            if Array(parts.prefix(wordParts.count)) == wordParts { return true }
            if Array(parts.suffix(wordParts.count)) == wordParts { return true }
        }
        return false
    }

    static func image(fromInspect json: String, app: String) -> String {
        struct Container: Decodable {
            struct Config: Decodable {
                let Image: String
                let Labels: [String: String]?
            }
            let Config: Config
        }
        let fallback = "dokku/\(app):latest"
        guard let containers = try? JSONDecoder().decode([Container].self, from: Data(json.utf8)),
            let first = containers.first
        else { return fallback }
        if let raw = first.Config.Labels?["com.dokku.docker-image-labeler/alternate-tags"],
            let tags = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)),
            let tag = tags.first
        {
            return tag
        }
        return first.Config.Image
    }

    /// `http:80:8080` → 8080. The last field of the first http mapping.
    static func containerPort(fromPortMap map: String) -> Int {
        for entry in map.split(separator: " ") {
            let parts = entry.split(separator: ":")
            if parts.count == 3, parts[0] == "http", let port = Int(parts[2]) { return port }
        }
        return 8080
    }

    /// `http:80:8080` → `"80"`. The middle field of the same mapping, so the tofu declaration
    /// answers the domain on the port the app actually maps rather than an assumed `"80"`.
    static func hostPort(fromPortMap map: String) -> String {
        for entry in map.split(separator: " ") {
            let parts = entry.split(separator: ":")
            if parts.count == 3, parts[0] == "http" { return String(parts[1]) }
        }
        return "80"
    }

    private func answer(_ command: String, on box: String) async throws -> String {
        let argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", box]
            + command.split(separator: " ").map(String.init)
        let output: CommandOutput
        do {
            output = try await self.execute(argv, nil)
        } catch {
            throw AdoptError.unreadable(command)
        }
        guard output.status == 0 else { throw AdoptError.unreadable(command) }
        return output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

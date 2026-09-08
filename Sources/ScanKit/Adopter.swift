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
    /// each of those in a report of its own.
    public func container(named name: String, on box: String) async throws -> ContainerInspection {
        let output: CommandOutput
        do {
            output = try await self.execute(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", box,
                 "docker inspect \(name)"], nil)
        } catch {
            throw AdoptError.unreadable("docker inspect \(name)")
        }
        guard output.status == 0 else {
            throw AdoptError.notOnBox(app: name, box: box)
        }
        return try ContainerInspection.decode(Data(output.standardOutput.utf8))
    }

    /// The plan for a container: the service joins `stackName` on the host backend, with the box's own
    /// environment in place of minted values, and a declaration that imports what is already running.
    ///
    /// `kindFile`, when the registry holds one under the container's name, wins for `healthcheck`. Without
    /// one the service records no health path, and the container's own HEALTHCHECK is what status reads.
    public func planContainer(
        _ facts: ContainerInspection, kind: ServiceKind, into stackName: String, box: String,
        manifest: StackManifest, manifestPath: String, kindFile: KindFile? = nil
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
            throw AdoptError.alreadyDeclared(app: facts.name, stack: declared.name)
        }

        let service = ServiceSpec(
            name: facts.name, kind: kind, image: facts.image,
            configFile: "\(facts.name).config.json",
            healthPath: kindFile?.healthcheck,
            container: facts.spec)
        let scaffolded = try await Scaffolder().plan(
            service: service, into: stackName, manifest: manifest, containerID: facts.id,
            manifestPath: manifestPath)

        // The scaffolder minted nothing, because a container's kind carries no built-in contract. The box's
        // environment replaces the empty sidecar, split by whatever contract the kind does have.
        let contract = EnvContract.contract(
            for: kind, backend: .host, registry: KindRegistry(manifestPath: manifestPath))
        let split = contract.map { ConfigSync.split(facts.environment, by: $0) }
            ?? (config: facts.environment, secrets: [:])

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

        return AdoptResult(
            service: scaffolded.service, files: files, manifest: scaffolded.manifest,
            importCommand: "tofu import docker_container.\(tofuIdentifier(for: facts.name)) \(facts.id)")
    }

    // MARK: parsing

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

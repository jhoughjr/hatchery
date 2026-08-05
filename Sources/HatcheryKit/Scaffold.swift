import Foundation

public enum ScaffoldError: Error, CustomStringConvertible, Equatable {
    case serviceExists(stack: String, service: String)
    case noTofuBinding(stack: String)
    case fileExists(String)

    public var description: String {
        switch self {
        case .serviceExists(let stack, let service):
            return "stack '\(stack)' already declares a service named '\(service)'"
        case .noTofuBinding(let stack):
            return "stack '\(stack)' declares no tofu directory, so there is nowhere to write"
        case .fileExists(let path):
            return "\(path) already exists; hatchery will not overwrite it"
        }
    }
}

/// Everything authoring one service produced.
public struct ScaffoldResult: Sendable, Equatable {
    public let service: ServiceSpec
    public let files: [GeneratedFile]
    public let secrets: [SecretResolution]
    /// The manifest with the new service in it.
    public let manifest: StackManifest

    public init(
        service: ServiceSpec,
        files: [GeneratedFile],
        secrets: [SecretResolution],
        manifest: StackManifest
    ) {
        self.service = service
        self.files = files
        self.secrets = secrets
        self.manifest = manifest
    }

    /// The keys a person still has to fill in before the service will boot.
    public var unresolved: [SecretResolution] {
        secrets.filter { $0.origin.needsValue }
    }
}

/// Authors a new service: its declaration, its image variable, its config, and its manifest entry.
///
/// Nothing here is dokku-specific. The declaration comes from a ``ServiceProvider``, so a new
/// backend is a new conformance rather than a change to this type.
public struct Scaffolder: Sendable {
    private let readFile: @Sendable (String) throws -> String
    private let writeFile: @Sendable (String, String) throws -> Void
    private let fileExists: @Sendable (String) -> Bool
    private let planner: SecretPlanner

    public init(
        planner: SecretPlanner = SecretPlanner(),
        readFile: @escaping @Sendable (String) throws -> String = {
            try String(contentsOfFile: $0, encoding: .utf8)
        },
        writeFile: @escaping @Sendable (String, String) throws -> Void = {
            try $1.write(toFile: $0, atomically: true, encoding: .utf8)
        },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.planner = planner
        self.readFile = readFile
        self.writeFile = writeFile
        self.fileExists = fileExists
    }

    /// Works out everything that would be written, without writing any of it.
    public func plan(
        service: ServiceSpec,
        into stackName: String,
        manifest: StackManifest,
        containerPort: Int = 8080,
        network: String? = nil,
        gated: Bool = false,
        siblings: [String: [String: String]] = [:],
        mintKeypair: Bool = false
    ) async throws -> ScaffoldResult {
        guard var stack = manifest.stack(named: stackName) else {
            throw ManifestError.invalidStackName(stackName)
        }
        guard stack.tofu != nil else {
            throw ScaffoldError.noTofuBinding(stack: stackName)
        }
        guard stack.service(named: service.name) == nil else {
            throw ScaffoldError.serviceExists(stack: stackName, service: service.name)
        }

        let provider = try Providers.provider(for: stack.backend)

        var resolved = service
        let request = ScaffoldRequest(
            stack: stack, service: service, containerPort: containerPort,
            network: network, gated: gated)
        resolved.imageVariable = provider.imageVariableName(for: request)

        let finalRequest = ScaffoldRequest(
            stack: stack, service: resolved, containerPort: containerPort,
            network: network, gated: gated)

        var files = try provider.declaration(for: finalRequest)
        if let variable = provider.imageVariable(for: finalRequest) {
            files.append(
                GeneratedFile(path: "variables.tf", contents: variable, role: .variableAppend))
        }

        let secrets = try await planner.resolve(
            for: resolved, in: stack, siblings: siblings, mintKeypair: mintKeypair)

        // A key with no value is left out rather than written as "". The dokku provider rejects
        // a zero-length config value outright — `string length must be at least 1` — so an empty
        // placeholder makes the stack fail to plan the moment it is created, which is the worst
        // possible time to discover it.
        var config: [String: String] = [:]
        for secret in secrets where !secret.value.isEmpty {
            config[secret.key] = secret.value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configJSON = String(decoding: try encoder.encode(config), as: UTF8.self)
        files.append(
            GeneratedFile(path: resolved.configFile, contents: configJSON + "\n", role: .config))

        stack.services.append(resolved)
        var updated = manifest
        for index in updated.stacks.indices where updated.stacks[index].name == stackName {
            updated.stacks[index] = stack
        }

        return ScaffoldResult(
            service: resolved, files: files, secrets: secrets, manifest: updated)
    }

    /// Writes what ``plan(service:into:manifest:containerPort:network:gated:siblings:mintKeypair:)``
    /// worked out.
    ///
    /// A whole file is never overwritten. Appends are appended. The tofu directory holds live
    /// declarations and real secrets, so clobbering one is the one mistake that cannot be undone
    /// from inside hatchery.
    @discardableResult
    public func write(_ result: ScaffoldResult, in stack: StackSpec) throws -> [String] {
        guard let binding = stack.tofu else {
            throw ScaffoldError.noTofuBinding(stack: stack.name)
        }
        let directory = Paths.expanded(binding.directory)

        // Every destination is checked before anything is written, so a collision cannot leave
        // half a service on disk.
        for file in result.files where file.role != .variableAppend {
            let path = Paths.join(directory, file.path)
            if fileExists(path) {
                throw ScaffoldError.fileExists(path)
            }
        }

        var written: [String] = []
        for file in result.files {
            let path = Paths.join(directory, file.path)
            switch file.role {
            case .variableAppend:
                let existing = (try? readFile(path)) ?? ""
                try writeFile(path, existing + file.contents + "\n")
            case .declaration, .config:
                try writeFile(path, file.contents)
            }
            written.append(path)
        }
        return written
    }
}

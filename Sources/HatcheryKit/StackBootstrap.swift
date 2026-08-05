import Foundation

public enum BootstrapError: Error, CustomStringConvertible, Equatable {
    case stackExists(String)
    case directoryNotEmpty(String)
    case initFailed(String)
    case unsupportedBackend(Backend)
    case missingSettings(backend: Backend, keys: [String])

    public var description: String {
        switch self {
        case .stackExists(let name):
            return "a stack named '\(name)' is already declared"
        case .directoryNotEmpty(let path):
            return "\(path) already holds a tofu configuration; hatchery will not write over it"
        case .initFailed(let message):
            return "tofu init failed: \(message)"
        case .missingSettings(let backend, let keys):
            return """
                \(backend.rawValue) needs \(keys.joined(separator: ", ")); \
                pass --set <key>=<value>, or run `hatchery setup --backend \(backend.rawValue)`
                """
        case .unsupportedBackend(let backend):
            return "hatchery cannot bootstrap a \(backend.rawValue) stack yet"
        }
    }
}

/// What creating a stack produced.
public struct BootstrapResult: Sendable, Equatable {
    public let stack: StackSpec
    public let files: [GeneratedFile]
    public let manifest: StackManifest
    /// Where the manifest should be written.
    public let manifestPath: String
    /// What `tofu init` said, once it has run.
    public let initOutput: String?

    public init(
        stack: StackSpec,
        files: [GeneratedFile],
        manifest: StackManifest,
        manifestPath: String,
        initOutput: String? = nil
    ) {
        self.stack = stack
        self.files = files
        self.manifest = manifest
        self.manifestPath = manifestPath
        self.initOutput = initOutput
    }
}

/// Creates a stack where there was nothing: the tofu configuration, the manifest, and `tofu init`.
///
/// This is the step that was missing. `service new` could add to a configuration that already
/// existed, but the lab's own configuration was written by hand, so there was no path from an
/// empty directory to a running service without writing HCL yourself.
public struct StackBootstrapper: Sendable {
    private let execute: CommandExecutor
    private let writeFile: @Sendable (String, String) throws -> Void
    private let fileExists: @Sendable (String) -> Bool
    private let createDirectory: @Sendable (String) throws -> Void
    /// Named for what it is, because `plan` already has an `environment` meaning prod/dev.
    private let processEnvironment: [String: String]

    public init(
        execute: @escaping CommandExecutor = ShellRunner.liveExecutor,
        writeFile: @escaping @Sendable (String, String) throws -> Void = {
            try $1.write(toFile: $0, atomically: true, encoding: .utf8)
        },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        createDirectory: @escaping @Sendable (String) throws -> Void = {
            try FileManager.default.createDirectory(
                atPath: $0, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.execute = execute
        self.writeFile = writeFile
        self.fileExists = fileExists
        self.createDirectory = createDirectory
        self.processEnvironment = environment
    }

    static func initCommand() -> [String] {
        ["tofu", "init", "-input=false", "-no-color"]
    }

    /// The manifest belongs beside the config files it names, because `configFile` resolves
    /// against the stack's own directory.
    public static func manifestPath(inTofuDirectory directory: String) -> String {
        Paths.join(Paths.expanded(directory), ManifestLocator.defaultName)
    }

    public func plan(
        name: String,
        backend: Backend,
        host: String,
        tofuDir: String,
        environment: Environment? = nil,
        settings: [String: String] = [:],
        into existing: StackManifest? = nil,
        manifestPath: String? = nil
    ) throws -> BootstrapResult {
        let provider = Providers.support(for: backend)
        guard provider.authorable else {
            throw BootstrapError.unsupportedBackend(backend)
        }
        guard StackName.isValid(name) else {
            throw ManifestError.invalidStackName(name)
        }
        var manifest = existing ?? StackManifest()
        guard manifest.stack(named: name) == nil else {
            throw BootstrapError.stackExists(name)
        }

        let directory = Paths.expanded(tofuDir)
        // A configuration already there is never written over. Getting this wrong means
        // clobbering the declaration of something already running.
        for existingFile in ["versions.tf", "providers.tf"] where fileExists(Paths.join(directory, existingFile)) {
            throw BootstrapError.directoryNotEmpty(directory)
        }

        // The backend supplies its own starting configuration; this type only decides where
        // it goes and refuses to write over anything already there.
        // Missing settings are refused here rather than surfacing as a provider error later.
        var values = settings
        if !host.isEmpty { values["host"] = host }
        let missing = provider.missingSettings(values, environment: processEnvironment)
        guard missing.isEmpty else {
            throw BootstrapError.missingSettings(
                backend: backend, keys: missing.map(\.key).sorted())
        }
        let files = provider.bootstrapFiles(settings: values)

        let stack = StackSpec(
            name: name,
            backend: backend,
            environment: environment,
            host: host,
            tofu: TofuBinding(directory: tofuDir),
            // Only the declared, non-secret values: a token never reaches the manifest.
            settings: provider.settings.storable(values),
            services: [])
        manifest.stacks.append(stack)

        return BootstrapResult(
            stack: stack,
            files: files,
            manifest: manifest,
            manifestPath: manifestPath ?? Self.manifestPath(inTofuDirectory: tofuDir))
    }

    /// Writes the configuration and runs `tofu init` so the directory is ready to plan.
    public func create(_ result: BootstrapResult) async throws -> BootstrapResult {
        guard let binding = result.stack.tofu else {
            throw BootstrapError.unsupportedBackend(result.stack.backend)
        }
        let directory = Paths.expanded(binding.directory)
        try createDirectory(directory)

        for file in result.files {
            try writeFile(Paths.join(directory, file.path), file.contents)
        }

        let output = try await execute(Self.initCommand(), directory)
        guard output.status == 0 else {
            throw BootstrapError.initFailed(output.combined)
        }

        return BootstrapResult(
            stack: result.stack, files: result.files, manifest: result.manifest,
            manifestPath: result.manifestPath, initOutput: output.combined)
    }

}

import Foundation

public struct CommandFailure: Error, CustomStringConvertible, Equatable {
    public let command: String
    public let status: Int32
    public let message: String

    public init(command: String, status: Int32, message: String) {
        self.command = command
        self.status = status
        self.message = message
    }

    public var description: String {
        message.isEmpty ? "\(command) failed (\(status))" : "\(command) failed (\(status)): \(message)"
    }
}

public enum LiveConfigError: Error, CustomStringConvertible, Equatable {
    case noHost(stack: String)
    case unsupportedBackend(Backend)
    case malformedConfig(service: String)

    public var description: String {
        switch self {
        case .noHost(let stack):
            return "stack '\(stack)' targets dokku but declares no host, so there is nothing to read from"
        case .unsupportedBackend(let backend):
            return "reading live config from \(backend.rawValue) is not implemented yet"
        case .malformedConfig(let service):
            return "the config '\(service)' returned is not a flat map of strings"
        }
    }
}

/// Runs one command and returns its standard output.
public typealias CommandRunner = @Sendable ([String]) async throws -> Data

/// Everything one command produced, including a nonzero status.
///
/// ``CommandRunner`` throws on a nonzero exit, which is right for a command whose only
/// interesting outcome is its output. `tofu plan -detailed-exitcode` is not that command:
/// it exits 2 to say *there are changes*, which is the answer rather than a failure.
public struct CommandOutput: Sendable, Equatable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String, standardError: String = "") {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// Whatever the command said, preferring stdout and falling back to stderr.
    public var combined: String {
        let out = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return err }
        if err.isEmpty { return out }
        return out + "\n" + err
    }
}

/// Runs one command in a directory and reports how it exited.
public typealias CommandExecutor = @Sendable (
    _ argv: [String],
    _ workingDirectory: String?
) async throws -> CommandOutput

public enum ShellRunner {
    public static let live: CommandRunner = { argv in
        let result = try await liveExecutor(argv, nil)
        guard result.status == 0 else {
            throw CommandFailure(
                command: argv.first ?? "command",
                status: result.status,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return Data(result.standardOutput.utf8)
    }

    public static let liveExecutor: CommandExecutor = { argv, workingDirectory in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: Paths.expanded(workingDirectory))
        }

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        // Both pipes are drained before the wait. A process that fills a pipe buffer blocks
        // until someone reads it, and waiting first would deadlock on a long plan.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandOutput(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}

public enum Paths {
    /// Expands a leading `~`, which a manifest is likely to carry because a person wrote it.
    public static func expanded(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSString(string: path).expandingTildeInPath
    }

    public static func join(_ directory: String, _ file: String) -> String {
        guard !directory.isEmpty else { return file }
        return directory.hasSuffix("/") ? directory + file : directory + "/" + file
    }
}

/// Reads the configuration a service is actually running with.
///
/// The declared file and the running app drift apart, because `dokku config:set` merges rather
/// than replaces: a key set by hand never reaches the file, and nothing reports the difference.
/// Checking the file alone therefore answers a question nobody asked.
public struct LiveConfigReader: Sendable {
    private let run: CommandRunner

    public init(run: @escaping CommandRunner = ShellRunner.live) {
        self.run = run
    }

    public func config(for service: ServiceSpec, in stack: StackSpec) async throws -> [String: String] {
        switch stack.backend {
        case .dokku:
            guard let host = stack.host, !host.isEmpty else {
                throw LiveConfigError.noHost(stack: stack.name)
            }
            let data = try await run(Self.dokkuCommand(host: host, app: service.name))
            guard let config = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw LiveConfigError.malformedConfig(service: service.name)
            }
            return config

        case .cloudRun:
            // `gcloud run services describe` returns the environment, but anything sourced from
            // Secret Manager is a reference rather than a value, same as App Runner.
            throw LiveConfigError.unsupportedBackend(.cloudRun)

        case .aws:
            // `aws apprunner describe-service` returns the plain environment, but anything
            // pulled from Secrets Manager comes back as a reference rather than a value. Half a
            // config would make `config audit` report drift that is not there.
            throw LiveConfigError.unsupportedBackend(.aws)

        case .appPlatform:
            // Authoring one works — `digitalocean_app` takes an image, an environment, a port
            // and a health check. Reading one back does not: `doctl apps spec get` returns the
            // whole spec, and the env block carries
            // `EV[...]` ciphertext for every key typed SECRET. Reading it needs a decision
            // about what a value we cannot see means, so it is deliberately not guessed here.
            throw LiveConfigError.unsupportedBackend(.appPlatform)
        }
    }

    static func dokkuCommand(host: String, app: String) -> [String] {
        ["ssh", "-o", "BatchMode=yes", host, "config:export", "--format", "json", app]
    }
}

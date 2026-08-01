import Foundation

public struct CommandFailure: Error, CustomStringConvertible, Equatable {
    public let command: String
    public let status: Int32
    public let message: String

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

public enum ShellRunner {
    public static let live: CommandRunner = { argv in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        // Both pipes are drained before the wait. A process that fills a pipe buffer blocks
        // until someone reads it, and waiting first would deadlock on a large config.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CommandFailure(
                command: argv.first ?? "command",
                status: process.terminationStatus,
                message: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return outputData
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

        case .appPlatform:
            // `doctl apps spec get` returns the whole spec, and the env block carries
            // `EV[...]` ciphertext for every key typed SECRET. Reading it needs a decision
            // about what a value we cannot see means, so it is deliberately not guessed here.
            throw LiveConfigError.unsupportedBackend(.appPlatform)
        }
    }

    static func dokkuCommand(host: String, app: String) -> [String] {
        ["ssh", "-o", "BatchMode=yes", host, "config:export", "--format", "json", app]
    }
}

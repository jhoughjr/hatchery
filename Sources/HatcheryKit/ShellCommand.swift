import Foundation

/// One command and the bytes it reads on its standard input.
///
/// A secret goes in `standardInput` and never in `argv`, because `ps` on either machine shows every argument to every account.
/// Its description prints the arguments and only the size of the input, so a log line or an error that names the command names no value.
public struct ShellCommand: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var argv: [String]
    public var standardInput: Data?

    public var description: String {
        let line = self.argv.joined(separator: " ")
        guard let input = self.standardInput else { return line }
        return line + " < (\(input.count) bytes on standard input)"
    }

    public var debugDescription: String { self.description }

    /// The mirror a `dump` or a test failure prints, which keeps the input out of it the same way.
    public var customMirror: Mirror {
        Mirror(self, children: ["argv": self.argv, "standardInput": self.standardInput.map { "\($0.count) bytes" } ?? "none"])
    }

    public init(_ argv: [String], standardInput: Data? = nil) {
        self.argv = argv
        self.standardInput = standardInput
    }
}

/// Runs one command with its input and returns its standard output.
public typealias ShellCommandRunner = @Sendable (ShellCommand) async throws -> Data

// MARK: - The live runner

extension ShellRunner {
    /// Runs a command, writes its input to the command's standard input, and closes it so the command reads an end.
    /// A command with no input inherits this process's standard input, the same as ``ShellRunner/live``.
    public static let withInput: ShellCommandRunner = { command in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command.argv

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = command.standardInput.map { _ in Pipe() }
        if let input { process.standardInput = input }

        // A command that exits before it reads its input closes the pipe.
        // The write then fails with an error in place of a signal that ends hatchery.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        // The input is written whole before the output is read.
        // A value is a few hundred bytes, far under the 16 KiB a pipe holds, so the write never waits on a reader.
        if let input, let bytes = command.standardInput {
            try? input.fileHandleForWriting.write(contentsOf: bytes)
            try? input.fileHandleForWriting.close()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CommandFailure(
                command: command.argv.first ?? "command",
                status: process.terminationStatus,
                message: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outputData
    }
}

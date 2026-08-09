import Foundation

/// Runs one command and hands back its output line by line, as it is produced.
///
/// `ShellRunner` collects everything and answers once, which is right for commands whose
/// output is an answer. `tofu apply` is not that command: it narrates for minutes, and a
/// person watching a dashboard needs the narration while it happens, not afterwards.
public enum LineStream {
    public typealias Runner = @Sendable (
        _ argv: [String], _ directory: String?, _ onLine: @escaping @Sendable (String) -> Void
    ) async -> Int32

    public static let live: Runner = { argv, directory, onLine in
        await run(argv, in: directory, onLine: onLine)
    }

    /// Runs the command, calling `onLine` for every completed line of combined output, and
    /// returns the exit status. A command that cannot start reports the reason as a line and
    /// returns -1 rather than throwing — the caller is a job, and a job's failures belong in
    /// its own transcript.
    public static func run(
        _ argv: [String], in directory: String?,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            if let directory {
                process.currentDirectoryURL = URL(fileURLWithPath: Paths.expanded(directory))
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let buffer = LineBuffer(onLine)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.feed(data)
            }

            process.terminationHandler = { finished in
                // The handler races the last reads: detach it, drain what remains, flush the
                // partial line, and only then answer.
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    buffer.feed(rest)
                }
                buffer.flush()
                continuation.resume(returning: finished.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                onLine("could not start \(argv.first ?? "the command"): \(error)")
                continuation.resume(returning: -1)
            }
        }
    }

    /// Accumulates chunks and emits whole lines, in arrival order.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = Data()
        private let onLine: @Sendable (String) -> Void

        init(_ onLine: @escaping @Sendable (String) -> Void) {
            self.onLine = onLine
        }

        func feed(_ data: Data) {
            lock.lock()
            partial.append(data)
            var lines: [String] = []
            while let newline = partial.firstIndex(of: 0x0A) {
                let line = partial[partial.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self))
                partial = Data(partial[partial.index(after: newline)...])
            }
            lock.unlock()
            for line in lines { onLine(line) }
        }

        func flush() {
            lock.lock()
            let rest = partial
            partial = Data()
            lock.unlock()
            if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
        }
    }
}

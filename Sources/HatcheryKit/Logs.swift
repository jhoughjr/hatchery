import Foundation

public enum LogError: Error, CustomStringConvertible, Equatable {
    case noHost(stack: String)
    case unsupportedBackend(Backend)

    public var description: String {
        switch self {
        case .noHost(let stack):
            return "stack '\(stack)' targets dokku but declares no host, so there is nothing to read from"
        case .unsupportedBackend(let backend):
            return "reading logs from \(backend.rawValue) is not implemented yet"
        }
    }
}

/// One line of a service's output, with the severity it announced.
public struct LogLine: Sendable, Equatable, Codable {
    public enum Level: String, Sendable, Codable {
        case error, warning, info, unknown
    }

    public let text: String
    public let level: Level

    public init(text: String, level: Level) {
        self.text = text
        self.level = level
    }

    /// Classified by what the line says about itself.
    ///
    /// This reads the line rather than parsing it into fields, because every service in the
    /// estate formats differently — Vapor's bracketed levels, the gateways' plain prefixes —
    /// and a parser that assumed one shape would silently mislabel the others.
    public static func classify(_ raw: String) -> LogLine {
        let text = stripANSI(raw)
        let upper = text.uppercased()
        let level: Level
        if upper.contains("ERROR") || upper.contains("FATAL") || upper.contains("CRITICAL") {
            level = .error
        } else if upper.contains("WARNING") || upper.contains("WARN") {
            level = .warning
        } else if upper.contains("INFO") || upper.contains("NOTICE") || upper.contains("DEBUG") {
            level = .info
        } else {
            level = .unknown
        }
        return LogLine(text: text, level: level)
    }

    /// Removes the colour codes dokku wraps each line's prefix in.
    ///
    /// They are invisible in a terminal and literal noise anywhere else — a browser renders
    /// `ESC[36m` as text, so every line would start with garbage.
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var out = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{1B}" else {
                out.append(character)
                continue
            }
            // CSI sequences run until a letter in @-~; anything else we drop the escape alone.
            guard let next = iterator.next() else { break }
            guard next == "[" else { continue }
            while let terminator = iterator.next() {
                if terminator.isLetter || terminator == "@" || terminator == "~" { break }
            }
        }
        return out
    }
}

/// Reads what a service has been saying.
public struct LogReader: Sendable {
    private let run: CommandRunner

    public init(run: @escaping CommandRunner = ShellRunner.live) {
        self.run = run
    }

    /// Capped rather than unbounded. `dokku logs` with no limit can return a very large
    /// buffer, and a browser that has to render all of it stops being a dashboard.
    public static let maximumLines = 1000

    static func command(host: String, app: String, lines: Int) -> [String] {
        ["ssh", "-o", "BatchMode=yes", host, "logs", app, "--num", String(lines)]
    }

    public func logs(
        for service: ServiceSpec,
        in stack: StackSpec,
        lines: Int = 200
    ) async throws -> [LogLine] {
        guard stack.backend == .dokku else {
            throw LogError.unsupportedBackend(stack.backend)
        }
        guard let host = stack.host, !host.isEmpty else {
            throw LogError.noHost(stack: stack.name)
        }

        let capped = max(1, min(lines, Self.maximumLines))
        let data = try await run(
            Self.command(
                host: DokkuProvider.sshTarget(host), app: service.name, lines: capped))
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { LogLine.classify(String($0)) }
            .drop { $0.text.isEmpty }
            .reversed()
            .drop { $0.text.isEmpty }
            .reversed()
    }
}

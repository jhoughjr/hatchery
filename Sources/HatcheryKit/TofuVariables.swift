import Foundation

public enum TofuVariableError: Error, CustomStringConvertible, Equatable {
    case variableNotFound(String, file: String)
    case noDefault(variable: String, file: String)

    public var description: String {
        switch self {
        case .variableNotFound(let name, let file):
            return "no variable '\(name)' is declared in \(file)"
        case .noDefault(let name, let file):
            return """
                variable '\(name)' in \(file) declares no default, so hatchery cannot tell what \
                it currently resolves to; give it a default or pass the image with -var
                """
        }
    }
}

/// A `variables.tf` file, edited one default at a time.
///
/// The edit is deliberately textual rather than a parse-and-reprint. The file carries comments
/// that explain how each image was built and where it came from, and those comments are the
/// most useful thing in it. Rewriting the file from a syntax tree would drop them, so this
/// replaces exactly the quoted value on the `default` line and returns every other byte unchanged.
public struct TofuVariableFile: Sendable, Equatable {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }

    /// The value on a variable's `default` line, or `nil` when the variable or default is absent.
    public func defaultValue(of variable: String) -> String? {
        guard let location = try? locateDefault(of: variable) else { return nil }
        return location.value
    }

    /// The same file with one variable's default replaced.
    public func settingDefault(of variable: String, to value: String) throws -> TofuVariableFile {
        let location = try locateDefault(of: variable)
        var lines = contents.components(separatedBy: "\n")
        let line = lines[location.line]

        let head = line.index(line.startIndex, offsetBy: location.valueStart)
        let tail = line.index(line.startIndex, offsetBy: location.valueEnd)
        lines[location.line] = line.replacingCharacters(in: head..<tail, with: value)

        return TofuVariableFile(path: path, contents: lines.joined(separator: "\n"))
    }

    /// Where one variable's default value sits, as offsets into a single line.
    struct DefaultLocation {
        let line: Int
        let valueStart: Int
        let valueEnd: Int
        let value: String
    }

    func locateDefault(of variable: String) throws -> DefaultLocation {
        let lines = contents.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { Self.opensBlock(for: variable, $0) }) else {
            throw TofuVariableError.variableNotFound(variable, file: path)
        }

        // Brace depth bounds the search to this block, so a `default` belonging to the next
        // variable is never mistaken for this one's.
        var depth = 0
        for index in start..<lines.count {
            let line = lines[index]
            depth += line.filter { $0 == "{" }.count
            depth -= line.filter { $0 == "}" }.count

            if index > start, let location = Self.defaultValue(in: line, at: index) {
                return location
            }
            if depth <= 0, index > start { break }
        }
        throw TofuVariableError.noDefault(variable: variable, file: path)
    }

    /// `variable "name" {` in any spacing a person is likely to have typed.
    static func opensBlock(for variable: String, _ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("variable") else { return false }
        return trimmed.contains("\"\(variable)\"") && trimmed.contains("{")
    }

    /// The quoted value on a `default = "..."` line.
    ///
    /// Only a quoted scalar is recognised. A default that is a list, a map, or an expression
    /// has no single value to swap, and guessing at one would corrupt the file.
    static func defaultValue(in line: String, at index: Int) -> DefaultLocation? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("default"), trimmed.dropFirst("default".count).trimmingCharacters(in: .whitespaces).hasPrefix("=") else {
            return nil
        }
        let characters = Array(line)
        guard let equals = characters.firstIndex(of: "=") else { return nil }
        // The quote has to be the first thing after the `=`. Scanning ahead for one instead
        // would find the first element of a list default and rewrite that.
        guard let open = characters[characters.index(after: equals)...]
            .firstIndex(where: { !$0.isWhitespace }), characters[open] == "\"" else { return nil }
        guard let close = characters[characters.index(after: open)...].firstIndex(of: "\"") else { return nil }

        return DefaultLocation(
            line: index,
            valueStart: characters.index(after: open),
            valueEnd: close,
            value: String(characters[characters.index(after: open)..<close])
        )
    }
}

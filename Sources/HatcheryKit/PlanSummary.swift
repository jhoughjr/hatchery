import Foundation

/// What a `tofu plan` said, reduced to the parts worth reading before applying.
///
/// This reads the human output rather than `-json`, because the JSON form needs a plan file
/// written to disk and a second `tofu show` pass. The shape read here is narrow on purpose:
/// the summary line and the per-line change markers, both of which tofu has emitted unchanged
/// for years. Anything it does not recognise is still shown verbatim, so a format change
/// degrades to the flat text it used to be rather than to a blank panel.
public struct PlanSummary: Sendable, Equatable, Codable {
    public struct Line: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable {
            /// `+ ` — a resource or attribute being created.
            case add
            /// `- ` — being destroyed.
            case remove
            /// `~ ` — being changed in place.
            case change
            /// A resource header, e.g. `# dokku_app.mwlab will be updated in-place`.
            case header
            case plain
        }

        public let text: String
        public let kind: Kind

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    public let add: Int
    public let change: Int
    public let destroy: Int
    public let lines: [Line]
    /// True when the summary line was found. When false the counts are zero and the caller
    /// should treat the lines as the whole story.
    public let parsed: Bool

    public init(add: Int, change: Int, destroy: Int, lines: [Line], parsed: Bool) {
        self.add = add
        self.change = change
        self.destroy = destroy
        self.lines = lines
        self.parsed = parsed
    }

    public var isEmpty: Bool {
        add == 0 && change == 0 && destroy == 0
    }

    /// A one-line description in the words tofu itself uses.
    /// tofu understood the plan and it would do nothing.
    ///
    /// Distinct from `!parsed`, which means the output was not understood at all. Reading one as
    /// the other is how a destroy that would remove nothing came to be announced as though it
    /// would remove something.
    public var isNoop: Bool {
        parsed && add == 0 && change == 0 && destroy == 0
    }

    public var headline: String {
        guard parsed else { return "plan output" }
        if isNoop { return "nothing to change" }
        return "\(add) to add, \(change) to change, \(destroy) to destroy"
    }

    public static func parse(_ output: String) -> PlanSummary {
        var add = 0
        var change = 0
        var destroy = 0
        var parsed = false
        var lines: [Line] = []

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Plan:"), let counts = Self.counts(in: trimmed) {
                add = counts.add
                change = counts.change
                destroy = counts.destroy
                parsed = true
            }

            // tofu prints a `Plan:` line only when something would change. With nothing to do it
            // says "No changes." instead, which left the summary unparsed and reported as though
            // it were unreadable output rather than an empty plan.
            if trimmed.hasPrefix("No changes.") {
                parsed = true
            }

            lines.append(Line(text: text, kind: Self.kind(of: trimmed)))
        }

        // Trailing blank lines are noise in a panel that is already scrolling.
        while let last = lines.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return PlanSummary(add: add, change: change, destroy: destroy, lines: lines, parsed: parsed)
    }

    static func kind(of trimmed: String) -> Line.Kind {
        if trimmed.hasPrefix("#") { return .header }
        guard let first = trimmed.first else { return .plain }
        // A marker only counts when something follows it, so a bare `-` in prose or an `---`
        // rule is not mistaken for a destroy.
        let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, rest.first != first else { return .plain }
        switch first {
        case "+": return .add
        case "-": return .remove
        case "~": return .change
        default: return .plain
        }
    }

    /// `Plan: 1 to add, 0 to change, 0 to destroy.`
    static func counts(in line: String) -> (add: Int, change: Int, destroy: Int)? {
        func number(before phrase: String) -> Int? {
            guard let range = line.range(of: phrase) else { return nil }
            let digits = line[..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ").last
            return digits.flatMap { Int($0) }
        }
        guard let add = number(before: "to add"),
            let change = number(before: "to change"),
            let destroy = number(before: "to destroy")
        else { return nil }
        return (add, change, destroy)
    }
}

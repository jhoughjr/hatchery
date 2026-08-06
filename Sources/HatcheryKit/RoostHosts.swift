import Foundation

/// SSH targets that roost already knows about.
///
/// roost configures boxes; hatchery configures the stacks on them. So roost is the one that
/// knows a machine exists, and hatchery should ask rather than make you type an address it
/// already has. `~/.roostrc` declares `ROOST_DOKKU_HOST` today, which is enough to start —
/// nothing has to change on roost's side for this to work.
///
/// This reads rather than executes: sourcing someone's rc file to learn one variable would run
/// whatever else is in it.
public enum RoostHosts {
    public static let defaultPath = "~/.roostrc"

    /// Variables whose value is an SSH target.
    static let hostKeys = ["ROOST_DOKKU_HOST", "ROOST_STATUS_RUNNER", "ROOST_NODE_HOST"]

    public static func hosts(
        at path: String = defaultPath,
        read: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) }
    ) -> [(name: String, target: String)] {
        guard let contents = try? read(Paths.expanded(path)) else { return [] }

        var found: [(name: String, target: String)] = []
        var seen = Set<String>()
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard hostKeys.contains(key) else { continue }

            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            // A placeholder from the example file is not a host.
            guard !value.isEmpty, !value.contains("YOUR_"), !value.contains("$") else { continue }
            guard seen.insert(value).inserted else { continue }

            found.append((name: Self.label(for: key), target: value))
        }
        return found
    }

    /// A short name for the variable, so the list reads as places rather than as settings.
    static func label(for key: String) -> String {
        switch key {
        case "ROOST_DOKKU_HOST": return "roost dokku host"
        case "ROOST_STATUS_RUNNER": return "roost status runner"
        default: return key.replacingOccurrences(of: "ROOST_", with: "roost ").lowercased()
        }
    }
}

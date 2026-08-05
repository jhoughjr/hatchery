import Foundation

/// What changed between the config a service runs with and the file that declares it.
///
/// Only key names appear here. The values are the whole reason the declared file is gitignored,
/// and a summary that prints them defeats that.
public struct ConfigDiff: Sendable, Equatable {
    /// Live on the service, absent from the file. A key set by hand lands here.
    public let added: [String]
    /// Declared in the file, absent from the service.
    public let removed: [String]
    /// Present in both, with different values.
    public let changed: [String]

    public init(added: [String] = [], removed: [String] = [], changed: [String] = []) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }

    /// A one-line summary, safe to paste anywhere.
    public var summary: String {
        isEmpty
            ? "in sync"
            : "\(added.count) added, \(changed.count) changed, \(removed.count) removed"
    }
}

public enum ConfigSync {
    /// Keys the platform writes for itself.
    ///
    /// `GIT_REV` moves on every deploy, so reporting it as a difference would make every sync
    /// look like a change and train a reader to skim. It is filtered out of the *report* only.
    ///
    /// It is deliberately still written to the file. The declaration has to match what tofu
    /// already tracks in state, and a key that disappears from the declaration reads as a
    /// removal that an apply would carry out against the running app.
    public static let platformInjected: Set<String> = [
        "GIT_REV", "DOKKU_APP_TYPE", "DOKKU_PROXY_PORT_MAP",
    ]

    static func reportable(_ config: [String: String]) -> [String: String] {
        config.filter { !platformInjected.contains($0.key) }
    }

    /// Compare a live config against a declared one, ignoring the platform's own keys.
    ///
    /// The lists are sorted so a summary is stable between runs and diffable.
    public static func diff(live: [String: String], declared: [String: String]) -> ConfigDiff {
        let live = reportable(live)
        let declared = reportable(declared)
        return ConfigDiff(
            added: Set(live.keys).subtracting(declared.keys).sorted(),
            removed: Set(declared.keys).subtracting(live.keys).sorted(),
            changed: Set(live.keys).intersection(declared.keys)
                .filter { live[$0] != declared[$0] }
                .sorted()
        )
    }

    /// The bytes to write, carrying everything the service runs with.
    ///
    /// Keys are sorted and the output is pretty printed, so a rewrite produces a small diff
    /// rather than a reordered file.
    public static func encode(_ config: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }

    /// Read a declared config, treating a missing file as an empty one.
    ///
    /// A service that has never been synced has no file, and that is a first sync rather than
    /// an error.
    public static func readDeclared(at url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    /// The config to write for a service.
    ///
    /// A platform key is carried only when the declaration already claimed it. The lab taught
    /// this rule twice in one sitting: adding `GIT_REV` to a declaration that never had it made
    /// a plan want to set it on the app, and dropping it from one that did have it made a plan
    /// want to unset it. Matching whatever the declaration already decided leaves a plan clean
    /// in both cases.
    public static func merged(live: [String: String], declared: [String: String]) -> [String: String] {
        var result = reportable(live)
        for key in platformInjected where declared[key] != nil {
            result[key] = live[key]
        }
        return result
    }

    /// Whether the file on disk already says what this service should declare.
    ///
    /// This compares values rather than bytes, so a hand-formatted file that already agrees is
    /// left alone.
    public static func needsWrite(live: [String: String], declared: [String: String]) -> Bool {
        merged(live: live, declared: declared) != declared
    }

    /// Where a service's declared config lives.
    ///
    /// Resolved against the stack's own tofu directory when it has one, because that is where
    /// the declaration reading the file lives: `jsondecode(file("${path.module}/x.config.json"))`
    /// is relative to the module, not to wherever the manifest happens to sit. Falling back to
    /// the manifest's directory keeps a single-stack layout — where the two are the same place —
    /// working exactly as before.
    public static func configURL(
        for service: ServiceSpec,
        in stack: StackSpec? = nil,
        manifestPath: String
    ) -> URL {
        if let directory = stack?.tofu?.directory {
            return URL(
                fileURLWithPath: service.configFile,
                relativeTo: URL(fileURLWithPath: Paths.expanded(directory), isDirectory: true)
            ).standardizedFileURL
        }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let directory = manifestURL.deletingLastPathComponent()
        return URL(fileURLWithPath: service.configFile, relativeTo: directory).standardizedFileURL
    }

    /// Merges values into a service's declared config, leaving every other key alone.
    ///
    /// This is how a key reported as needing a value gets one. It is a merge rather than a
    /// replace because the file already holds everything hatchery minted, and rewriting it
    /// wholesale from a form would drop whatever the form did not know about.
    public static func applying(_ values: [String: String], to declared: [String: String]) -> [String: String] {
        var result = declared
        for (key, value) in values {
            // An empty value clears the key rather than writing "", so a mistake can be undone
            // and a key never sits there looking answered when it is not.
            if value.isEmpty {
                result.removeValue(forKey: key)
            } else {
                result[key] = value
            }
        }
        return result
    }

    public static func encoded(_ config: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }
}

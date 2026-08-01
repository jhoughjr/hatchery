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

    /// Where a service's declared config lives, resolved against the manifest's own directory.
    ///
    /// The manifest names the sidecar by a relative path, so the pair travels together.
    public static func configURL(for service: ServiceSpec, manifestPath: String) -> URL {
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let directory = manifestURL.deletingLastPathComponent()
        return URL(fileURLWithPath: service.configFile, relativeTo: directory).standardizedFileURL
    }
}

import Foundation

public enum ManifestLocatorError: Error, CustomStringConvertible, Equatable {
    case notFound(searched: [String])

    public var description: String {
        """
        no manifest found. Looked in:
        \(searched.map { "  \($0)" }.joined(separator: "\n"))

        Pass --manifest, set HATCHERY_MANIFEST, or put one at ~/.config/hatchery/hatchery.json.
        """
    }

    var searched: [String] {
        if case .notFound(let searched) = self { return searched }
        return []
    }
}

/// Finds the manifest when the command line does not say where it is.
///
/// A stack manifest lives next to the config files it names, because `configFile` resolves
/// relative to the manifest's own directory. That is rarely the directory you happen to be
/// standing in, so a bare `hatchery status` would otherwise only work from one place.
public enum ManifestLocator {
    public static let defaultName = "hatchery.json"

    /// Where a manifest is looked for, in order, when none was named.
    public static func searchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        home: String = NSHomeDirectory()
    ) -> [String] {
        var paths = [Paths.join(currentDirectory, defaultName)]
        if let named = environment["HATCHERY_MANIFEST"], !named.isEmpty {
            paths.append(expand(named, home: home))
        }
        paths.append(Paths.join(home, ".config/hatchery/\(defaultName)"))
        return paths
    }

    /// Expands `~` against the home directory passed in rather than the process's own.
    ///
    /// `Paths.expanded` asks Foundation, which always answers with the real home. That is right
    /// everywhere else and wrong here, because it makes the `home` parameter a lie.
    static func expand(_ path: String, home: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return Paths.join(home, String(path.dropFirst(2)))
    }

    /// Resolves the path to read.
    ///
    /// An explicitly named path is used as given, and its absence is reported by whoever opens
    /// it — second-guessing an explicit `--manifest` would hide a typo. Only the default falls
    /// back, and only to somewhere that exists.
    public static func resolve(
        _ requested: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        home: String = NSHomeDirectory()
    ) throws -> String {
        guard requested == defaultName else { return expand(requested, home: home) }

        let candidates = searchPaths(
            environment: environment, currentDirectory: currentDirectory, home: home)
        for candidate in candidates where exists(candidate) {
            return candidate
        }
        throw ManifestLocatorError.notFound(searched: candidates)
    }

    /// Reads and validates whatever ``resolve(_:exists:environment:currentDirectory:home:)`` found.
    public static func load(_ requested: String) throws -> (manifest: StackManifest, path: String) {
        let path = try resolve(requested)
        let manifest = try StackManifest.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
        return (manifest, path)
    }
}

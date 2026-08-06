import Foundation

/// A directory that keeps its secrets encrypted at rest.
///
/// Recognised by `.age-recipient`, the file naming the key the bundle encrypts to. Its presence
/// is the whole opt-in: a state directory without it is sealed by nothing and reports nothing.
public enum SealedState {
    /// Names `seal.sh` also relies on. Changing one here means changing it there.
    public static let marker = ".age-recipient"
    public static let manifestName = "secrets.manifest"
    public static let archiveName = "secrets.tar.age"
    public static let scriptName = "seal.sh"

    /// Walks up from `path` looking for the marker, so a stack nested a level down
    /// (`infra-state/mwserver-tf`) still finds the root that seals it.
    public static func root(
        containing path: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        var directory = URL(fileURLWithPath: Paths.expanded(path)).standardizedFileURL
        while !directory.path.isEmpty && directory.path != "/" {
            if exists(directory.appendingPathComponent(marker).path) { return directory.path }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// The files that carry secret values, by the same rule `seal.sh` uses: config maps hold
    /// credentials, and tfstate holds every value the provider has ever seen, in cleartext.
    ///
    /// Kept deliberately identical to the `find` in that script. If the two disagree, a file is
    /// either sealed but unreported or reported but unsealed — and both of those read as safe.
    public static func isSecret(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        if parts.contains(".terraform") || parts.contains(".git") { return false }
        guard let name = parts.last else { return false }
        return name.hasSuffix(".config.json")
            || name == "terraform.tfstate"
            || name == "terraform.tfstate.backup"
    }
}

/// How the archive compares to the secrets actually on disk.
public struct SealStatus: Sendable, Equatable, Codable {
    public let root: String
    /// Holding secrets on disk, but absent from the archive or changed since it was written.
    /// These exist in exactly one place, and it is this machine.
    public let unsealed: [String]
    /// In the archive but gone from disk — a torn-down stack. The archive is merely stale.
    public let stale: [String]
    /// When the archive was last written, as recorded in the manifest.
    public let sealedAt: String?

    public init(root: String, unsealed: [String], stale: [String], sealedAt: String?) {
        self.root = root
        self.unsealed = unsealed
        self.stale = stale
        self.sealedAt = sealedAt
    }

    /// Every secret on disk is also in the archive.
    public var sealed: Bool { unsealed.isEmpty && stale.isEmpty }

    /// `sealed` and `summary` are computed, and a computed property is not encoded. They are
    /// written out explicitly so the browser and the CLI read one definition, not two.
    private enum CodingKeys: String, CodingKey {
        case root, unsealed, stale, sealedAt, sealed, summary
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(unsealed, forKey: .unsealed)
        try container.encode(stale, forKey: .stale)
        try container.encodeIfPresent(sealedAt, forKey: .sealedAt)
        try container.encode(sealed, forKey: .sealed)
        try container.encodeIfPresent(summary, forKey: .summary)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(String.self, forKey: .root)
        unsealed = try container.decode([String].self, forKey: .unsealed)
        stale = try container.decode([String].self, forKey: .stale)
        sealedAt = try container.decodeIfPresent(String.self, forKey: .sealedAt)
    }

    /// What to show next to the state directory.
    public var summary: String? {
        if !unsealed.isEmpty {
            return unsealed.count == 1
                ? "1 secret file not in the backup"
                : "\(unsealed.count) secret files not in the backup"
        }
        if !stale.isEmpty { return "backup is stale" }
        return nil
    }
}

/// Compares the secrets on disk against the manifest of what was last sealed.
///
/// Reads hashes only — it never decrypts, so it needs no age identity and is cheap enough to run
/// on every status call.
public struct SealAudit: Sendable {
    private let listFiles: @Sendable (String) throws -> [String]
    private let hash: @Sendable (String) throws -> String
    private let readManifest: @Sendable (String) throws -> String

    public init(
        listFiles: @escaping @Sendable (String) throws -> [String] = SealAudit.liveList,
        hash: @escaping @Sendable (String) throws -> String = SealAudit.liveHash,
        readManifest: @escaping @Sendable (String) throws -> String = { path in
            try String(contentsOfFile: path, encoding: .utf8)
        }
    ) {
        self.listFiles = listFiles
        self.hash = hash
        self.readManifest = readManifest
    }

    /// Parses `secrets.manifest`: a `# Sealed <timestamp>` header, then `<sha256>  <path>` lines.
    public static func parseManifest(
        _ text: String
    ) -> (sealedAt: String?, hashes: [String: String]) {
        var sealedAt: String?
        var hashes: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                // "# Sealed 2026-08-05T00:47:24Z — contents of secrets.tar.age"
                if sealedAt == nil, let range = trimmed.range(of: "Sealed ") {
                    sealedAt = trimmed[range.upperBound...]
                        .split(separator: " ").first.map(String.init)
                }
                continue
            }
            guard !trimmed.isEmpty else { continue }
            // shasum separates with two spaces, but splitting on any run of whitespace means a
            // hand-edited manifest still parses.
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            hashes[parts.dropFirst().joined(separator: " ")] = String(parts[0])
        }
        return (sealedAt, hashes)
    }

    /// What is on disk but not in the archive.
    public func status(root: String) throws -> SealStatus {
        let expanded = Paths.expanded(root)
        let text = (try? readManifest(expanded + "/" + SealedState.manifestName)) ?? ""
        let (sealedAt, recorded) = Self.parseManifest(text)

        let onDisk = try listFiles(expanded).filter(SealedState.isSecret).sorted()

        var unsealed: [String] = []
        for path in onDisk {
            guard let known = recorded[path] else {
                unsealed.append(path)  // never sealed at all
                continue
            }
            // A file that cannot be hashed is reported rather than quietly passed.
            let current = (try? hash(expanded + "/" + path)) ?? ""
            if current != known { unsealed.append(path) }
        }

        return SealStatus(
            root: expanded,
            unsealed: unsealed,
            stale: recorded.keys.filter { !onDisk.contains($0) }.sorted(),
            sealedAt: sealedAt
        )
    }

    public static let liveList: @Sendable (String) throws -> [String] = { root in
        let base = URL(fileURLWithPath: root).standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            // Pruning here rather than filtering afterwards keeps the walk out of .terraform,
            // which holds the provider binaries and is by far the largest thing in the tree.
            if url.lastPathComponent == ".terraform" || url.lastPathComponent == ".git" {
                walker.skipDescendants()
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base.path + "/") else { continue }
            found.append(String(path.dropFirst(base.path.count + 1)))
        }
        return found
    }

    public static let liveHash: @Sendable (String) throws -> String = { path in
        SHA256.hex(try Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

/// Re-seals a state directory after hatchery has written to it.
///
/// Runs the directory's own `seal.sh`. Hatchery deliberately does not reimplement the sealing:
/// the script decides what counts as a secret and which key it encrypts to, and a second
/// implementation drifting from it is how a file ends up believed-sealed and absent.
public struct StateSealer: Sendable {
    private let execute: CommandExecutor
    private let exists: @Sendable (String) -> Bool

    public init(
        execute: @escaping CommandExecutor,
        exists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) {
        self.execute = execute
        self.exists = exists
    }

    public enum Outcome: Sendable, Equatable {
        /// Not a sealed directory — no marker. Nothing to do and nothing to warn about.
        case notSealed
        /// Marked as sealed but carrying no `seal.sh` to run.
        case noScript(root: String)
        case sealed(root: String, detail: String)
        case failed(root: String, detail: String)

        /// Whether the caller should say something. A directory that is not sealed at all is
        /// not a problem; one that is sealed and failed to seal very much is.
        public var isProblem: Bool {
            switch self {
            case .notSealed, .sealed: return false
            case .noScript, .failed: return true
            }
        }

        public var message: String? {
            switch self {
            case .notSealed:
                return nil
            case .noScript(let root):
                return "\(root) is marked sealed but has no \(SealedState.scriptName); "
                    + "secrets there are not backed up"
            case .sealed(let root, _):
                return "sealed secrets in \(root)"
            case .failed(let root, let detail):
                return "could not seal \(root): \(detail)"
            }
        }
    }

    /// Seals the directory containing `path`, if it is one that seals.
    @discardableResult
    public func seal(pathInside path: String) async -> Outcome {
        guard let root = SealedState.root(containing: path, exists: exists) else {
            return .notSealed
        }
        let script = root + "/" + SealedState.scriptName
        guard exists(script) else { return .noScript(root: root) }

        do {
            let result = try await execute(["./" + SealedState.scriptName], root)
            guard result.status == 0 else {
                return .failed(root: root, detail: result.combined)
            }
            return .sealed(root: root, detail: result.combined)
        } catch {
            return .failed(root: root, detail: "\(error)")
        }
    }
}

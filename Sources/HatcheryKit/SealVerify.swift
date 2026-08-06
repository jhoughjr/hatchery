import Foundation

/// What happened when the archive was actually opened.
///
/// `SealAudit` compares what is on disk against the manifest and never touches the archive, so a
/// truncated or unopenable `secrets.tar.age` passes it cleanly. That is a green light for the one
/// thing nobody checks until they need it. This opens the archive.
public enum SealVerification: Sendable, Equatable {
    /// Decrypted, and every file inside matches the manifest.
    case verified(files: Int)
    /// Decrypted, but the contents disagree with the manifest.
    case mismatch(missing: [String], differing: [String])
    /// Did not decrypt at all — corrupt, truncated, or encrypted to a key this is not.
    case unopenable(detail: String)
    /// The key is not on this machine, so nothing can be said either way.
    case noIdentity(path: String)
    /// No archive to open yet.
    case noArchive
    case notSealed

    /// Whether someone needs to do something about it.
    public var isProblem: Bool {
        switch self {
        case .verified, .notSealed, .noArchive: return false
        case .mismatch, .unopenable, .noIdentity: return true
        }
    }

    public var summary: String {
        switch self {
        case .verified(let files):
            return "opened and matched \(files) file(s)"
        case .mismatch(let missing, let differing):
            let parts = [
                missing.isEmpty ? nil : "\(missing.count) missing",
                differing.isEmpty ? nil : "\(differing.count) differing",
            ].compactMap { $0 }
            return "archive opened but does not match the manifest: " + parts.joined(separator: ", ")
        case .unopenable(let detail):
            return "the archive did not open — the backup is unusable: \(detail)"
        case .noIdentity(let path):
            return "no age identity at \(path), so the backup cannot be verified here"
        case .noArchive:
            return "nothing sealed yet"
        case .notSealed:
            return "not a sealed directory"
        }
    }
}

/// Opens the archive and checks it against the manifest.
///
/// Runs the directory's own `unseal.sh --check`, which decrypts to a scratch directory and
/// compares — the same reason sealing runs `seal.sh`: one implementation decides what the archive
/// is, and a second one drifting from it is how a backup comes to be trusted wrongly.
public struct SealVerifier: Sendable {
    private let execute: CommandExecutor
    private let exists: @Sendable (String) -> Bool

    public static let scriptName = "unseal.sh"

    public init(
        execute: @escaping CommandExecutor = ShellRunner.liveExecutor,
        exists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) {
        self.execute = execute
        self.exists = exists
    }

    public func verify(pathInside path: String) async -> SealVerification {
        guard let root = SealedState.root(containing: path, exists: exists) else {
            return .notSealed
        }
        guard exists(root + "/" + SealedState.archiveName) else { return .noArchive }
        guard exists(root + "/" + Self.scriptName) else {
            return .unopenable(detail: "\(root) has no \(Self.scriptName) to open it with")
        }

        let result: CommandOutput
        do {
            result = try await execute(["./" + Self.scriptName, "--check"], root)
        } catch {
            return .unopenable(detail: "\(error)")
        }
        return Self.interpret(output: result.combined, status: result.status)
    }

    /// Reads what `unseal.sh --check` printed.
    ///
    /// Exit status alone cannot tell a content mismatch from a failure to decrypt — the script
    /// exits 1 for both — so the distinction comes from whether it managed to report on any file
    /// at all. That difference matters: one means a file changed, the other means the whole
    /// backup is gone.
    public static func interpret(output: String, status: Int32) -> SealVerification {
        var verified = 0
        var missing: [String] = []
        var differing: [String] = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "ok": verified += 1
            case "MISSING": missing.append(path)
            case "DIFFERS": differing.append(path)
            default: continue
            }
        }

        if output.contains("no age identity at") {
            // The line reads "error: no age identity at /path" — take the path so the remedy can
            // name it rather than say "somewhere".
            let path = output.split(separator: "\n")
                .first { $0.contains("no age identity at") }
                .flatMap { $0.components(separatedBy: "no age identity at ").last }?
                .trimmingCharacters(in: .whitespaces) ?? "the configured path"
            return .noIdentity(path: path)
        }

        if !missing.isEmpty || !differing.isEmpty {
            return .mismatch(missing: missing, differing: differing)
        }
        if status != 0 || verified == 0 {
            // Nothing was reported about any file, and it failed. The archive never opened.
            return .unopenable(
                detail: output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "exit \(status)" : output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .verified(files: verified)
    }
}

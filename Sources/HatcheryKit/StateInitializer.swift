import Foundation

public enum StateInitError: Error, Equatable, CustomStringConvertible {
    case toolMissing(String, hint: String)
    case commandFailed(String, detail: String)
    case recipientMismatch(stored: String, derived: String)

    public var description: String {
        switch self {
        case .toolMissing(let tool, let hint):
            return "\(tool) is not installed. \(hint)"
        case .commandFailed(let what, let detail):
            return "\(what) failed: \(detail)"
        case .recipientMismatch(let stored, let derived):
            return """
                the key at the identity path does not match .age-recipient
                  archive is encrypted to  \(stored)
                  this key would produce   \(derived)
                Using it would write an archive the old one cannot open. Point --identity at the \
                original key, or move .age-recipient aside deliberately.
                """
        }
    }
}

/// What actually happened, so the caller can report it rather than guess.
public struct StateInitResult: Sendable, Equatable {
    public var created: [String] = []
    public var preserved: [String] = []
    public var generatedIdentity: Bool = false
    public var recipient: String = ""
    public var gitInitialised: Bool = false
    public var committed: Bool = false
    public var remote: String?
    public var pushed: Bool = false
    public var warnings: [String] = []
}

/// Performs a `StateInitPlan`.
///
/// Every step is skipped when it has already been done, so running this twice is safe. That
/// matters more than it sounds: the failure this whole feature exists to prevent is a setup
/// nobody repeats, and a setup that breaks when repeated is one nobody dares repeat.
public struct StateInitializer: Sendable {
    private let execute: CommandExecutor
    private let exists: @Sendable (String) -> Bool
    private let read: @Sendable (String) -> String?
    private let write: @Sendable (String, String, Bool) throws -> Void
    private let makeDirectory: @Sendable (String) throws -> Void
    private let platform: Platform

    public init(
        execute: @escaping CommandExecutor = ShellRunner.liveExecutor,
        exists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        read: @escaping @Sendable (String) -> String? = {
            try? String(contentsOfFile: $0, encoding: .utf8)
        },
        write: @escaping @Sendable (String, String, Bool) throws -> Void = { path, contents, executable in
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
            if executable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: path)
            }
        },
        makeDirectory: @escaping @Sendable (String) throws -> Void = { path in
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
        },
        platform: Platform = .current
    ) {
        self.execute = execute
        self.exists = exists
        self.read = read
        self.write = write
        self.makeDirectory = makeDirectory
        self.platform = platform
    }

    /// Tools the plan needs, checked before anything is written.
    public func preflight(_ plan: StateInitPlan) async -> [PreflightCheck] {
        var checks: [PreflightCheck] = []
        for tool in ["age", "age-keygen", "git"] + (plan.remote != nil ? ["gh"] : []) {
            let found = (try? await execute(["which", tool], nil))?.status == 0
            checks.append(
                PreflightCheck(
                    name: tool,
                    status: found ? .ok : .failed,
                    detail: found ? "found" : "not found on PATH",
                    remedy: found ? nil : InstallHint.forTool(tool, platform: platform)))
        }
        return checks
    }

    public func run(_ plan: StateInitPlan) async throws -> StateInitResult {
        var result = StateInitResult()
        result.warnings = plan.warnings
        result.remote = plan.remote

        try makeDirectory(plan.directory)

        // 1. The key. Generated only when absent — a new key orphans an existing archive.
        let identity = plan.identityPath
        let recipientPath = plan.directory + "/" + SealedState.marker
        let storedRecipient = exists(recipientPath)
            ? (read(recipientPath) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        // Checked before generating anything. A directory that already encrypts to a key, plus
        // an identity path with no key at it, can only end in a mismatch — and generating first
        // would leave a stray key behind on the way to that error.
        if let stored = storedRecipient, !exists(identity) {
            throw StateInitError.recipientMismatch(stored: stored, derived: "a newly generated key")
        }

        if !exists(identity) {
            try makeDirectory(URL(fileURLWithPath: identity).deletingLastPathComponent().path)
            let generated = try await execute(["age-keygen", "-o", identity], nil)
            guard generated.status == 0 else {
                throw StateInitError.commandFailed("age-keygen", detail: generated.combined)
            }
            result.generatedIdentity = true
        }

        // 2. The recipient, derived from the key rather than typed. Deriving it is also the only
        // proof the key and the archive belong together.
        let derived = try await execute(["age-keygen", "-y", identity], nil)
        guard derived.status == 0 else {
            throw StateInitError.commandFailed("age-keygen -y", detail: derived.combined)
        }
        let recipient = derived.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        result.recipient = recipient

        if let stored = storedRecipient {
            // Refuse rather than overwrite. Rewriting this silently produces an archive the
            // previous key cannot open, and nothing would say so until a restore failed.
            guard stored == recipient else {
                throw StateInitError.recipientMismatch(stored: stored, derived: recipient)
            }
            result.preserved.append(SealedState.marker)
        } else {
            try write(recipientPath, recipient + "\n", false)
            result.created.append(SealedState.marker)
        }

        // 3. The scripts and the ignore rules.
        for file in plan.files {
            let path = plan.directory + "/" + file.path
            if file.preserveExisting, exists(path) {
                result.preserved.append(file.path)
                continue
            }
            try write(path, file.contents, file.executable)
            result.created.append(file.path)
        }

        // 4. Version control. `git init` on an existing repository is a no-op by design, but
        // checking keeps the report honest about what this run actually did.
        if !exists(plan.directory + "/.git") {
            let initialised = try await execute(["git", "init", "-b", "main"], plan.directory)
            guard initialised.status == 0 else {
                throw StateInitError.commandFailed("git init", detail: initialised.combined)
            }
            result.gitInitialised = true
        }

        return result
    }

    /// Commits what is there and, when a remote is named, creates it private and pushes.
    ///
    /// Split from `run` because it is the only outward-facing part: everything above happens on
    /// this machine, and this publishes. A caller that wants the directory set up without
    /// anything leaving the laptop simply does not call it.
    public func publish(_ plan: StateInitPlan, message: String) async throws -> StateInitResult {
        var result = StateInitResult()
        result.remote = plan.remote

        let staged = try await execute(["git", "add", "-A"], plan.directory)
        guard staged.status == 0 else {
            throw StateInitError.commandFailed("git add", detail: staged.combined)
        }

        // An empty commit means there was nothing to save, which is not an error.
        let committed = try await execute(["git", "commit", "-m", message], plan.directory)
        result.committed = committed.status == 0

        guard let remote = plan.remote, remote.contains("/") else { return result }

        // `gh repo create` is idempotent enough to lean on: it fails when the repository exists,
        // and that failure is the signal to just add the remote instead.
        let created = try await execute(
            ["gh", "repo", "create", remote, "--private", "--source", plan.directory, "--remote", "origin"],
            plan.directory)
        if created.status != 0 {
            // Already exists, or the remote is already wired. Neither is worth failing over;
            // the push below is what actually matters and it will report its own trouble.
            let url = "git@github.com:\(remote).git"
            _ = try? await execute(["git", "remote", "add", "origin", url], plan.directory)
        }

        let pushed = try await execute(["git", "push", "-u", "origin", "main"], plan.directory)
        guard pushed.status == 0 else {
            throw StateInitError.commandFailed("git push", detail: pushed.combined)
        }
        result.pushed = true
        return result
    }
}

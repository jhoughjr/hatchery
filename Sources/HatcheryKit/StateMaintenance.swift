import Foundation

/// Keeps the encrypted backup current without anyone having to remember it.
///
/// Every command that writes a secret file — a scaffolded config, a synced value, an apply that
/// rewrites tfstate — calls this afterwards. The alternative is what shipped before: `seal.sh`
/// was correct, and simply never ran, so a minted signing key existed on exactly one disk for a
/// day without anything saying so.
public enum StateMaintenance {
    /// Seals the directory `path` belongs to. Returns a line worth printing, or nil when there
    /// is nothing to say.
    ///
    /// Never throws. This runs after the real work has already succeeded, and a backup problem
    /// must not turn a completed deploy into a failed command — it has to be *reported*, which
    /// is why a failure still returns a line rather than swallowing itself.
    public static func seal(
        after path: String,
        execute: @escaping CommandExecutor = ShellRunner.liveExecutor
    ) async -> String? {
        let outcome = await StateSealer(execute: execute).seal(pathInside: path)
        guard let message = outcome.message else { return nil }
        return outcome.isProblem ? "warning: \(message)" : message
    }

    /// The seal as an injectable value, for parameters whose default is the live behaviour.
    ///
    /// This exists because of where it is used, not what it does. Writing the same closure as
    /// a literal in a default-argument position compiles into a generator whose task-stack
    /// allocations release out of order, and Swift 6.3.3 aborts with "freed pointer was not
    /// the last allocation" at the first await through the closure (issue #36). A reference to
    /// a closure built here never goes through that generator.
    public static let liveSeal: @Sendable (String) async -> String? = { path in
        await seal(after: path)
    }
}

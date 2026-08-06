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
}

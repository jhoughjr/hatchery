import Foundation
import HatcheryKit

/// The way `acquire()` refuses.
///
/// - `held`: another adopt already holds the lock, and started less than an hour ago.
public enum AdoptLockError: Error, CustomStringConvertible, Equatable {
    case held(pid: Int32, since: Date)

    public var description: String {
        switch self {
        case .held(let pid, let since):
            return "adopt is already running as pid \(pid), started \(ISO8601DateFormatter().string(from: since)); wait for it to finish"
        }
    }
}

/// Keeps two adopters from running against the same manifest at once.
///
/// Two adopters racing the same box was one of the phase 1 findings: nothing else serializes
/// them, and each writes the manifest without knowing about the other.
public struct AdoptLock: Sendable {
    public let path: String

    public init(manifestDirectory: String) {
        self.path = Paths.join(manifestDirectory, ".adopt.lock")
    }

    /// Takes the lock, throwing when a holder less than an hour old is already there. An
    /// older holder is treated as abandoned: taken over, and reported through `report`.
    public func acquire(
        now: Date = Date(),
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        report: (String) -> Void = { print($0) }
    ) throws {
        if let holder = Self.holder(atPath: path) {
            guard now.timeIntervalSince(holder.at) >= 3600 else {
                throw AdoptLockError.held(pid: holder.pid, since: holder.at)
            }
            report("  a stale adopt lock from pid \(holder.pid) (older than an hour) was taken over")
        }
        let line = "\(pid) \(ISO8601DateFormatter().string(from: now))"
        try line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Releases the lock. Missing is not an error: a lock that was never taken has nothing to
    /// release, which is the state `--dry-run` leaves things in.
    public func release() {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func holder(atPath path: String) -> (pid: Int32, at: Date)? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let parts = contents.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, let pid = Int32(parts[0]),
            let at = ISO8601DateFormatter().date(from: String(parts[1]))
        else { return nil }
        return (pid, at)
    }
}

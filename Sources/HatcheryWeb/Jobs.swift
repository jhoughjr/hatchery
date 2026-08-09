import Foundation

/// Long-running work the dashboard can watch while it happens.
///
/// A job is a transcript with a state: lines arrive as the work narrates, the page polls for
/// what it has not yet seen, and the state says whether the narration is over. Any phase can
/// run as one — apply today; create, destroy and deploy whenever their silence next hurts.
final class JobStore: @unchecked Sendable {
    struct Snapshot {
        let lines: [String]
        let state: String
        let next: Int
    }

    private let lock = NSLock()
    private var jobs: [String: (lines: [String], state: String)] = [:]

    /// A short id the page can poll with.
    func create() -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        lock.lock()
        jobs[id] = ([], "running")
        lock.unlock()
        return id
    }

    func append(_ id: String, _ line: String) {
        lock.lock()
        jobs[id]?.lines.append(line)
        lock.unlock()
    }

    func finish(_ id: String, ok: Bool) {
        lock.lock()
        jobs[id]?.state = ok ? "ok" : "failed"
        lock.unlock()
    }

    /// Everything from `from` on, plus where to poll from next. Nil for a job never started.
    func snapshot(_ id: String, from: Int) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else { return nil }
        let start = min(max(from, 0), job.lines.count)
        return Snapshot(
            lines: Array(job.lines[start...]), state: job.state, next: job.lines.count)
    }
}

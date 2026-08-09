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
        /// A JSON payload the finishing phase left for the page — the clone job parks its
        /// missing-keys summary here, because a transcript is prose and the fill-in dialog
        /// needs structure.
        let result: String?
    }

    private let lock = NSLock()
    private var jobs: [String: (lines: [String], state: String, result: String?)] = [:]

    /// A short id the page can poll with.
    func create() -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        lock.lock()
        jobs[id] = ([], "running", nil)
        lock.unlock()
        return id
    }

    func append(_ id: String, _ line: String) {
        lock.lock()
        jobs[id]?.lines.append(line)
        lock.unlock()
    }

    func finish(_ id: String, ok: Bool, result: String? = nil) {
        lock.lock()
        jobs[id]?.state = ok ? "ok" : "failed"
        jobs[id]?.result = result
        lock.unlock()
    }

    /// Everything from `from` on, plus where to poll from next. Nil for a job never started.
    func snapshot(_ id: String, from: Int) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else { return nil }
        let start = min(max(from, 0), job.lines.count)
        return Snapshot(
            lines: Array(job.lines[start...]), state: job.state, next: job.lines.count,
            result: job.state == "running" ? nil : job.result)
    }
}

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One observed change in a service's health.
///
/// `from` is always a real prior observation. The first look at a service is a baseline,
/// not a transition — recording "came up ready" for every service on every serve restart
/// would bury the lines that mean something.
public struct HealthTransition: Sendable, Equatable, Codable {
    public let at: Date
    public let stack: String
    public let service: String
    public let from: HealthState
    public let to: HealthState
    /// Reason lines that appeared with this change.
    public let gained: [String]
    /// Reason lines that stopped being reported.
    public let lost: [String]

    public init(
        at: Date, stack: String, service: String,
        from: HealthState, to: HealthState,
        gained: [String] = [], lost: [String] = []
    ) {
        self.at = at
        self.stack = stack
        self.service = service
        self.from = from
        self.to = to
        self.gained = gained
        self.lost = lost
    }

    public var worsened: Bool { to < from }
    public var improved: Bool { from < to }

    /// The one-line form: what the console prints, what a webhook sends, what the page lists.
    public var line: String {
        var text = from == to
            ? "\(stack)/\(service): still \(to.rawValue)"
            : "\(stack)/\(service): \(from.rawValue) → \(to.rawValue)"
        var notes: [String] = []
        if !gained.isEmpty { notes.append("+ " + gained.joined(separator: "; ")) }
        if !lost.isEmpty { notes.append("− " + lost.joined(separator: "; ")) }
        if !notes.isEmpty { text += " (" + notes.joined(separator: " ") + ")" }
        return text
    }
}

/// Diffs two status snapshots into transitions.
///
/// This is the caller `ServiceHealth.reasons` was designed for: the probe layer keeps its
/// failure lines short and stable exactly so that set-difference between polls means
/// something.
public enum HealthLedger {
    public static func transitions(
        from old: [StackStatus], to new: [StackStatus], at: Date
    ) -> [HealthTransition] {
        var before: [String: ServiceHealth] = [:]
        for stack in old {
            for service in stack.services {
                before["\(stack.stack)\u{0}\(service.service)"] = service
            }
        }

        var changes: [HealthTransition] = []
        for stack in new {
            for service in stack.services {
                // A service seen for the first time is a baseline, and one that left the
                // manifest is a declaration change, not a health event. Transitions exist
                // only between two observations of the same service.
                guard let prior = before["\(stack.stack)\u{0}\(service.service)"] else { continue }
                guard prior.state != service.state || prior.reasons != service.reasons else { continue }
                changes.append(
                    HealthTransition(
                        at: at, stack: stack.stack, service: service.service,
                        from: prior.state, to: service.state,
                        gained: service.reasons.filter { !prior.reasons.contains($0) },
                        lost: prior.reasons.filter { !service.reasons.contains($0) }))
            }
        }
        return changes
    }
}

/// An append-only record of transitions, one JSON object per line.
///
/// A flat file beside the manifest, because the question this answers — "what happened
/// while I wasn't looking" — should survive the process that noticed it, and should be
/// readable with grep when the dashboard itself is what's broken.
public struct TransitionLog: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func append(_ transitions: [HealthTransition]) {
        guard !transitions.isEmpty else { return }
        var lines = Data()
        for transition in transitions {
            guard let encoded = try? Self.encoder.encode(transition) else { continue }
            lines.append(encoded)
            lines.append(0x0A)
        }

        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: path, contents: nil)
        }
        // A failed append is dropped rather than fatal: a full disk should degrade the
        // record, not take the monitoring down with it. The live dashboard is unaffected.
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: lines)
    }

    /// The most recent transitions, newest first. A line that does not parse is skipped,
    /// so one torn write cannot hide the rest of the file.
    public func recent(limit: Int) -> [HealthTransition] {
        guard limit > 0, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return []
        }
        let parsed = data.split(separator: 0x0A).compactMap {
            try? Self.decoder.decode(HealthTransition.self, from: Data($0))
        }
        return parsed.suffix(limit).reversed()
    }
}

/// Polls on the server's clock, so history accrues with no browser open.
///
/// The browser's ten-second poll was the only heartbeat the dashboard had, which meant
/// closing the tab stopped anyone watching. This actor owns the previous snapshot, writes
/// what changed to the log, and hands worsening transitions to the alert sink.
public actor HealthWatcher {
    public typealias Probe = @Sendable () async -> [StackStatus]
    public typealias AlertSink = @Sendable ([HealthTransition]) async -> Void

    private let probe: Probe
    private let log: TransitionLog
    private let alert: AlertSink?
    private var previous: [StackStatus]?

    public init(probe: @escaping Probe, log: TransitionLog, alert: AlertSink? = nil) {
        self.probe = probe
        self.log = log
        self.alert = alert
    }

    /// One poll: probe, diff, record, alert. Returns what changed so a caller can narrate.
    @discardableResult
    public func poll(now: Date = Date()) async -> [HealthTransition] {
        let current = await probe()
        defer { previous = current }
        guard let previous else { return [] }

        let changes = HealthLedger.transitions(from: previous, to: current, at: now)
        guard !changes.isEmpty else { return [] }
        log.append(changes)

        // Only worsening reaches the sink. Recovery is visible in the history and on the
        // page; waking someone up for it is how alerts get muted.
        let worsening = changes.filter(\.worsened)
        if !worsening.isEmpty, let alert {
            await alert(worsening)
        }
        return changes
    }
}

/// Posts worsening transitions to one URL as JSON.
///
/// The payload carries both a `text` line for anything chat-shaped and the structured
/// events for anything that wants to route on them. The poster is replaceable so no test
/// opens a socket.
public enum AlertWebhook {
    /// Returns `nil` when delivered, or a short reason.
    public typealias Poster = @Sendable (URL, Data) async -> String?

    public static let live: Poster = { url, body in
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "no HTTP response" }
            guard (200..<300).contains(http.statusCode) else { return "HTTP \(http.statusCode)" }
            return nil
        } catch {
            return URLSessionTransport.reason(for: error)
        }
    }

    struct Payload: Encodable {
        let text: String
        let events: [HealthTransition]
    }

    public static func sink(url: URL, post: @escaping Poster = live) -> HealthWatcher.AlertSink {
        { transitions in
            let payload = Payload(
                text: transitions.map(\.line).joined(separator: "\n"),
                events: transitions)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let body = try? encoder.encode(payload) else { return }
            if let failure = await post(url, body) {
                // The alert path has no one to alert. One honest line on the console the
                // serve process already owns beats swallowing it.
                print("alert webhook: \(failure)")
            }
        }
    }
}

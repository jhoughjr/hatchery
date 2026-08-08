import XCTest

@testable import HatcheryKit

/// The reason lines are short and stable so that set-difference between polls means
/// something. These tests are the caller that contract was written for.
final class HealthHistoryTests: XCTestCase {
    private func snapshot(
        _ services: [(String, HealthState, [String])], stack: String = "mwlab"
    ) -> [StackStatus] {
        [
            StackStatus(
                stack: stack,
                services: services.map {
                    ServiceHealth(service: $0.0, state: $0.1, reasons: $0.2)
                })
        ]
    }

    private let when = Date(timeIntervalSince1970: 1_754_600_000)

    // MARK: - Ledger

    func testUnchangedSnapshotsEmitNothing() {
        let now = snapshot([("api", .ready, []), ("web", .degraded, ["HTTP 502"])])
        XCTAssertEqual(HealthLedger.transitions(from: now, to: now, at: when), [])
    }

    func testWorseningCarriesTheReasonsItGained() {
        let before = snapshot([("api", .ready, [])])
        let after = snapshot([("api", .degraded, ["1 migration pending"])])
        let changes = HealthLedger.transitions(from: before, to: after, at: when)

        XCTAssertEqual(changes.count, 1)
        let change = try! XCTUnwrap(changes.first)
        XCTAssertTrue(change.worsened)
        XCTAssertFalse(change.improved)
        XCTAssertEqual(change.gained, ["1 migration pending"])
        XCTAssertEqual(change.lost, [])
        XCTAssertEqual(change.line, "mwlab/api: ready → degraded (+ 1 migration pending)")
    }

    func testRecoveryCarriesTheReasonsItLost() {
        let before = snapshot([("api", .unreachable, ["timed out"])])
        let after = snapshot([("api", .ready, [])])
        let changes = HealthLedger.transitions(from: before, to: after, at: when)

        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].improved)
        XCTAssertEqual(changes[0].lost, ["timed out"])
        XCTAssertEqual(changes[0].line, "mwlab/api: unreachable → ready (− timed out)")
    }

    func testAReasonChangeAtTheSameStateStillRecords() {
        // Degraded for a new reason is a different incident, not a continuation.
        let before = snapshot([("api", .degraded, ["HTTP 500"])])
        let after = snapshot([("api", .degraded, ["1 migration pending"])])
        let changes = HealthLedger.transitions(from: before, to: after, at: when)

        XCTAssertEqual(changes.count, 1)
        XCTAssertFalse(changes[0].worsened)
        XCTAssertFalse(changes[0].improved)
        XCTAssertEqual(
            changes[0].line,
            "mwlab/api: still degraded (+ 1 migration pending − HTTP 500)")
    }

    func testTheFirstSightOfAServiceIsABaselineNotATransition() {
        let after = snapshot([("api", .degraded, ["HTTP 500"])])
        XCTAssertEqual(HealthLedger.transitions(from: [], to: after, at: when), [])
    }

    func testAServiceLeavingTheManifestEmitsNothing() {
        let before = snapshot([("api", .ready, []), ("web", .ready, [])])
        let after = snapshot([("api", .ready, [])])
        XCTAssertEqual(HealthLedger.transitions(from: before, to: after, at: when), [])
    }

    // MARK: - Log

    private func temporaryPath() -> String {
        NSTemporaryDirectory() + "hatchery-tests-\(UUID().uuidString)/history.jsonl"
    }

    private func transition(
        _ service: String, from: HealthState, to: HealthState, at: Date
    ) -> HealthTransition {
        HealthTransition(at: at, stack: "mwlab", service: service, from: from, to: to)
    }

    func testAppendedTransitionsComeBackNewestFirst() {
        let log = TransitionLog(path: temporaryPath())
        log.append([
            transition("api", from: .ready, to: .degraded, at: when),
            transition("api", from: .degraded, to: .unreachable, at: when + 30),
        ])
        log.append([transition("api", from: .unreachable, to: .ready, at: when + 60)])

        let recent = log.recent(limit: 10)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map(\.to), [.ready, .unreachable, .degraded])
        XCTAssertEqual(recent[0].at, when + 60)

        XCTAssertEqual(log.recent(limit: 2).map(\.to), [.ready, .unreachable])
    }

    func testACorruptLineHidesOnlyItself() throws {
        let path = temporaryPath()
        let log = TransitionLog(path: path)
        log.append([transition("api", from: .ready, to: .degraded, at: when)])

        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        log.append([transition("api", from: .degraded, to: .ready, at: when + 30)])

        XCTAssertEqual(log.recent(limit: 10).map(\.to), [.ready, .degraded])
    }

    func testAMissingFileReadsAsAnEmptyHistory() {
        XCTAssertEqual(TransitionLog(path: temporaryPath()).recent(limit: 10), [])
    }

    func testTheSidecarTakesTheManifestsName() {
        XCTAssertEqual(
            TransitionLog.defaultPath(besideManifest: "/etc/hatchery/hatchery.json"),
            "/etc/hatchery/hatchery.history.jsonl")
        XCTAssertEqual(
            TransitionLog.defaultPath(besideManifest: "/lab/mystack.json"),
            "/lab/mystack.history.jsonl")
    }

    // MARK: - Watcher

    /// Hands out one scripted snapshot per poll.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [[StackStatus]]
        init(_ snapshots: [[StackStatus]]) { self.snapshots = snapshots }
        func next() -> [StackStatus] {
            lock.lock()
            defer { lock.unlock() }
            return snapshots.isEmpty ? [] : snapshots.removeFirst()
        }
    }

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[HealthTransition]] = []
        func record(_ transitions: [HealthTransition]) {
            lock.lock()
            batches.append(transitions)
            lock.unlock()
        }
        func all() -> [[HealthTransition]] {
            lock.lock()
            defer { lock.unlock() }
            return batches
        }
    }

    func testOnlyWorseningReachesTheAlertSink() async {
        let script = Script([
            snapshot([("api", .ready, [])]),
            snapshot([("api", .degraded, ["HTTP 502"])]),
            snapshot([("api", .ready, [])]),
        ])
        let alerts = Captured()
        let path = temporaryPath()
        let watcher = HealthWatcher(
            probe: { script.next() },
            log: TransitionLog(path: path),
            alert: { alerts.record($0) })

        let first = await watcher.poll(now: when)
        XCTAssertEqual(first, [], "the first look is a baseline")

        let second = await watcher.poll(now: when + 30)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[0].worsened)

        let third = await watcher.poll(now: when + 60)
        XCTAssertEqual(third.count, 1)
        XCTAssertTrue(third[0].improved)

        // The recovery is in the record but was never worth waking anyone for.
        XCTAssertEqual(alerts.all().count, 1)
        XCTAssertEqual(alerts.all()[0].map(\.to), [.degraded])
        XCTAssertEqual(TransitionLog(path: path).recent(limit: 10).count, 2)
    }

    // MARK: - Webhook

    func testTheWebhookPayloadCarriesLinesAndEvents() async {
        let received = Captured()
        let sink = AlertWebhook.sink(
            url: URL(string: "http://127.0.0.1:1/alerts")!,
            post: { _, body in
                struct Payload: Decodable {
                    let text: String
                    let events: [HealthTransition]
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let payload = try? decoder.decode(Payload.self, from: body) {
                    received.record(payload.events)
                    XCTAssertEqual(payload.text, payload.events.map(\.line).joined(separator: "\n"))
                }
                return nil
            })

        await sink([transition("api", from: .ready, to: .unreachable, at: when)])
        XCTAssertEqual(received.all().count, 1)
        XCTAssertEqual(received.all()[0].map(\.service), ["api"])
    }
}

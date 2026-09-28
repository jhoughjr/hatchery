import Foundation

/// What the token ledger knows about each secret that no declaration can say: the day the ledger first saw it, the day it
/// was last issued, and the last check of whether it works.
///
/// It exists because an issuer reports no issue date, so a token that predates the ledger has none until a rotation stamps
/// one. It is one JSON file on the machine that runs the rotations, and it holds names and dates, never a value.
public struct LedgerState: Codable, Sendable, Equatable {
    public var records: [String: Record]

    /// One secret on one service, keyed by ``LedgerState/id(stack:service:key:)``.
    public struct Record: Codable, Sendable, Equatable {
        /// The day the ledger first listed this key, as `yyyy-MM-dd`.
        public var firstSeen: String
        /// The day a rotation or a person last issued the value, as `yyyy-MM-dd`, or `nil` when nobody knows.
        public var issued: String?
        /// The last time something asked the issuer whether the value works.
        public var checked: Check?

        public init(firstSeen: String, issued: String? = nil, checked: Check? = nil) {
            self.firstSeen = firstSeen
            self.issued = issued
            self.checked = checked
        }
    }

    /// One answer from an issuer's own check, and the day it came.
    public struct Check: Codable, Sendable, Equatable {
        public var on: String
        public var live: Bool

        public init(on: String, live: Bool) {
            self.on = on
            self.live = live
        }
    }

    public init(records: [String: Record] = [:]) {
        self.records = records
    }

    /// Where the ledger keeps its dates when no path is given.
    /// It sits beside the operator token, on the Mac that runs `house-rotate`, so the rotation and the ledger read one file.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hatchery/ledger.json")
    }

    /// The one key a record is filed under.
    public static func id(stack: String, service: String, key: String) -> String {
        "\(stack)/\(service) \(key)"
    }
}

// MARK: - Recording

extension LedgerState {
    /// Records the first sighting of a key and answers its record. A key already seen keeps its first date.
    @discardableResult
    public mutating func see(_ id: String, on day: String) -> Record {
        if let record = self.records[id] { return record }
        let record = Record(firstSeen: day)
        self.records[id] = record
        return record
    }

    /// Stamps the day a value was issued, for every key one rotation or one person turned over.
    public mutating func stampIssued(stack: String, service: String, keys: [String], on day: String) {
        for key in keys {
            let id = Self.id(stack: stack, service: service, key: key)
            var record = self.see(id, on: day)
            record.issued = day
            self.records[id] = record
        }
    }

    /// Stamps every key whose rotation ran to the end in a `rotate --all` run.
    /// A refused, dry, skipped, or failed rotation issued nothing a holder took, so it stamps nothing.
    public mutating func stampIssued(from outcomes: [RotationOutcome], on day: String) {
        for outcome in outcomes where outcome.state == .run {
            self.stampIssued(stack: outcome.stack, service: outcome.service, keys: outcome.keys, on: day)
        }
    }
}

// MARK: - The file

extension LedgerState {
    /// Reads the ledger's file. A missing file is an empty ledger, which is what the first run sees.
    public static func load(from url: URL) throws -> LedgerState {
        guard FileManager.default.fileExists(atPath: url.path) else { return LedgerState() }
        return try JSONDecoder().decode(LedgerState.self, from: Data(contentsOf: url))
    }

    /// Writes the ledger's file whole, sorted, so a diff of two runs shows only what changed.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Days

/// A calendar day as the ledger writes it, `yyyy-MM-dd` in UTC.
/// A day and not a time, because an expiry typed from a console and an issue date both name a day.
public enum LedgerDay {
    public static func string(_ date: Date) -> String {
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The day a `yyyy-MM-dd` string names, or `nil` when the text is not such a day.
    public static func date(_ text: String) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return nil }
        guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: Self.calendar) else { return nil }
        return Self.calendar.date(from: components)
    }

    /// Whole days from one day to another, negative when `to` is earlier.
    public static func days(from: Date, to: Date) -> Int {
        let start = Self.calendar.startOfDay(for: from)
        let end = Self.calendar.startOfDay(for: to)
        return Self.calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
}

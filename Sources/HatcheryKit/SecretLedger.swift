import Foundation

/// One service's secrets as the ledger reads them: the kind file that declares them, and the keys the service carries.
public struct LedgerTarget: Sendable {
    public var stack: String
    public var service: String
    public var kind: KindFile
    /// The keys the service's config and secrets files declare, or `nil` to list every secret the kind declares.
    /// A kind shared by nine jobs declares a key once, and only the jobs that carry it hold a token.
    public var carried: Set<String>?

    public init(stack: String, service: String, kind: KindFile, carried: Set<String>? = nil) {
        self.stack = stack
        self.service = service
        self.kind = kind
        self.carried = carried
    }
}

/// One token in the ledger: who issues it, whether it is known to work, when it was issued, when it expires, and what is
/// owed to it next.
public struct LedgerRow: Sendable, Equatable {
    public var stack: String
    public var service: String
    public var key: String
    public var issuer: String
    public var liveness: Liveness
    /// The day the value was issued, or `nil` when nobody knows.
    public var issued: String?
    public var firstSeen: String
    public var expiry: Expiry
    /// Whether the typed expiry is a review date and not the issuer's own: no API checks this key, so the day in the
    /// kind file is when a person looks at the issuer's console, which is what Jimmy typed for Apple and Google on 2026-09-28.
    public var review: Bool
    public var next: Next
    /// The recipe of a person-issued key, which is the whole of what a person needs to turn it over.
    public var recipe: String?

    /// What the ledger knows about whether the value works.
    ///
    /// - `live`: the issuer's own check said it works.
    /// - `dead`: the issuer's own check refused it.
    /// - `cannotProbe`: no issuer API checks it, so it is checked by use only and never reads as live.
    /// - `notChecked`: an API could check it, and nothing has asked.
    public enum Liveness: String, Sendable, Equatable {
        case live
        case dead
        case cannotProbe = "cannot probe"
        case notChecked = "not checked"
    }

    /// When the value stops working, as far as the declaration says.
    ///
    /// - `undeclared`: the declaration names no expiry, and the key needs none because a probe can check it.
    /// - `notTyped`: a key that cannot be probed, with no expiry typed, so no reminder can fire.
    /// - `unreadable`: the typed expiry is not a `yyyy-MM-dd` day.
    /// - `on`: the typed day.
    public enum Expiry: Sendable, Equatable {
        case undeclared
        case notTyped
        case unreadable(String)
        case on(String)
    }

    /// What the ledger asks for next.
    ///
    /// - `nothing`: the issue date is known and nothing is owed.
    /// - `rotate`: the issue date is unknown, and hatchery can rotate it.
    /// - `rotateByHand`: the issue date is unknown, and a person rotates it by the recipe.
    /// - `reseal`: a new value locks what is sealed under the old one, so this key is never put up for rotation.
    /// - `heldFrom`: another service's rotation turns it over, so the owner's row carries the date.
    /// - `declareRotation`: the issue date is unknown, and no rotation is declared to turn it over.
    public enum Next: Sendable, Equatable {
        case nothing
        case rotate
        case rotateByHand
        case reseal
        case heldFrom(String)
        case declareRotation
    }

    /// Whether this row is put up for rotation: its issue date is unknown, and a rotation is how it becomes known.
    public var listedForRotation: Bool {
        switch self.next {
        case .rotate, .rotateByHand, .declareRotation:
            return true

        case .nothing, .reseal, .heldFrom:
            return false
        }
    }
}

/// The token ledger: every secret the declarations name, one row per service that carries it.
///
/// hatchery owns the list because it owns the declarations, and the dates come from ``LedgerState``.
/// It reads no box and asks no issuer, so every key an API could check reads `not checked` until a probe records one.
public enum SecretLedger {
    /// Keys whose issuer has no API that says the value works, as house#3 found: Apple's private keys and Google's client
    /// secrets. A kind file can mark any other key with `"probe": "none"`.
    public static let noIssuerAPI: Set<String> = ["APPLE_PRIVATE_KEY", "GOOGLE_CLIENT_SECRET"]

    /// Keys that other values are sealed under, as `<kind> <KEY>`, which a rotation must never turn over.
    /// On 2026-09-28 a minted `SESSION_SECRET` locked every app document in vault with no symptom until a restart.
    public static let sealingKeys: Set<String> = ["vault SESSION_SECRET"]

    /// How many days before a typed expiry the ledger starts to remind.
    /// Thirty covers a person away for a fortnight and the daily publish that carries the reminder to the board.
    public static let reminderDays = 30

    /// Whether the ledger can ever learn that this value works by asking its issuer.
    public static func cannotProbe(key: String, entry: KindFile.EnvEntry) -> Bool {
        entry.probe == .unavailable || Self.noIssuerAPI.contains(key)
    }

    /// Every row for these targets, in target order and then key order.
    /// A key seen for the first time gets today's date as its first sighting, written into `state`.
    public static func rows(for targets: [LedgerTarget], state: inout LedgerState, today: Date) -> [LedgerRow] {
        let day = LedgerDay.string(today)
        var rows: [LedgerRow] = []
        for target in targets {
            for entry in target.kind.secretRotations() {
                if let carried = target.carried, !carried.contains(entry.key) { continue }
                guard let declared = target.kind.environment[entry.key] else { continue }
                let record = state.see(
                    LedgerState.id(stack: target.stack, service: target.service, key: entry.key),
                    on: day)
                var row = Self.row(
                    stack: target.stack,
                    service: target.service,
                    kind: target.kind.kind,
                    key: entry.key,
                    entry: declared,
                    record: record)
                // A held key is turned over by its owner's rotation, so the owner's stamp is its issue date.
                // The owner's record is read and not seen, because the owner may sit on a manifest this run did not load.
                if case .heldFrom(let owner) = row.next, row.issued == nil {
                    row.issued = state.records["\(owner) \(entry.key)"]?.issued
                }
                rows.append(row)
            }
        }
        return rows
    }

    /// The row for one key, from its declaration and the ledger's record of it.
    static func row(
        stack: String, service: String, kind: String, key: String, entry: KindFile.EnvEntry, record: LedgerState.Record
    ) -> LedgerRow {
        let cannotProbe = Self.cannotProbe(key: key, entry: entry)

        // A cannot-probe key never reads live, whatever a check once recorded.
        let liveness: LedgerRow.Liveness
        if cannotProbe {
            liveness = .cannotProbe
        } else if let check = record.checked {
            liveness = check.live ? .live : .dead
        } else {
            liveness = .notChecked
        }

        let expiry: LedgerRow.Expiry
        if let typed = entry.expires {
            expiry = LedgerDay.date(typed) == nil ? .unreadable(typed) : .on(typed)
        } else {
            expiry = cannotProbe ? .notTyped : .undeclared
        }

        var issuer = "none declared"
        var recipe: String?
        var next: LedgerRow.Next = record.issued == nil ? .declareRotation : .nothing
        switch entry.rotation {
        case .owned(let owner)?:
            issuer = "held from \(owner)"
            next = .heldFrom(owner)

        case .declared(let rotation)?:
            issuer = Self.issuerWord(rotation.issuer)
            if case .manual(let text) = rotation.issuer { recipe = text }
            if record.issued == nil {
                next = rotation.issuer.isManual ? .rotateByHand : .rotate
            }

        case nil:
            break
        }
        // Checked last, so a sealing key is never put up for rotation even with its issue date unknown.
        if Self.sealingKeys.contains("\(kind) \(key)") {
            next = .reseal
        }

        return LedgerRow(
            stack: stack,
            service: service,
            key: key,
            issuer: issuer,
            liveness: liveness,
            issued: record.issued,
            firstSeen: record.firstSeen,
            expiry: expiry,
            review: cannotProbe,
            next: next,
            recipe: recipe)
    }

    /// The one word for who issues a value, short enough for a column.
    static func issuerWord(_ issuer: KindFile.Issuer) -> String {
        switch issuer {
        case .vaultAppKey, .vaultS3Key, .vaultSecret:
            return "vault"

        case .postgresRole:
            return "postgres"

        case .random:
            return "random"

        case .manual:
            return "person"
        }
    }
}

// MARK: - Reminders

extension SecretLedger {
    /// The reminder one key owes today, or `nil` when it owes none.
    /// A cannot-probe key with no typed expiry owes one too, because a reminder with no date can never fire.
    public static func reminder(key: String, entry: KindFile.EnvEntry, within days: Int, today: Date) -> String? {
        guard let typed = entry.expires else {
            guard Self.cannotProbe(key: key, entry: entry) else { return nil }
            return "\(key) has no API to check it and no typed expiry, so no reminder can fire; "
                + "type the date from the issuer's console into the kind file as expires"
        }
        guard let expiry = LedgerDay.date(typed) else {
            return "\(key) declares expires \"\(typed)\", which is not a yyyy-MM-dd day, so no reminder can fire"
        }
        let left = LedgerDay.days(from: today, to: expiry)
        if left < 0 {
            return "\(key) expired on \(typed), \(-left) day(s) ago; turn it over by its recipe"
        }
        guard left <= days else { return nil }
        return "\(key) expires on \(typed), in \(left) day(s); turn it over by its recipe before then"
    }

    /// Every reminder these targets owe, one line each, prefixed with the service.
    public static func reminders(for targets: [LedgerTarget], within days: Int, today: Date) -> [String] {
        var lines: [String] = []
        for target in targets {
            for entry in target.kind.secretRotations() {
                if let carried = target.carried, !carried.contains(entry.key) { continue }
                guard let declared = target.kind.environment[entry.key] else { continue }
                guard let text = Self.reminder(key: entry.key, entry: declared, within: days, today: today) else { continue }
                lines.append("\(target.stack)/\(target.service) \(text)")
            }
        }
        return lines
    }
}

// MARK: - Reading the estate

extension SecretLedger {
    /// One target per service with a kind file, across every manifest, with the keys its config and secrets files carry.
    /// Only key names leave the files. A missing file reads as empty, the same rule `rotate --all` keeps.
    public static func targets(in loaded: [(manifest: StackManifest, path: String)]) throws -> [LedgerTarget] {
        var targets: [LedgerTarget] = []
        for entry in loaded {
            let registry = KindRegistry(manifestPath: entry.path)
            for stack in entry.manifest.stacks {
                for service in stack.services {
                    guard let kind = try registry.kindFile(for: service.kind) else { continue }
                    let carried = Set(
                        try ConfigSync.readDeclared(
                            config: ConfigSync.configURL(for: service, in: stack, manifestPath: entry.path),
                            secrets: ConfigSync.secretsURL(for: service, in: stack, manifestPath: entry.path)
                        ).keys)
                    targets.append(
                        LedgerTarget(
                            stack: stack.name,
                            service: service.name,
                            kind: kind,
                            carried: carried))
                }
            }
        }
        return targets
    }
}

// MARK: - Printing

extension SecretLedger {
    /// The ledger as a table, one row per token, then the recipe of every key that is re-sealed rather than rotated.
    public static func lines(for rows: [LedgerRow]) -> [String] {
        let header = ["TOKEN", "ISSUER", "LIVE", "ISSUED", "EXPIRES", "NEXT"]
        let cells = rows.map { row in
            [
                "\(row.stack)/\(row.service) \(row.key)",
                row.issuer,
                row.liveness.rawValue,
                row.issued ?? "unknown, first seen \(row.firstSeen)",
                Self.expiryText(row.expiry, review: row.review),
                Self.nextText(row.next),
            ]
        }
        var widths = header.map(\.count)
        for line in cells {
            for (index, cell) in line.enumerated() where index < line.count - 1 {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func render(_ line: [String]) -> String {
            let padded = line.enumerated().map { index, cell in
                index == line.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            return "  " + padded.joined(separator: "  ")
        }

        var out = [render(header)]
        out += cells.map(render)
        for row in rows where row.next == .reseal {
            out.append("")
            out.append("  \(row.stack)/\(row.service) \(row.key) is re-sealed, not rotated. The recipe:")
            out.append("    \(row.recipe ?? "none declared")")
        }
        return out
    }

    static func expiryText(_ expiry: LedgerRow.Expiry, review: Bool) -> String {
        switch expiry {
        case .undeclared: return "-"
        case .notTyped: return "expiry not typed"
        case .unreadable(let text): return "unreadable: \(text)"
        case .on(let day): return review ? "review by \(day)" : day
        }
    }

    static func nextText(_ next: LedgerRow.Next) -> String {
        switch next {
        case .nothing: return "-"
        case .rotate: return "rotate"
        case .rotateByHand: return "rotate by hand, by the recipe"
        case .reseal: return "re-seal, not a rotation"
        case .heldFrom(let owner): return "the owner's row, \(owner)"
        case .declareRotation: return "rotate; declare a rotation first"
        }
    }
}

// MARK: - Publishing

/// The ledger as pulse keeps it and the coop draws it: one object per token with the same facts as the table, the
/// reminders owed inside the window, and the manifests it was read from. Names and dates, never a value.
public struct LedgerDocument: Codable, Sendable, Equatable {
    public var manifests: [String]
    public var rows: [Row]
    public var reminders: [String]

    /// One token, flattened for a page: the enums of ``LedgerRow`` as words, and the typed day beside its kind.
    public struct Row: Codable, Sendable, Equatable {
        public var stack: String
        public var service: String
        public var key: String
        public var issuer: String
        /// `live`, `dead`, `cannot probe`, or `not checked`.
        public var liveness: String
        public var issued: String?
        public var firstSeen: String
        /// The typed `yyyy-MM-dd` day, or `nil` when none is typed or the typed text is not a day.
        public var expires: String?
        /// `expiry not typed` or `unreadable: <text>` when `expires` is nil for a reason a page should say.
        public var expiryNote: String?
        /// Whether `expires` is a review date, so a page says "review by" and not "expires".
        public var review: Bool
        /// `nothing`, `rotate`, `rotateByHand`, `reseal`, `heldFrom`, or `declareRotation`.
        public var next: String
        /// The owner's `stack/service` when `next` is `heldFrom`.
        public var owner: String?
        public var listedForRotation: Bool
        public var recipe: String?

        public init(_ row: LedgerRow) {
            self.stack = row.stack
            self.service = row.service
            self.key = row.key
            self.issuer = row.issuer
            self.liveness = row.liveness.rawValue
            self.issued = row.issued
            self.firstSeen = row.firstSeen
            switch row.expiry {
            case .undeclared:
                self.expires = nil
                self.expiryNote = nil
            case .notTyped:
                self.expires = nil
                self.expiryNote = "expiry not typed"
            case .unreadable(let text):
                self.expires = nil
                self.expiryNote = "unreadable: \(text)"
            case .on(let day):
                self.expires = day
                self.expiryNote = nil
            }
            self.review = row.review
            switch row.next {
            case .nothing: self.next = "nothing"
            case .rotate: self.next = "rotate"
            case .rotateByHand: self.next = "rotateByHand"
            case .reseal: self.next = "reseal"
            case .heldFrom: self.next = "heldFrom"
            case .declareRotation: self.next = "declareRotation"
            }
            if case .heldFrom(let owner) = row.next { self.owner = owner } else { self.owner = nil }
            self.listedForRotation = row.listedForRotation
            self.recipe = row.recipe
        }
    }

    public init(manifests: [String], rows: [LedgerRow], reminders: [String]) {
        self.manifests = manifests
        self.rows = rows.map(Row.init)
        self.reminders = reminders
    }

    /// The document as JSON, sorted and pretty, so a person can read what pulse holds.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Where pulse keeps the ledger. The declaration's route sits beside it and both take the node key.
    public static let pulsePath = "/api/ledger"
}

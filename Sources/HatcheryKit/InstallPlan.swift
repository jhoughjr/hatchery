import Foundation

/// What a host should hold, read from its declaration, and what it holds, read from the host.
///
/// The declaration is the list: each declared job names the program it runs, and that program lives in a checkout,
/// is a built binary, or is a copy of a file from a checkout. The job's own plist or unit is the fourth thing. Nothing
/// is installed that no declaration names, and a host that declares nothing holds nothing hatchery minds.
/// Ruled on 2026-09-29, house#40: hatchery owns install, and the declaration is the list.
public enum InstallKind: Sendable, Equatable {
    /// A git checkout the program lives in, such as `~/repos/roost`, which should sit on its source's main.
    case checkout(name: String, root: String)
    /// A built binary, which records the sha it was built from beside itself as `<path>.sha`.
    case binary(tool: String, path: String, checkout: String)
    /// A file copied out of a checkout by one of its installers, such as the reconcile under `~/opt`.
    case copy(destination: String, source: String, installer: String)
    /// The supervisor's artifact for a declared job, rendered by hatchery.
    case job(label: String, file: String)
}

/// One installed thing on one host, and where it stands against what the declaration wants.
public struct InstallRow: Sendable, Equatable {
    public var host: String
    public var kind: InstallKind
    /// The sha or hash the host holds, or `nil` when the thing is not there.
    public var installed: String?
    /// The sha or hash the declaration wants, or `nil` when nothing could say.
    public var wanted: String?
    public var state: State

    public enum State: String, Sendable, Equatable {
        /// The host holds what the source's main holds.
        case level
        /// The host holds an older commit than the source's main.
        case behind
        /// The host holds commits the source's main lacks, so the source is what is behind; push it.
        case ahead
        /// The checkout has local changes, so no install touches it.
        case dirty
        /// The thing is not on the host.
        case missing
        /// The copy or the job file differs from what the checkout or the rendering holds.
        case differs
        /// Nothing could say: a binary with no sha beside it, or a source nothing could read.
        case unknown
    }

    /// The name a table shows, short enough for a column.
    public var name: String {
        switch self.kind {
        case .checkout(let name, _): return name
        case .binary(let tool, _, _): return tool
        case .copy(let destination, _, _): return (destination as NSString).lastPathComponent
        case .job(let label, _): return label
        }
    }

    public var kindWord: String {
        switch self.kind {
        case .checkout: return "checkout"
        case .binary: return "binary"
        case .copy: return "copy"
        case .job: return "job"
        }
    }

    /// Whether an install has something to do here.
    public var needsInstall: Bool {
        switch self.state {
        case .behind, .missing, .differs: return true
        case .level, .ahead, .dirty, .unknown: return false
        }
    }
}

/// The report of every host, as the table prints it and pulse keeps it.
public struct InstallReport: Codable, Sendable, Equatable {
    public var hosts: [Host]

    public struct Host: Codable, Sendable, Equatable {
        public var host: String
        public var rows: [Row]
    }

    public struct Row: Codable, Sendable, Equatable {
        public var name: String
        public var kind: String
        public var path: String
        public var installed: String?
        public var wanted: String?
        public var state: String
    }

    public init(rows: [InstallRow]) {
        var byHost: [String: [InstallRow]] = [:]
        var order: [String] = []
        for row in rows {
            if byHost[row.host] == nil { order.append(row.host) }
            byHost[row.host, default: []].append(row)
        }
        self.hosts = order.map { host in
            Host(
                host: host,
                rows: (byHost[host] ?? []).map { row in
                    Row(
                        name: row.name,
                        kind: row.kindWord,
                        path: InstallPlan.path(of: row.kind),
                        installed: row.installed,
                        wanted: row.wanted,
                        state: row.state.rawValue)
                })
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Where pulse keeps the report, beside the declaration.
    public static let pulsePath = "/api/install"
}

// MARK: - Reading the declaration

/// The things one host's declaration names, before any host is asked.
public struct InstallPlan: Sendable, Equatable {
    public var host: String
    public var platform: HostPlatform
    public var things: [InstallKind]
    /// The rendered job files by their destination under the home, which the host hashes beside its own copies.
    public var rendered: [String: String]
    /// The jobs that are kept alive, by label, with the program each runs. A job that runs for ever never reads a
    /// pulled checkout on its own, so an install restarts it when its checkout moves.
    public var longRunning: [String: String]
    /// How the supervisor comes to run each job file's job, by the file's destination. An install starts a timer and
    /// a kept-alive job, and never a job that only another unit asks for.
    public var starts: [String: JobSpec.Start]

    public init(
        host: String, platform: HostPlatform, things: [InstallKind], rendered: [String: String],
        longRunning: [String: String] = [:], starts: [String: JobSpec.Start] = [:]
    ) {
        self.host = host
        self.platform = platform
        self.things = things
        self.rendered = rendered
        self.longRunning = longRunning
        self.starts = starts
    }

    /// The remote lines that restart every kept-alive job whose program lives in this checkout.
    public func restartSteps(afterCheckout root: String) -> [(label: String, step: String)] {
        self.longRunning.filter { $0.value.hasPrefix(root + "/") }.sorted { $0.key < $1.key }.map { label, _ in
            switch self.platform {
            case .darwin: return (label, "launchctl kickstart -k gui/$(id -u)/\(label)")
            case .linux: return (label, "systemctl --user restart \(label).service")
            }
        }
    }

    /// The tools a checkout is recognised by when it sits directly under the home, as `~/roost` does on the opi.
    public static let homeCheckouts: Set<String> = ["roost", "hatchery", "house", "statusgen"]

    /// The programs that run a script named next, so the script is the thing and not the interpreter.
    static let interpreters: Set<String> = ["python3", "python", "node", "sh", "bash", "env"]

    /// Where the forge keeps a tool, for the sha the host should hold.
    public static func forgeURL(of name: String) -> String {
        "https://forgejo.jimmyhoughjr.net/jimmy/\(name).git"
    }

    /// One plan per host stack, from every manifest.
    /// A stack with no host or a dokku backend declares no installed thing; its containers are tofu's.
    public static func plans(in loaded: [(manifest: StackManifest, path: String)]) throws -> [InstallPlan] {
        var plans: [InstallPlan] = []
        for entry in loaded {
            for stack in entry.manifest.stacks where stack.backend == .host {
                guard let host = stack.host, !host.isEmpty else { continue }
                var things: [InstallKind] = []
                var rendered: [String: String] = [:]
                var longRunning: [String: String] = [:]
                var starts: [String: JobSpec.Start] = [:]
                let platform = stack.platform
                let roost = Self.roostRoot(in: stack, platform: platform)
                for service in stack.services {
                    guard let job = service.job else { continue }
                    if let program = Self.program(of: job) {
                        for thing in Self.classify(program, platform: platform, roost: roost) where !things.contains(thing) {
                            things.append(thing)
                        }
                    }
                    let label = HostProvider.jobLabel(for: service, platform: platform)
                    if job.keepAlive, let program = Self.program(of: job) { longRunning[label] = Self.homed(program) }
                    // A job that reads its secrets from vault at start carries none in its file, so its rendering
                    // takes the config alone. On 2026-09-30 the serve job's rendering held its token for want of this.
                    let environment = try ConfigSync.readDeclared(
                        config: ConfigSync.configURL(for: service, in: stack, manifestPath: entry.path),
                        secrets: job.environmentFromVault ? nil : ConfigSync.secretsURL(for: service, in: stack, manifestPath: entry.path))
                    let files = try HostProvider.jobFiles(for: service, platform: platform, environment: environment)
                    // Every file of the job is a row: a scheduled job on Linux is a unit and its timer, and a timer
                    // nobody compared is a schedule nobody checked.
                    for (index, destination) in HostProvider.jobDestinations(for: service, platform: platform).enumerated()
                    where index < files.count {
                        rendered[destination] = files[index].contents
                        starts[destination] = job.start
                        things.append(.job(label: index == 0 ? label : (destination as NSString).lastPathComponent, file: destination))
                    }
                }
                plans.append(InstallPlan(host: host, platform: platform, things: things, rendered: rendered, longRunning: longRunning, starts: starts))
            }
        }
        return plans
    }

    /// The path the job runs: its program, or the script an interpreter is given.
    static func program(of job: JobSpec) -> String? {
        guard let first = job.program.first else { return nil }
        if Self.interpreters.contains((first as NSString).lastPathComponent), job.program.count > 1 {
            let next = job.program[1]
            return next.hasPrefix("-") ? nil : next
        }
        return first
    }

    /// The roost checkout on this host, which is where a copy under `~/opt` came from.
    static func roostRoot(in stack: StackSpec, platform: HostPlatform) -> String {
        for service in stack.services {
            guard let job = service.job, let program = Self.program(of: job) else { continue }
            if case .checkout(let name, let root)? = Self.checkout(in: Self.homed(program)), name == "roost" {
                return root
            }
        }
        return platform == .darwin ? "$HOME/repos/roost" : "$HOME/roost"
    }

    /// The path with the home spelled as `$HOME`, which the host's shell expands and this machine never does.
    static func homed(_ path: String) -> String {
        if path.hasPrefix("%h/") { return "$HOME/" + path.dropFirst(3) }
        if path.hasPrefix("~/") { return "$HOME/" + path.dropFirst(2) }
        return path
    }

    /// The things one program path names: its checkout, its binary, or its copy.
    /// The job's own file is added by the caller, because every job has one whatever it runs.
    static func classify(_ program: String, platform: HostPlatform, roost: String) -> [InstallKind] {
        let path = Self.homed(program)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let index = parts.firstIndex(of: ".local"), index + 2 < parts.count, parts[index + 1] == "bin",
            parts[index + 2] == "hatchery"
        {
            let home = parts[..<index].joined(separator: "/")
            let checkout = home + "/repos/hatchery"
            return [
                .checkout(name: "hatchery", root: checkout),
                .binary(tool: "hatchery", path: path, checkout: checkout),
            ]
        }
        if let checkout = Self.checkout(in: path) { return [checkout] }
        // A copy lives under the account's own `opt`, and `/opt/homebrew` is nobody's copy of anything.
        if let index = parts.firstIndex(of: "opt"), index + 2 < parts.count, index >= 1,
            parts[index - 1] == "$HOME" || (index >= 2 && ["home", "Users"].contains(parts[index - 2]))
        {
            let file = parts[index + 2]
            let stem = file.hasSuffix(".sh") ? String(file.dropLast(3)) : file
            return [
                .checkout(name: "roost", root: roost),
                .copy(destination: path, source: "\(roost)/bin/\(file)", installer: "\(roost)/bin/install-\(stem).sh"),
            ]
        }
        return []
    }

    /// The checkout a path sits in: `<home>/repos/<name>/...`, or `<home>/<name>/...` for a tool the estate keeps
    /// directly under a home.
    static func checkout(in path: String) -> InstallKind? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let index = parts.firstIndex(of: "repos"), index + 1 < parts.count, index + 2 < parts.count {
            let name = parts[index + 1]
            return .checkout(name: name, root: parts[...(index + 1)].joined(separator: "/"))
        }
        for (index, part) in parts.enumerated() where Self.homeCheckouts.contains(part) && index + 1 < parts.count {
            guard index >= 1, parts[index - 1] == "$HOME" || parts[index - 1] == "jimmy" || parts[index - 1] == "jimmyhoughjr"
            else { continue }
            return .checkout(name: part, root: parts[...index].joined(separator: "/"))
        }
        return nil
    }

    /// The path a row is about.
    public static func path(of kind: InstallKind) -> String {
        switch kind {
        case .checkout(_, let root): return root
        case .binary(_, let path, _): return path
        case .copy(let destination, _, _): return destination
        case .job(_, let file): return "$HOME/" + file
        }
    }
}

// MARK: - Reading the host

extension InstallPlan {
    /// The one script that reads every fact on the host, so a host is asked once.
    ///
    /// Each line is `kind<TAB>path<TAB>fact...`. A hash is the first twelve characters of a sha256, enough to tell two
    /// files apart and short enough for a column. The rendered job file travels as base64 and is hashed on the host,
    /// so this machine needs no hash of its own and the two hashes come from one tool.
    public func script(forgeMain: [String: String?] = [:]) -> String {
        // A job file is compared in its canonical form, because the executor writes tabs where the renderer writes
        // spaces, and a unit's comments say nothing to systemd. `c` reads a file or, as `-`, standard input.
        let canonical = self.platform == .darwin
            ? "c() { plutil -convert xml1 -o - \"$1\" 2>/dev/null; }"
            : "c() { sed -e 's/^[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \"$1\"; }"
        var lines = [
            "h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-12; }",
            "f() { if [ -f \"$1\" ]; then h < \"$1\"; else echo missing; fi; }",
            canonical,
            "j() { if [ -f \"$1\" ]; then c \"$1\" | h; else echo missing; fi; }",
        ]
        for thing in self.things {
            switch thing {
            case .checkout(let name, let root):
                lines.append(
                    "if [ -d \"\(root)/.git\" ]; then printf 'checkout\\t%s\\t%s\\t%s\\t%s\\n' '\(root)' "
                        + "\"$(git -C \"\(root)\" rev-parse HEAD 2>/dev/null)\" "
                        + "\"$(git -C \"\(root)\" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')\" "
                        + "\"$(git -C \"\(root)\" ls-remote --heads origin main 2>/dev/null | cut -c1-40)\"; "
                        + "else printf 'checkout\\t%s\\tmissing\\t0\\t\\n' '\(root)'; fi")
                // Whether the source's main is already in what the host holds, which tells behind from ahead.
                if let sha = forgeMain[name].flatMap({ $0 }) {
                    lines.append(
                        "printf 'ahead\\t%s\\t%s\\n' '\(root)' "
                            + "\"$(git -C \"\(root)\" merge-base --is-ancestor \(sha) HEAD 2>/dev/null && echo yes || echo no)\"")
                }

            case .binary(_, let path, _):
                lines.append(
                    "if [ -x \"\(path)\" ]; then printf 'binary\\t%s\\t%s\\n' '\(path)' "
                        + "\"$(cat \"\(path).sha\" 2>/dev/null || echo unknown)\"; "
                        + "else printf 'binary\\t%s\\tmissing\\n' '\(path)'; fi")

            case .copy(let destination, let source, _):
                lines.append(
                    "printf 'copy\\t%s\\t%s\\t%s\\n' '\(destination)' \"$(f \"\(destination)\")\" \"$(f \"\(source)\")\"")

            case .job(_, let file):
                let encoded = Data((self.rendered[file] ?? "").utf8).base64EncodedString()
                lines.append(
                    "printf 'job\\t%s\\t%s\\t%s\\n' '\(file)' \"$(j \"$HOME/\(file)\")\" "
                        + "\"$(printf %s '\(encoded)' | base64 --decode | c - | h)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The rows for this host, from what the script printed and what the forge said each checkout's main is.
    /// `forgeMain` is keyed by tool name and holds `nil` for a tool the forge does not keep, where the host's own
    /// origin is the source instead.
    public func rows(from output: String, forgeMain: [String: String?]) -> [InstallRow] {
        var facts: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count >= 3 else { continue }
            facts[cells[0] + " " + cells[1]] = Array(cells[2...])
        }
        var checkoutState: [String: InstallRow.State] = [:]
        var rows: [InstallRow] = []
        for thing in self.things {
            var row = InstallRow(host: self.host, kind: thing, installed: nil, wanted: nil, state: .unknown)
            switch thing {
            case .checkout(let name, let root):
                let fact = facts["checkout " + root] ?? []
                let head = fact.first ?? ""
                let dirty = (fact.count > 1 ? Int(fact[1]) : 0) ?? 0
                let origin = fact.count > 2 ? fact[2] : ""
                let wanted = forgeMain[name].flatMap { $0 } ?? (origin.isEmpty ? nil : origin)
                row.installed = head == "missing" || head.isEmpty ? nil : String(head.prefix(7))
                row.wanted = wanted.map { String($0.prefix(7)) }
                if head == "missing" || head.isEmpty {
                    row.state = .missing
                } else if dirty > 0 {
                    row.state = .dirty
                } else if let wanted {
                    let holdsMain = (facts["ahead " + root] ?? []).first == "yes"
                    row.state = wanted == head ? .level : (holdsMain ? .ahead : .behind)
                } else {
                    row.state = .unknown
                }
                checkoutState[root] = row.state

            case .binary(let tool, let path, let checkout):
                let fact = facts["binary " + path] ?? []
                let sha = fact.first ?? ""
                row.installed = sha == "missing" || sha == "unknown" || sha.isEmpty ? nil : String(sha.prefix(7))
                let wanted = forgeMain[tool].flatMap { $0 }
                row.wanted = wanted.map { String($0.prefix(7)) }
                if sha == "missing" || sha.isEmpty {
                    row.state = .missing
                } else if sha == "unknown" {
                    row.state = .unknown
                } else if let wanted {
                    row.state = wanted.hasPrefix(sha) || sha.hasPrefix(String(wanted.prefix(7))) ? .level : .behind
                } else {
                    row.state = .unknown
                }
                // A binary is built from its checkout, so a checkout that is not level is the first thing to fix.
                if row.state == .behind, checkoutState[checkout] == .dirty { row.state = .dirty }

            case .copy(let destination, _, _):
                let fact = facts["copy " + destination] ?? []
                let installed = fact.first ?? "missing"
                let source = fact.count > 1 ? fact[1] : "missing"
                row.installed = installed == "missing" ? nil : installed
                row.wanted = source == "missing" ? nil : source
                if installed == "missing" {
                    row.state = .missing
                } else if source == "missing" {
                    row.state = .unknown
                } else {
                    row.state = installed == source ? .level : .differs
                }

            case .job(_, let file):
                let fact = facts["job " + file] ?? []
                let installed = fact.first ?? "missing"
                let wanted = fact.count > 1 ? fact[1] : ""
                row.installed = installed == "missing" ? nil : installed
                row.wanted = wanted.isEmpty ? nil : wanted
                if installed == "missing" {
                    row.state = .missing
                } else if wanted.isEmpty {
                    row.state = .unknown
                } else {
                    row.state = installed == wanted ? .level : .differs
                }
            }
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Installing

extension InstallPlan {
    /// The remote shell lines that bring one row level, in the order they must run. An empty answer means the row
    /// needs nothing, or nothing an install can do: a dirty checkout is a person's, and an unknown row is read first.
    public func steps(for row: InstallRow, forgeMain: [String: String?]) -> [String] {
        guard row.needsInstall else { return [] }
        switch row.kind {
        case .checkout(let name, let root):
            // A fetch from the forge by URL, so a clone whose origin is GitHub still lands on the forge's main.
            // A merge that is not a fast-forward fails, and that failure is the report.
            if row.state == .missing { return [] }
            if forgeMain[name].flatMap({ $0 }) != nil {
                return ["git -C \"\(root)\" fetch -q \(Self.forgeURL(of: name)) main && git -C \"\(root)\" merge -q --ff-only FETCH_HEAD"]
            }
            return ["git -C \"\(root)\" pull -q --ff-only"]

        case .binary(_, _, let checkout):
            // The checkout's own row runs before this one, so the build reads the forge's main.
            return ["cd \"\(checkout)\" && bin/install >/dev/null"]

        case .copy(let destination, let source, let installer):
            // The tool's own installer when it has one, since it places the libraries and reloads the supervisor too.
            return [
                "if [ -x \"\(installer)\" ]; then \"\(installer)\" >/dev/null; "
                    + "else mkdir -p \"$(dirname \"\(destination)\")\" && install -m 755 \"\(source)\" \"\(destination)\"; fi"
            ]

        case .job(_, let file):
            guard let contents = self.rendered[file] else { return [] }
            let encoded = Data(contents.utf8).base64EncodedString()
            let label = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            var lines = [
                "mkdir -p \"$HOME/\((file as NSString).deletingLastPathComponent)\" && printf %s '\(encoded)' | base64 --decode > \"$HOME/\(file)\""
            ]
            switch self.platform {
            case .darwin:
                lines.append("launchctl bootout gui/$(id -u)/\(label) >/dev/null 2>&1 || true")
                lines.append("launchctl bootstrap gui/$(id -u) \"$HOME/\(file)\"")
            case .linux:
                let unit = (file as NSString).lastPathComponent
                lines.append("systemctl --user daemon-reload")
                // The timer is what starts a scheduled job, a kept-alive or run-at-load job starts itself, and a job
                // another unit asks for is only read again: starting the reconcile's alert would send the alert.
                if file.hasSuffix(".timer") {
                    lines.append("systemctl --user enable --now \(unit)")
                } else {
                    switch self.starts[file] ?? .keep {
                    case .keep:
                        lines.append("systemctl --user enable \(unit)")
                        lines.append("systemctl --user restart \(unit)")
                    case .load:
                        lines.append("systemctl --user enable --now \(unit)")
                    case .timer, .demand:
                        break
                    }
                }
            }
            return lines
        }
    }

    /// The command that runs a script on this plan's host: ssh for a box, `sh` for this machine.
    public func command(_ script: String) -> [String] {
        if InstallPlan.isLocal(self.host) { return ["sh", "-c", script] }
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", self.host, script]
    }

    /// The probe that says the host answers before anything is read or written.
    public func probe() -> [String]? {
        if InstallPlan.isLocal(self.host) { return nil }
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", self.host, "true"]
    }

    static func isLocal(_ host: String) -> Bool {
        ["local", "localhost", "127.0.0.1"].contains(host.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The tools the plans name, for one forge read each.
    public static func tools(in plans: [InstallPlan]) -> [String] {
        var names: [String] = []
        for plan in plans {
            for thing in plan.things {
                switch thing {
                case .checkout(let name, _), .binary(let name, _, _):
                    if !names.contains(name) { names.append(name) }
                case .copy, .job:
                    break
                }
            }
        }
        return names
    }

    /// The forge's main for one tool, or `nil` when the forge does not keep it.
    /// Read from this machine, so the sha is the forge's whatever a host's origin points at.
    public static func forgeMain(of tool: String, execute: CommandExecutor) async -> String? {
        let output = try? await execute(["git", "ls-remote", "--heads", Self.forgeURL(of: tool), "main"], nil)
        guard let output, output.status == 0 else { return nil }
        let sha = output.standardOutput.split(separator: "\t").first.map(String.init) ?? ""
        return sha.count == 40 ? sha : nil
    }
}

// MARK: - Printing

extension InstallReport {
    /// The report as a table, one row per thing, grouped by host.
    public static func lines(for rows: [InstallRow]) -> [String] {
        var out: [String] = []
        var lastHost = ""
        let header = ["THING", "KIND", "INSTALLED", "WANTED", "STATE"]
        let cells = rows.map { row in
            [row.name, row.kindWord, row.installed ?? "-", row.wanted ?? "-", row.state.rawValue]
        }
        var widths = header.map(\.count)
        for line in cells {
            for (index, cell) in line.enumerated() { widths[index] = max(widths[index], cell.count) }
        }
        func render(_ line: [String]) -> String {
            "    " + line.enumerated().map { index, cell in
                cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        for (index, row) in rows.enumerated() {
            if row.host != lastHost {
                if !lastHost.isEmpty { out.append("") }
                out.append("  \(row.host)")
                out.append(render(header))
                lastHost = row.host
            }
            out.append(render(cells[index]))
        }
        return out
    }
}

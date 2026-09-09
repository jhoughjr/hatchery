import Foundation

// MARK: - What a rotation did

/// One thing a rotation did, in the order it did it.
///
/// - `issue`: the issuer answered with a new value.
/// - `record`: the new values reached the service's secrets file, before any holder was told.
/// - `hold`: a holder took the value.
/// - `restart`: a holder was restarted so it reads the value.
public struct RotationStep: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case issue, record, hold, restart
    }

    public var phase: Phase
    public var what: String

    public init(phase: Phase, what: String) {
        self.phase = phase
        self.what = what
    }
}

/// Everything a rotation did, and where it stopped.
///
/// A rotation that stops halfway has already turned a value over, so the report is the only thing standing
/// between a person and a service nobody can reach. It names every step that ran, so the rest is finished by hand.
public struct RotationReport: Sendable, Equatable {
    public var keys: [String]
    public var done: [RotationStep]
    /// The step that failed, or `nil` when the whole plan ran.
    public var stopped: RotationStep?
    public var reason: String?

    public init(
        keys: [String], done: [RotationStep] = [], stopped: RotationStep? = nil, reason: String? = nil
    ) {
        self.keys = keys
        self.done = done
        self.stopped = stopped
        self.reason = reason
    }

    public var succeeded: Bool { self.stopped == nil }

    /// The report as printed. A stop names what ran and what did not, in that order.
    public func lines() -> [String] {
        var lines = ["  \(self.keys.joined(separator: " + "))"]
        for step in self.done {
            lines.append("    done     \(step.phase.rawValue): \(step.what)")
        }
        guard let stopped = self.stopped else {
            lines.append("    finished. Seal the state so the new values are backed up.")
            return lines
        }
        lines.append("    FAILED   \(stopped.phase.rawValue): \(stopped.what)")
        lines.append("             \(self.reason ?? "no reason given")")
        lines.append("    The steps above ran. Finish the rest by hand, then seal the state.")
        return lines
    }
}

/// The service's own `<service>.secrets.json`, read and written by the executor.
///
/// It is a pair of closures rather than a path, so a test drives a rotation without a file and a caller on a
/// box drives one against the real sidecar.
public struct SecretsFile: Sendable {
    public var read: @Sendable () throws -> [String: String]
    public var write: @Sendable ([String: String]) throws -> Void

    public init(
        read: @escaping @Sendable () throws -> [String: String],
        write: @escaping @Sendable ([String: String]) throws -> Void
    ) {
        self.read = read
        self.write = write
    }

    /// The file on disk, read through `ConfigSync` and written the same way `config split` writes it.
    public static func onDisk(at url: URL) -> SecretsFile {
        SecretsFile(
            read: { (try? ConfigSync.readDeclared(at: url)) ?? [:] },
            write: { values in try ConfigSync.encoded(values).write(to: url, options: .atomic) })
    }
}

// MARK: - Running a rotation

/// Executes a rotation plan in the ruled order: the issuer, then the record, then every holder, then every restart.
///
/// The record between the issuer and the holders is not bookkeeping. Vault answers a minted value once, and a
/// postgres password exists nowhere but in the `ALTER ROLE` that set it, so a crash after the issuer and before
/// the file write is a value that is live and lost at the same time. Writing it first turns that into a value
/// that is on disk and not yet distributed, which a person can finish by hand.
///
/// The run stops at the first failure and reports what ran. It never rolls back: the issuer already invalidated
/// the old value, so going backwards is not a thing that exists.
public struct RotationExecutor: Sendable {
    private let run: CommandRunner
    private let vault: VaultAdmin
    private let mint: @Sendable (Int) -> String
    private let secrets: SecretsFile
    /// App name to the ssh target its dokku commands arrive at.
    private let dokkuTargets: [String: String]
    /// Postgres server name to the shell account that can `docker exec` its container.
    private let adminTargets: [String: String]

    public init(
        vault: VaultAdmin,
        secrets: SecretsFile,
        dokkuTargets: [String: String] = [:],
        adminTargets: [String: String] = [:],
        run: @escaping CommandRunner = ShellRunner.live,
        mint: @escaping @Sendable (Int) -> String = { SecretMinter().token(bytes: $0) }
    ) {
        self.vault = vault
        self.secrets = secrets
        self.dokkuTargets = dokkuTargets
        self.adminTargets = adminTargets
        self.run = run
        self.mint = mint
    }

    /// Runs one plan and reports what it did.
    public func execute(_ plan: RotationPlan) async -> RotationReport {
        var report = RotationReport(keys: plan.keys)

        let values: [String: String]
        do {
            values = try await self.issue(plan)
            report.done.append(
                RotationStep(
                    phase: .issue, what: plan.rotation.issuer.label(service: plan.service)))
        } catch {
            report.stopped = RotationStep(
                phase: .issue, what: plan.rotation.issuer.label(service: plan.service))
            report.reason = "\(error)"
            return report
        }

        // Before any holder. A value that is issued and not written down is a value nobody can read again.
        do {
            var file = try self.secrets.read()
            for (key, value) in values { file[key] = value }
            try self.secrets.write(file)
            report.done.append(
                RotationStep(
                    phase: .record,
                    what: "\(values.keys.sorted().joined(separator: " + ")) written to the secrets file"))
        } catch {
            report.stopped = RotationStep(phase: .record, what: "the secrets file")
            report.reason = "\(error)"
            return report
        }

        for holder in plan.rotation.holders {
            let step = RotationStep(phase: .hold, what: holder.label)
            do {
                for command in try Self.writeCommands(
                    holder, plan: plan, values: values, dokkuTargets: self.dokkuTargets)
                {
                    _ = try await self.run(command)
                }
                report.done.append(step)
            } catch {
                report.stopped = step
                report.reason = "\(error)"
                return report
            }
        }

        for holder in plan.restarting {
            let step = RotationStep(phase: .restart, what: holder.restartLabel)
            do {
                for command in try Self.restartCommands(holder, dokkuTargets: self.dokkuTargets) {
                    _ = try await self.run(command)
                }
                report.done.append(step)
            } catch {
                report.stopped = step
                report.reason = "\(error)"
                return report
            }
        }
        return report
    }

    // MARK: - The issuers

    /// The new value for every key of the plan, from whatever issues it.
    private func issue(_ plan: RotationPlan) async throws -> [String: String] {
        switch plan.rotation.issuer {
        case .vaultAppKey:
            return [try plan.singleKey(): try await self.vault.rotateAppKey(app: plan.service)]

        case .vaultS3Key(let app):
            let pair = try await self.vault.rotateS3Key(app: app)
            return try Self.s3Values(pair, keys: plan.keys)

        case .vaultSecret(let app, let name):
            let value = self.mint(32)
            try await self.vault.setSecret(app: app, name: name, value: value)
            return [try plan.singleKey(): value]

        case .postgresRole(let server, let role):
            let password = self.mint(32)
            _ = try await self.run(
                Self.alterRoleCommand(
                    server: server, role: role, password: password,
                    on: self.adminTargets[server] ?? server))
            return try self.rewrittenURLs(plan, password: password)

        case .random(let bytes):
            return [try plan.singleKey(): self.mint(bytes)]

        case .manual(let recipe):
            throw RotationRefusal.manualIssuer(keys: plan.keys, recipe: recipe)
        }
    }

    /// The plan's keys with the new password put back into the connection URL each one holds.
    ///
    /// A role's password is a part of the URL and not the whole value, so the host, the port and the database
    /// have to survive the rotation untouched. The old URL comes from the secrets file, because that is where
    /// `config split` put it.
    private func rewrittenURLs(_ plan: RotationPlan, password: String) throws -> [String: String] {
        let file = try self.secrets.read()
        var values: [String: String] = [:]
        for key in plan.keys {
            guard let old = file[key], !old.isEmpty else {
                throw RotationExecutorError.noCurrentValue(key: key)
            }
            guard let rewritten = Self.replacingPassword(in: old, with: password) else {
                throw RotationExecutorError.notAConnectionURL(key: key)
            }
            values[key] = rewritten
        }
        return values
    }

    /// Which half of a minted S3 key goes to which of the two declared keys.
    ///
    /// The name says it: the key whose name carries `SECRET` takes the secret half. Position would not,
    /// because a kind file sorts its keys and nothing makes that order the pair's order.
    static func s3Values(
        _ pair: (accessKeyID: String, secretAccessKey: String), keys: [String]
    ) throws -> [String: String] {
        guard keys.count == 2 else { throw RotationExecutorError.notAPair(keys: keys) }
        let secretKeys = keys.filter { $0.uppercased().contains("SECRET") }
        guard secretKeys.count == 1, let identifierKey = keys.first(where: { $0 != secretKeys[0] })
        else {
            throw RotationExecutorError.notAPair(keys: keys)
        }
        return [identifierKey: pair.accessKeyID, secretKeys[0]: pair.secretAccessKey]
    }

    /// `ALTER ROLE` over the same `docker exec` channel `db provision` uses.
    ///
    /// The SQL travels through two shells when the box is another machine, so it is quoted for the remote one
    /// and left bare when there is no second shell to parse it.
    static func alterRoleCommand(
        server: String, role: String, password: String, on target: String
    ) -> [String] {
        let sql = "ALTER ROLE \"\(role)\" WITH LOGIN PASSWORD '\(password)'"
        let prefix = AdminChannel.prefix(target)
        return prefix
            + ["docker", "exec", server, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-Atc"]
            + [prefix.isEmpty ? sql : DatabaseProvisioner.shellQuoted(sql)]
    }

    /// The same connection URL with a new password.
    ///
    /// A URL with no password is answered as `nil`, because guessing where a password belongs would produce a
    /// string that connects to nothing. The minted password is base64url, so nothing in it needs escaping.
    static func replacingPassword(in url: String, with password: String) -> String? {
        guard let scheme = url.range(of: "://") else { return nil }
        let rest = url[scheme.upperBound...]
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let credentials = rest[rest.startIndex..<at]
        guard let colon = credentials.firstIndex(of: ":") else { return nil }
        let user = credentials[credentials.startIndex..<colon]
        return String(url[url.startIndex..<scheme.upperBound]) + user + ":" + password + String(rest[at...])
    }

    // MARK: - The holders

    /// What a holder must run to take the new value. Empty for a holder that reads it from vault itself.
    static func writeCommands(
        _ holder: KindFile.Holder,
        plan: RotationPlan,
        values: [String: String],
        dokkuTargets: [String: String]
    ) throws -> [[String]] {
        switch holder {
        case .dokkuConfig(let app, let key, let restart):
            let value = try Self.value(for: key, plan: plan, values: values)
            let target = try Self.dokkuTarget(app, in: dokkuTargets)
            let flags = restart == .stopStart ? ["--no-restart"] : []
            return [[
                "ssh", "-o", "BatchMode=yes", target, "config:set",
            ] + flags + [app, "\(key)=\(value)"]]

        case .roostrc(let host, let key):
            let value = try Self.value(for: key, plan: plan, values: values)
            return [Self.onHost(host, script: Self.roostrcScript(key: key, value: value))]

        case .launchdEnvironment(let host, let label, let key):
            let value = try Self.value(for: key, plan: plan, values: values)
            return [Self.onHost(host, script: Self.plistScript(label: label, key: key, value: value))]

        case .systemdEnvironment(let host, let unit, let key):
            let value = try Self.value(for: key, plan: plan, values: values)
            return [Self.onHost(host, script: Self.dropInScript(unit: unit, key: key, value: value))]

        case .vaultSecret:
            // Vault already holds the value, and this holder reads it at boot. Its restart is the whole step.
            return []
        }
    }

    /// What a holder must run to read the new value, after every holder has taken it.
    static func restartCommands(
        _ holder: KindFile.Holder, dokkuTargets: [String: String]
    ) throws -> [[String]] {
        switch holder {
        case .dokkuConfig(let app, _, let restart):
            // A rolling deploy is the config change's own doing, so it is a step of the plan and not a command.
            guard restart == .stopStart else { return [] }
            let target = try Self.dokkuTarget(app, in: dokkuTargets)
            return [
                ["ssh", "-o", "BatchMode=yes", target, "ps:stop", app],
                ["ssh", "-o", "BatchMode=yes", target, "ps:start", app],
            ]

        case .roostrc:
            return []

        case .launchdEnvironment(let host, let label, _):
            return [Self.onHost(host, script: Self.bootstrapScript(label: label))]

        case .systemdEnvironment(let host, let unit, _):
            return [Self.onHost(host, script: "systemctl --user restart \(unit)")]

        case .vaultSecret(let app, _):
            // The app reads the value from vault at boot, so it needs a restart and no write. hatchery restarts
            // it where it knows how, which is dokku. An app it does not know is named in the report instead.
            guard let target = dokkuTargets[app] else {
                throw RotationExecutorError.unknownRestart(app: app)
            }
            return [["ssh", "-o", "BatchMode=yes", target, "ps:restart", app]]
        }
    }

    /// The value a holder takes: its own key's when the plan issued that key, and the plan's one value otherwise.
    ///
    /// A holder may name the value differently from the service that issues it. `ROOST_HATCHERY_TOKEN` on a box
    /// is the same value as `HATCHERY_SERVE_TOKEN` in vault, and the declaration is what says so.
    static func value(for key: String, plan: RotationPlan, values: [String: String]) throws -> String {
        if let own = values[key] { return own }
        guard values.count == 1, let only = values.values.first else {
            throw RotationExecutorError.ambiguousValue(key: key, keys: plan.keys)
        }
        return only
    }

    static func dokkuTarget(_ app: String, in targets: [String: String]) throws -> String {
        guard let target = targets[app] else { throw RotationExecutorError.noBox(app: app) }
        return target
    }

    /// A shell script on a box, or on this machine when the box is this one.
    static func onHost(_ host: String, script: String) -> [String] {
        let prefix = AdminChannel.prefix(host)
        return prefix + ["sh", "-c", prefix.isEmpty ? script : DatabaseProvisioner.shellQuoted(script)]
    }

    /// Replaces a key in `~/.roostrc`, keeping every other line.
    ///
    /// The file is rewritten beside itself and moved into place, so a failure halfway leaves the old file whole
    /// rather than a truncated one.
    static func roostrcScript(key: String, value: String) -> String {
        "f=$HOME/.roostrc; touch \"$f\"; grep -v '^\(key)=' \"$f\" > \"$f.rotating\"; "
            + "printf '\(key)=%s\\n' '\(value)' >> \"$f.rotating\"; mv \"$f.rotating\" \"$f\""
    }

    /// Sets a key in a launchd plist's `EnvironmentVariables`, adding it when the plist carries none.
    static func plistScript(label: String, key: String, value: String) -> String {
        let plist = "$HOME/Library/LaunchAgents/\(label).plist"
        return "/usr/libexec/PlistBuddy -c 'Set :EnvironmentVariables:\(key) \(value)' \"\(plist)\" "
            + "|| /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:\(key) string \(value)' \"\(plist)\""
    }

    /// Bootstraps a launchd agent again, the same two lines the job installer writes.
    static func bootstrapScript(label: String) -> String {
        "launchctl bootout gui/$(id -u)/\(label) >/dev/null 2>&1 || true; "
            + "launchctl bootstrap gui/$(id -u) \"$HOME/Library/LaunchAgents/\(label).plist\""
    }

    /// Sets a key in a systemd user unit's environment, through a drop-in of hatchery's own.
    ///
    /// A drop-in rather than the unit file, so a rotation never rewrites the artifact the job installer owns.
    static func dropInScript(unit: String, key: String, value: String) -> String {
        let directory = "$HOME/.config/systemd/user/\(unit).d"
        return "mkdir -p \(directory) && "
            + "printf '[Service]\\nEnvironment=\"\(key)=%s\"\\n' '\(value)' > \(directory)/rotation.conf && "
            + "systemctl --user daemon-reload"
    }
}

/// The way an executor cannot run a plan the planner allowed.
///
/// - `noBox`: a dokku holder's app is declared, and no stack says which box it runs on.
/// - `unknownRestart`: a vault-reading holder names an app hatchery has no way to restart.
/// - `noCurrentValue`: a URL rewrite needs the old URL, and the secrets file holds none.
/// - `notAConnectionURL`: the key holds something with no password in it to replace.
/// - `notAPair`: an S3 rotation must name exactly two keys, one of them a secret.
/// - `notASingleKey`: this issuer answers one value, and the plan holds more than one key.
/// - `ambiguousValue`: a holder renames the value, and the plan issued more than one.
public enum RotationExecutorError: Error, CustomStringConvertible, Equatable {
    case noBox(app: String)
    case unknownRestart(app: String)
    case noCurrentValue(key: String)
    case notAConnectionURL(key: String)
    case notAPair(keys: [String])
    case notASingleKey(keys: [String])
    case ambiguousValue(key: String, keys: [String])

    public var description: String {
        switch self {
        case .noBox(let app):
            return "no stack says which box \(app) runs on, so its config cannot be set"

        case .unknownRestart(let app):
            return "\(app) reads this value from vault at boot, and hatchery has no way to restart it; "
                + "restart it where it runs"

        case .noCurrentValue(let key):
            return "the secrets file holds no \(key), and the new password goes inside the old URL"

        case .notAConnectionURL(let key):
            return "\(key) is not a connection URL with a password in it"

        case .notAPair(let keys):
            return "an S3 rotation replaces two keys, one of them named SECRET; this one names "
                + keys.joined(separator: " + ")

        case .notASingleKey(let keys):
            return "this issuer answers one value, and the declaration gives it "
                + keys.joined(separator: " + ")

        case .ambiguousValue(let key, let keys):
            return "the holder names \(key), which the issuer did not answer for, and the plan issued "
                + "\(keys.count) values, so there is no one value to give it"
        }
    }
}

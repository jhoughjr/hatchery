import Foundation

// MARK: - What a rotation did

/// One thing a rotation did, in the order it did it.
///
/// - `ready`: a re-seal's own checks passed before anything was minted.
/// - `issue`: the issuer answered with a new value.
/// - `record`: the new values reached the service's secrets file, before any holder was told.
/// - `hold`: a holder took the value.
/// - `restart`: a holder was restarted so it reads the value.
/// - `check`: a token's new value was checked against its issuer.
/// - `revoke`: a token's old value stopped working.
public struct RotationStep: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case ready, issue, record, hold, restart, check, revoke
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
    /// The one step a person takes after the run, printed as the last line of a finished report. Only an address has one.
    public var handStep: String?

    public init(
        keys: [String], done: [RotationStep] = [], stopped: RotationStep? = nil, reason: String? = nil, handStep: String? = nil
    ) {
        self.keys = keys
        self.done = done
        self.stopped = stopped
        self.reason = reason
        self.handStep = handStep
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
            if let handStep = self.handStep { lines.append("    by hand  \(handStep)") }
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
    private let run: ShellCommandRunner
    private let vault: VaultAdmin
    private let mint: @Sendable (Int) -> String
    private let secrets: SecretsFile
    /// App name to the ssh target its dokku commands arrive at.
    private let dokkuTargets: [String: String]
    /// Postgres server name to the shell account that can `docker exec` its container.
    private let adminTargets: [String: String]
    /// App name to the secrets file of another service that holds a value this service issues.
    /// A dokku holder takes the value in its config, and this is where the declaration keeps it, so a later apply does not put the old one back.
    private let holderSecrets: [String: SecretsFile]
    /// Waits between two reads of vault's re-seal check, while vault starts again.
    private let pause: @Sendable (Int) async -> Void
    /// Whether the forge takes a token, the check of a `forgeToken` run.
    private let forgeAccepts: @Sendable (String) async throws -> Bool
    /// Writes a value to every forge repository whose Actions secrets hold the name, and answers those repositories.
    private let forgeRepos: @Sendable (_ name: String, _ value: String) async throws -> [String]
    /// Home Assistant's websocket, for a `homeAssistantToken` run.
    private let homeAssistant: HomeAssistantCall
    /// The time a Home Assistant token's name carries.
    private let now: @Sendable () -> Date

    /// How many times the re-seal check reads vault after the restart, and the seconds between two reads.
    /// Twenty reads three seconds apart give a restarted vault a minute to answer before the run calls the check failed.
    static let resealCheckAttempts = 20
    static let resealCheckPause = 3

    public init(
        vault: VaultAdmin,
        secrets: SecretsFile,
        dokkuTargets: [String: String] = [:],
        adminTargets: [String: String] = [:],
        holderSecrets: [String: SecretsFile] = [:],
        run: @escaping ShellCommandRunner = ShellRunner.withInput,
        mint: @escaping @Sendable (Int) -> String = { SecretMinter().token(bytes: $0) },
        pause: @escaping @Sendable (Int) async -> Void = { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) },
        forgeAccepts: @escaping @Sendable (String) async throws -> Bool = { try await ForgeTokenIssuer.accepts($0) },
        forgeRepos: (@Sendable (_ name: String, _ value: String) async throws -> [String])? = nil,
        homeAssistant: @escaping HomeAssistantCall = HomeAssistantTokens.live,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.vault = vault
        self.secrets = secrets
        self.dokkuTargets = dokkuTargets
        self.adminTargets = adminTargets
        self.holderSecrets = holderSecrets
        self.run = run
        self.mint = mint
        self.pause = pause
        self.forgeAccepts = forgeAccepts
        self.forgeRepos = forgeRepos ?? { name, value in try await ForgeSecrets(vault: vault).replaceEverywhere(name: name, value: value) }
        self.homeAssistant = homeAssistant
        self.now = now
    }

    /// Runs one plan and reports what it did.
    public func execute(_ plan: RotationPlan) async -> RotationReport {
        var report = RotationReport(keys: plan.keys, handStep: plan.handStep)

        // A re-seal checks its own door and every holder before the mint, because after the re-seal nothing goes back by itself.
        if case .vaultReseal = plan.rotation.issuer {
            let ready = RotationStep(phase: .ready, what: "the operator token opens vault's admin routes, and every holder is running")
            do {
                try await self.resealReady(plan)
                report.done.append(ready)
            } catch {
                report.stopped = ready
                report.reason = Self.explain(error)
                return report
            }
        }

        let values: [String: String]
        var resealed: VaultResealCount?
        var retiring: HomeAssistantTokens.Retiring?
        do {
            let issued = try await self.issue(plan)
            values = issued.values
            resealed = issued.resealed
            retiring = issued.retiring
            var what = plan.rotation.issuer.label(service: plan.service)
            if let resealed {
                what += "; vault re-sealed \(resealed.appDocuments) app document(s) and \(resealed.s3Keys) S3 key(s), "
                    + "and kept the old set in \(resealed.backup ?? "its data directory")"
            }
            report.done.append(RotationStep(phase: .issue, what: what))
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
            report.reason = Self.afterReseal("\(error)", resealed: resealed)
            return report
        }

        // A dokku holder of another service keeps the value in its own secrets file too, and only where that file already declares the key.
        for holder in plan.rotation.holders {
            guard case .dokkuConfig(let app, let key, _) = holder, app != plan.service, let file = self.holderSecrets[app] else { continue }
            let step = RotationStep(phase: .record, what: "\(key) written to the secrets file of \(app)")
            do {
                var held = try file.read()
                guard held[key] != nil else { continue }
                held[key] = try Self.value(for: key, plan: plan, values: values)
                try file.write(held)
                report.done.append(step)
            } catch {
                report.stopped = step
                report.reason = Self.afterReseal("\(error)", resealed: resealed)
                return report
            }
        }

        for holder in plan.rotation.holders {
            var step = RotationStep(phase: .hold, what: holder.label)
            do {
                switch holder {
                case .vaultDocument(let app, let name):
                    try await self.vault.setSecret(app: app, name: name, value: try Self.value(for: name, plan: plan, values: values))

                case .forgeRepoSecret(let name):
                    let repos = try await self.forgeRepos(name, try Self.value(for: name, plan: plan, values: values))
                    step.what += repos.isEmpty ? "; no repository holds it" : "; " + repos.joined(separator: ", ")

                case .dokkuConfig, .roostrc, .launchdEnvironment, .systemdEnvironment, .vaultSecret, .file:
                    for command in try Self.writeCommands(
                        holder, plan: plan, values: values, dokkuTargets: self.dokkuTargets)
                    {
                        _ = try await self.run(command)
                    }
                }
                report.done.append(step)
            } catch {
                report.stopped = step
                report.reason = Self.afterReseal(Self.redacting(Array(values.values), in: Self.explain(error)), resealed: resealed)
                return report
            }
        }

        for holder in plan.restarting {
            let step = RotationStep(phase: .restart, what: holder.restartLabel)
            do {
                for command in try Self.restartCommands(holder, dokkuTargets: self.dokkuTargets) {
                    _ = try await self.run(ShellCommand(command))
                }
                report.done.append(step)
            } catch {
                report.stopped = step
                report.reason = Self.afterReseal(Self.redacting(Array(values.values), in: Self.explain(error)), resealed: resealed)
                return report
            }
        }

        // A re-seal ends with vault opening every document under the new value, in the restarted process, house#45.
        if let resealed {
            let check = RotationStep(phase: .check, what: plan.rotation.issuer.checkLabel(service: plan.service))
            do {
                let found = try await self.awaitResealCheck(expecting: resealed)
                report.done.append(
                    RotationStep(
                        phase: .check,
                        what: "vault opens \(found.appDocuments) app document(s) and \(found.s3Keys) S3 key(s) under the new value"))
            } catch {
                report.stopped = check
                report.reason = "\(error)"
                return report
            }
            return report
        }

        // A token's run ends with the check and the revoke, house#56. Every other class ends at the restarts.
        guard plan.secretClass == .token else { return report }
        let check = RotationStep(phase: .check, what: plan.rotation.issuer.checkLabel(service: plan.service))
        do {
            switch plan.rotation.issuer {
            case .vaultAppKey:
                if let key = values.values.first { try await self.vault.checkAppKey(app: plan.service, key: key) }

            case .forgeToken(let name, _, _):
                guard let token = values.values.first, try await self.forgeAccepts(token) else { throw ForgeTokenError.refused(name: name) }

            case .homeAssistantToken(let url, _):
                if let token = values.values.first { try await HomeAssistantTokens.check(url: url, token: token, call: self.homeAssistant) }

            case .vaultS3Key, .vaultSecret, .postgresRole, .vaultReseal, .random, .manual:
                break
            }
            report.done.append(check)
        } catch {
            report.stopped = check
            report.reason = Self.redacting(Array(values.values), in: "\(error)")
            return report
        }

        // Home Assistant is the one issuer whose old value is still live here, and it goes only now that every holder has the new one.
        // Vault's key and S3 routes stopped the old value at the mint, and the forge retired it before, so for them the revoke is a fact to report.
        let revoke = RotationStep(phase: .revoke, what: plan.rotation.issuer.revokeLabel)
        if case .homeAssistantToken(let url, _) = plan.rotation.issuer, let retiring, let token = values.values.first {
            do {
                try await HomeAssistantTokens.revoke(url: url, token: token, retiring: retiring, call: self.homeAssistant)
                report.done.append(RotationStep(phase: .revoke, what: "Home Assistant deleted the old token '\(retiring.clientName)'"))
            } catch {
                report.stopped = revoke
                report.reason = Self.redacting(Array(values.values), in: "\(error)")
            }
            return report
        }
        report.done.append(revoke)
        return report
    }

    /// The reason a step stopped, in words a person acts on.
    ///
    /// A dokku command that answers `command not found` reached a shell and not dokku, which is what a box running
    /// Tailscale SSH does for the dokku user over its Tailscale address, seen on 2026-09-27. Everything else is
    /// the error as it came.
    static func explain(_ error: Error) -> String {
        if let failure = error as? CommandFailure, failure.message.contains("command not found") {
            return "the dokku user answered with a shell and not with dokku; on the box, `sudo tailscale set --ssh=false` "
                + "puts sshd back on port 22 for its Tailscale address"
        }
        return "\(error)"
    }

    // MARK: - The issuers

    /// What an issuer answered: the new value of every key, and for a re-seal what vault counted.
    struct Issued {
        var values: [String: String]
        var resealed: VaultResealCount?
        /// The old Home Assistant token, which the revoke deletes after every holder has the new one.
        var retiring: HomeAssistantTokens.Retiring?
    }

    /// The new value for every key of the plan, from whatever issues it.
    private func issue(_ plan: RotationPlan) async throws -> Issued {
        switch plan.rotation.issuer {
        case .vaultAppKey:
            return Issued(values: [try plan.singleKey(): try await self.vault.rotateAppKey(app: plan.service)])

        case .vaultS3Key(let app):
            let pair = try await self.vault.rotateS3Key(app: app)
            return Issued(values: try Self.s3Values(pair, keys: plan.keys))

        case .vaultSecret(let app, let name):
            let value = self.mint(32)
            try await self.vault.setSecret(app: app, name: name, value: value)
            return Issued(values: [try plan.singleKey(): value])

        case .postgresRole(let server, let role):
            let password = self.mint(32)
            do {
                _ = try await self.run(
                    Self.alterRoleCommand(
                        server: server,
                        role: role,
                        password: password,
                        on: self.adminTargets[server] ?? server))
            } catch let failure as CommandFailure {
                throw CommandFailure(
                    command: failure.command,
                    status: failure.status,
                    message: Self.redacting([password], in: failure.message))
            }
            return Issued(values: try self.rewrittenURLs(plan, password: password))

        case .vaultReseal:
            // Vault refuses and writes nothing while any one document does not open, and then the new value is dropped here unused.
            let key = try plan.singleKey()
            let value = self.mint(32)
            let resealed = try await self.vault.reseal(secret: value)
            return Issued(values: [key: value], resealed: resealed)

        case .random(let bytes):
            return Issued(values: [try plan.singleKey(): self.mint(bytes)])

        case .forgeToken(let name, let scopes, let retires):
            return Issued(values: [try plan.singleKey(): try await self.mintForgeToken(name: name, scopes: scopes, retires: retires)])

        case .homeAssistantToken(let url, let name):
            // Home Assistant makes a token only for a session that is signed in, and the token the service holds now is the one this run has.
            let key = try plan.singleKey()
            guard let current = try self.secrets.read()[key], !current.isEmpty else {
                throw RotationExecutorError.noCurrentToken(key: key)
            }
            let minted = try await HomeAssistantTokens.mint(url: url, current: current, name: name, at: self.now(), call: self.homeAssistant)
            return Issued(values: [key: minted.token], retiring: minted.retiring)

        case .manual(let recipe):
            throw RotationRefusal.manualIssuer(keys: plan.keys, recipe: recipe)
        }
    }

    /// Retires every earlier token of the name, then mints it, and answers the token the CLI printed.
    /// The forge refuses a second token of one name, so the retire comes first, as `forge-token` does it.
    private func mintForgeToken(name: String, scopes: String, retires: [String]) async throws -> String {
        for retired in [name] + retires {
            do {
                _ = try await self.run(ForgeTokenIssuer.retireCommand(name: retired))
            } catch is CommandFailure {
                // The forge answers an error when no token has the name, which leaves nothing to retire.
                continue
            }
        }
        let output: Data
        do {
            output = try await self.run(ForgeTokenIssuer.mintCommand(name: name, scopes: scopes))
        } catch let failure as CommandFailure {
            throw ForgeTokenError.notMinted(name: name, reason: "exit \(failure.status): \(failure.message.prefix(200))")
        }
        guard let token = ForgeTokenIssuer.token(in: output) else {
            throw ForgeTokenError.notMinted(name: name, reason: "the last line of the output is not a forge token")
        }
        return token
    }

    // MARK: - The re-seal

    /// The checks a re-seal makes before the mint: the operator token opens vault's admin routes, and every dokku holder is running.
    /// Vault's health route is the preflight's probe, so it is not asked again here.
    private func resealReady(_ plan: RotationPlan) async throws {
        _ = try await self.vault.whoami()
        for holder in plan.rotation.holders {
            guard case .dokkuConfig(let app, _, _) = holder else { continue }
            let target = try Self.dokkuTarget(app, in: self.dokkuTargets)
            let answer = try await self.run(ShellCommand(Self.runningCommand(app, on: target)))
            guard String(decoding: answer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                throw RotationExecutorError.notRunning(app: app)
            }
        }
    }

    /// Asks dokku whether an app's containers are running, which it answers as `true`, `false` or `mixed`.
    static func runningCommand(_ app: String, on target: String) -> [String] {
        ["ssh", "-o", "BatchMode=yes", target, "ps:report", app, "--running"]
    }

    /// Reads vault's re-seal check until the restarted vault answers, and accepts it only when every value opens.
    /// A read that fails while vault starts is tried again, and a read that names a file is final, because a restart does not change it.
    private func awaitResealCheck(expecting resealed: VaultResealCount) async throws -> VaultResealCount {
        var last: Error = RotationExecutorError.resealUnchecked
        for attempt in 1...Self.resealCheckAttempts {
            if attempt > 1 { await self.pause(Self.resealCheckPause) }
            let found: VaultResealCount
            do {
                found = try await self.vault.resealCheck()
            } catch {
                last = error
                continue
            }
            guard found.failed.isEmpty, found.appDocuments >= resealed.appDocuments, found.s3Keys >= resealed.s3Keys else {
                throw RotationExecutorError.resealDoesNotOpen(found: found, expected: resealed)
            }
            return found
        }
        throw last
    }

    /// The reason for a step that stopped after vault re-sealed, with the way back.
    /// Vault's files are sealed under the new value by then, so a vault that restarts on the old value locks every document.
    static func afterReseal(_ reason: String, resealed: VaultResealCount?) -> String {
        guard let resealed else { return reason }
        return reason
            + ". Vault already re-sealed every document under the new value, and the old set is in "
            + (resealed.backup ?? "vault's reseal-backups")
            + ". Before vault restarts, either set the new value from vault's secrets file on vault and pulse and restart both, "
            + "or stop vault, copy the old set back over its authz directory, and set the old value on vault and pulse"
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

    /// `ALTER ROLE` over the same `docker exec` channel `db provision` uses, with the statement on psql's standard input.
    /// The statement holds the password, so it goes through ssh and `docker exec -i` as input and is never an argument on either machine.
    static func alterRoleCommand(
        server: String, role: String, password: String, on target: String
    ) -> ShellCommand {
        let sql = "ALTER ROLE \"\(role)\" WITH LOGIN PASSWORD '\(password)';\n"
        return ShellCommand(
            AdminChannel.prefix(target) + ["docker", "exec", "-i", server, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-At"],
            standardInput: Data(sql.utf8))
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
    /// Every command carries the value on its standard input and never in an argument, house#46.
    static func writeCommands(
        _ holder: KindFile.Holder,
        plan: RotationPlan,
        values: [String: String],
        dokkuTargets: [String: String]
    ) throws -> [ShellCommand] {
        switch holder {
        case .dokkuConfig(let app, let key, let restart):
            let value = try Self.value(for: key, plan: plan, values: values)
            let target = try Self.dokkuTarget(app, in: dokkuTargets)
            let flags = restart == .stopStart ? ["--no-restart"] : []
            return [
                ShellCommand(
                    ["ssh", "-o", "BatchMode=yes", target, "--quiet", "config:import", "--format=json"] + flags + [app, "-"],
                    standardInput: try Self.dokkuImport(key: key, value: value))
            ]

        case .roostrc(let host, let key):
            let value = try Self.value(for: key, plan: plan, values: values)
            return [Self.onHost(host, script: Self.roostrcScript(key: key), value: value)]

        case .launchdEnvironment(let host, let label, let key):
            let value = try Self.value(for: key, plan: plan, values: values)
            return [Self.onHost(host, script: Self.plistScript(label: label, key: key), value: value)]

        case .systemdEnvironment(let host, let unit, let key):
            let value = try Self.value(for: key, plan: plan, values: values)
            return [Self.onHost(host, script: Self.dropInScript(unit: unit, key: key), value: value)]

        case .vaultSecret:
            // Vault already holds the value, and this holder reads it at boot. Its restart is the whole step.
            return []

        case .file(let host, let path):
            let value = try Self.value(for: path, plan: plan, values: values)
            return [Self.onHost(host, script: Self.fileScript(path: path), value: value)]

        case .vaultDocument, .forgeRepoSecret:
            // These take the value over HTTP in the executor, in a request body, and run no command.
            return []
        }
    }

    /// The one key and its value as the JSON object `dokku config:import --format=json` reads from standard input.
    ///
    /// `config:set` takes the value only as an argument, which `ps` shows on the box, and its `--encoded` form is the same value in base64.
    /// `config:import` in dokku 0.38.19 reads a JSON map of strings from `-` and merges it without `--replace`,
    /// so no process holds the value in its arguments.
    static func dokkuImport(key: String, value: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [key: value], options: [.sortedKeys, .withoutEscapingSlashes])
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

        case .file, .vaultDocument, .forgeRepoSecret:
            return []
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

    /// A holder's script on its host, with the value on standard input and the value preamble in front of the script.
    static func onHost(_ host: String, script: String, value: String) -> ShellCommand {
        ShellCommand(Self.onHost(host, script: Self.valuePreamble + script), standardInput: Data(value.utf8))
    }

    /// The opening of every holder script: standard input goes to a mode 600 file in `$t`, which the shell removes when it exits.
    /// An empty input stops the script before it touches the holder,
    /// because a pipe that carried nothing looks like success, as `"KEY=$(cat)"` did on 2026-09-08.
    static let valuePreamble = #"umask 077; t=$(mktemp) || exit 1; trap 'rm -f "$t"' EXIT; cat > "$t"; "#
        + #"[ -s "$t" ] || { echo 'no value arrived on standard input' >&2; exit 1; }; "#

    /// Replaces a key in `~/.roostrc` with the value in `$t`, keeping every other line.
    /// The file is rewritten beside itself and moved into place, so a failure halfway leaves the old file whole.
    static func roostrcScript(key: String) -> String {
        #"f="$HOME/.roostrc"; touch "$f"; rm -f "$f.rotating"; "#
            + #"{ grep -v '^\#(key)=' "$f"; printf '\#(key)='; cat "$t"; printf '\n'; } > "$f.rotating" && mv "$f.rotating" "$f""#
    }

    /// Writes the value in `$t` whole to a path, `~` expanded against `$HOME`, as a mode 600 file only its owner can read.
    static func fileScript(path: String) -> String {
        let target = path.hasPrefix("~/") ? "$HOME/" + path.dropFirst(2) : path
        // The directory is made first: on 2026-09-29 a holder under ~/.config/gigs failed on a Mac that had no such directory,
        // after the issuer had minted and the other holders had taken the value.
        return #"p="\#(target)"; mkdir -p "$(dirname "$p")" && rm -f "$p.rotating" && cat "$t" > "$p.rotating" && "#
            + #"chmod 600 "$p.rotating" && mv "$p.rotating" "$p""#
    }

    /// Sets a key in a launchd plist's `EnvironmentVariables` to the value in `$t`, adding the dictionary when the plist carries none.
    ///
    /// PlistBuddy takes a value only inside its `-c` argument, so the value goes into a small plist file that `Merge` reads.
    /// `Merge` skips a key that is already there, so the key is deleted first, on a copy that is moved into place.
    static func plistScript(label: String, key: String) -> String {
        let buddy = "/usr/libexec/PlistBuddy"
        return #"pl="$HOME/Library/LaunchAgents/\#(label).plist"; "#
            + #"[ -f "$pl" ] || { echo "no launchd plist at $pl" >&2; exit 1; }; "#
            + #"x=$(mktemp) || exit 1; trap 'rm -f "$t" "$x" "$pl.rotating"' EXIT; "#
            + #"{ printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>\#(key)</key><string>'; "#
            + #"sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$t"; printf '</string></dict></plist>\n'; } > "$x" && "#
            + #"cp "$pl" "$pl.rotating" && "#
            + #"{ \#(buddy) -c 'Add :EnvironmentVariables dict' "$pl.rotating" >/dev/null 2>&1; "#
            + #"\#(buddy) -c 'Delete :EnvironmentVariables:\#(key)' "$pl.rotating" >/dev/null 2>&1; "#
            + #"\#(buddy) -c "Merge $x :EnvironmentVariables" "$pl.rotating"; } && mv "$pl.rotating" "$pl""#
    }

    /// Bootstraps a launchd agent again, the same two lines the job installer writes.
    static func bootstrapScript(label: String) -> String {
        "launchctl bootout gui/$(id -u)/\(label) >/dev/null 2>&1 || true; "
            + "launchctl bootstrap gui/$(id -u) \"$HOME/Library/LaunchAgents/\(label).plist\""
    }

    /// Sets a key in a systemd user unit's environment to the value in `$t`, through a drop-in of hatchery's own.
    ///
    /// A drop-in rather than the unit file, so a rotation never rewrites the artifact the job installer owns.
    /// Inside the quotes systemd reads a backslash and a double quote as escapes and a percent sign as a specifier, so the script escapes all three.
    static func dropInScript(unit: String, key: String) -> String {
        #"d="$HOME/.config/systemd/user/\#(unit).d"; mkdir -p "$d" && rm -f "$d/rotation.conf.rotating" && "#
            + #"{ printf '[Service]\nEnvironment="\#(key)='; sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g' "$t"; printf '"\n'; } "#
            + #"> "$d/rotation.conf.rotating" && mv "$d/rotation.conf.rotating" "$d/rotation.conf" && systemctl --user daemon-reload"#
    }

    /// The text with every value in it replaced by a mark, for a reason a person reads.
    /// A holder's error is the remote side's standard error, and nothing promises that a tool on the box never echoes its input there,
    /// so the value is withheld both as it is and as the JSON a dokku holder sends.
    static func redacting(_ values: [String], in text: String) -> String {
        let forms = values.filter { !$0.isEmpty }.flatMap { value -> [String] in
            let encoded = (try? JSONSerialization.data(withJSONObject: [value], options: .withoutEscapingSlashes))
                .map { String(decoding: $0, as: UTF8.self).dropFirst(2).dropLast(2) }
                .map(String.init)
            return [value] + (encoded.map { [$0] } ?? [])
        }
        return forms.reduce(text) { $0.replacingOccurrences(of: $1, with: "<value withheld>") }
    }
}

/// The way an executor cannot run a plan the planner allowed.
///
/// - `noBox`: a dokku holder's app is declared, and no stack says which box it runs on.
/// - `unknownRestart`: a vault-reading holder names an app hatchery has no way to restart.
/// - `noCurrentValue`: a URL rewrite needs the old URL, and the secrets file holds none.
/// - `noCurrentToken`: Home Assistant makes a token only for a signed-in session, and the secrets file holds no current token to sign in with.
/// - `notAConnectionURL`: the key holds something with no password in it to replace.
/// - `notAPair`: an S3 rotation must name exactly two keys, one of them a secret.
/// - `notASingleKey`: this issuer answers one value, and the plan holds more than one key.
/// - `ambiguousValue`: a holder does not know which of the plan's values is its own, whether it renames the
///   value or, like `file`, names no key of its own at all, and the plan issued more than one.
/// - `notRunning`: a re-seal holder's app is not running, so the run stops before the mint.
/// - `resealDoesNotOpen`: the restarted vault does not open every value the re-seal sealed. The old set is in the backup vault named.
/// - `resealUnchecked`: vault never answered the re-seal check after its restart.
public enum RotationExecutorError: Error, CustomStringConvertible, Equatable {
    case noBox(app: String)
    case unknownRestart(app: String)
    case noCurrentValue(key: String)
    case noCurrentToken(key: String)
    case notAConnectionURL(key: String)
    case notAPair(keys: [String])
    case notASingleKey(keys: [String])
    case ambiguousValue(key: String, keys: [String])
    case notRunning(app: String)
    case resealDoesNotOpen(found: VaultResealCount, expected: VaultResealCount)
    case resealUnchecked

    public var description: String {
        switch self {
        case .noBox(let app):
            return "no stack says which box \(app) runs on, so its config cannot be set"

        case .unknownRestart(let app):
            return "\(app) reads this value from vault at boot, and hatchery has no way to restart it; "
                + "restart it where it runs"

        case .noCurrentValue(let key):
            return "the secrets file holds no \(key), and the new password goes inside the old URL"

        case .noCurrentToken(let key):
            return "the secrets file holds no \(key), and Home Assistant makes a new token only for a session signed in with the current one; "
                + "seed it once with `pbpaste | house-secret <stack> <service> \(key)`"

        case .notAConnectionURL(let key):
            return "\(key) is not a connection URL with a password in it"

        case .notAPair(let keys):
            return "an S3 rotation replaces two keys, one of them named SECRET; this one names "
                + keys.joined(separator: " + ")

        case .notASingleKey(let keys):
            return "this issuer answers one value, and the declaration gives it "
                + keys.joined(separator: " + ")

        case .notRunning(let app):
            return "dokku does not report \(app) as running, so nothing is minted; start it and run the rotation again"

        case .resealDoesNotOpen(let found, let expected):
            let failed = found.failed.isEmpty ? "" : "; it does not open " + found.failed.joined(separator: ", ")
            return "the restarted vault opens \(found.appDocuments) of \(expected.appDocuments) app document(s) "
                + "and \(found.s3Keys) of \(expected.s3Keys) S3 key(s)\(failed). The old set is in \(expected.backup ?? "vault's reseal-backups"); "
                + "roll back by the README's re-seal recipe"

        case .resealUnchecked:
            return "vault did not answer the re-seal check after its restart"

        case .ambiguousValue(let key, let keys):
            return "the holder names \(key), which the issuer did not answer for, and the plan issued "
                + "\(keys.count) values, so there is no one value to give it"
        }
    }
}

import ArgumentParser
import Foundation
import HatcheryKit

/// The door on the rotations a service declares.
///
/// A secret's rotation is a declaration in the service's own kind file: what issues the value, who holds it,
/// and how each holder takes a new one. `holders` reads that declaration, and `rotate` executes it.
struct Secrets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Read and execute the rotations a service declares.",
        discussion: """
            A value read once at boot rotates by a config change and a restart. A value reissued \
            elsewhere rotates in order: the issuer first, then the config, then the restart. A value \
            fetched per use is not config at all and needs no restart. A shared bearer invalidates every \
            holder at once, so a rotation names its holders before it turns the value over.

            The vault credential is the operator token this machine signed in with, and never an argument, \
            because an argument lands in the shell history and in ps. Run hatchery vault login to get one.
            """,
        subcommands: [Holders.self, Rotate.self, Sync.self, Ledger.self, Issued.self]
    )

    /// What a `<stack>/<service>` target resolves to: the service, and the kind file that declares its rotations.
    struct Target {
        var service: ServiceSpec
        var stack: StackSpec
        var kind: KindFile
        var apps: Set<String>
        var hosts: Set<String>
        var manifests: [StackManifest]
        var manifestPath: String
    }

    /// Reads no box. Every fact here is in the manifests and the kind registry beside them.
    static func resolve(_ text: String, manifest: [String]) throws -> Target {
        guard let target = DeclaredProvision.target(text) else {
            throw ValidationError("name the service as <stack>/<service>, for example rookery/rookery")
        }
        let requested = manifest.isEmpty ? [ManifestLocator.defaultName] : manifest
        let loaded = try requested.map { try ManifestLocator.load($0) }

        for entry in loaded {
            guard let stack = entry.manifest.stack(named: target.stack),
                let service = stack.service(named: target.service)
            else { continue }
            let registry = KindRegistry(manifestPath: entry.path)
            guard let kind = try registry.kindFile(for: service.kind) else {
                throw RotationRefusal.noKindFile(
                    service: service.name, kind: service.kind.rawValue)
            }
            let manifests = loaded.map(\.manifest)
            return Target(
                service: service,
                stack: stack,
                kind: kind,
                apps: RotationPlanner.apps(in: manifests),
                hosts: RotationPlanner.hosts(in: manifests),
                manifests: manifests,
                manifestPath: entry.path)
        }
        throw ValidationError("no manifest declares \(target.stack)/\(target.service)")
    }

    /// Every bearer of every rotatable secret, and nothing else.
    ///
    /// A holder the manifest does not know is marked rather than refused, because this command writes nothing
    /// and a person asking who holds a value is owed the whole list, gap and all.
    struct Holders: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "holders",
            abstract: "Print who holds each of a service's rotatable secrets."
        )

        @Argument(help: "The service, as <stack>/<service>.")
        var target: String

        @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
        var manifest: [String] = []

        func run() async throws {
            let resolved = try Secrets.resolve(self.target, manifest: self.manifest)
            let groups = resolved.kind.rotationGroups()
            guard !groups.isEmpty else {
                print("  \(resolved.service.name) declares no secret with a rotation")
                return
            }

            for group in groups {
                print("  \(group.keys.joined(separator: " + "))")
                switch group.rotation {
                case .declared(let rotation):
                    print("    issues   \(rotation.issuer.label(service: resolved.service.name))")
                    for holder in rotation.holders {
                        print("    holds    \(holder.label)\(Self.gap(holder, in: resolved))")
                    }
                    if rotation.holders.isEmpty {
                        print("    holds    nobody hatchery can reach")
                    }

                case .owned(let owner):
                    print("    held from \(owner)")

                case .unrotated(let reason):
                    print("    not rotated  \(reason)")
                }
            }
            let missing = resolved.kind.secretRotations().filter { $0.rotation == nil }
            for entry in missing {
                print("  \(entry.key)")
                print("    issues   nothing; this secret declares no rotation")
            }
        }

        /// The note beside a holder the manifest cannot reach, or nothing when it can.
        static func gap(_ holder: KindFile.Holder, in resolved: Secrets.Target) -> String {
            switch holder.target {
            case .dokkuApp(let app):
                return resolved.apps.contains(app) ? "" : "   (no app \(app) in the manifest)"

            case .host(let host):
                return resolved.hosts.contains(host) ? "" : "   (no host \(host) in the manifest)"

            case .vaultApp:
                return ""
            }
        }
    }

    /// Replaces a declared secret, in the order the declaration rules.
    ///
    /// The plan prints first, always. Without `--yes` that is the whole run, so the default is a dry run and
    /// executing is the thing a person has to ask for. `--all` widens this from one service to every service
    /// the named manifests declare.
    struct Rotate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rotate",
            abstract: "Replace a declared secret: the issuer, then every holder, then every restart.",
            discussion: """
                Name the keys to rotate, or name none and every rotatable key of the service is planned. \
                A key issued by a person refuses the run and prints the recipe instead, and a holder the \
                manifest does not know refuses it too, because a bearer nothing can reach keeps the old \
                value after the new one is issued. A key another service owns is skipped, not run; that \
                service's own rotation is what turns it over. A key that declares a rotation of none is \
                skipped too, and its reason prints.

                --all reads every named manifest and runs every declared rotation of every service it finds, \
                in the same order, instead of the one service named on the command line. A refused key does \
                not stop the others, and the run ends with one line per service and key naming what happened.
                """
        )

        @Argument(help: "The service, as <stack>/<service>. Omit it with --all.")
        var target: String?

        @Argument(help: "The keys to rotate. Every rotatable key of the service when none are named.")
        var keys: [String] = []

        @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
        var manifest: [String] = []

        @Flag(name: .long, help: "Every declared rotation of every service the manifests name, instead of one service.")
        var all = false

        @Flag(name: .long, help: "Print the plan and stop, whatever else is given.")
        var dryRun = false

        @Flag(name: .long, help: "Execute the plan. Without it the plan prints and nothing changes.")
        var yes = false

        @Option(name: .long, help: "The ledger file each finished rotation stamps with its issue date.")
        var ledger: String?

        func validate() throws {
            if self.all {
                guard self.target == nil else {
                    throw ValidationError("--all reads every service the manifests declare; name none")
                }
                guard self.keys.isEmpty else {
                    throw ValidationError("--all rotates every key of every service; name none")
                }
            } else {
                guard self.target != nil else {
                    throw ValidationError("name the service, as <stack>/<service>, or pass --all")
                }
            }
        }

        func run() async throws {
            if self.all {
                try await self.runAll()
                return
            }
            guard let target = self.target else {
                throw ValidationError("name the service, as <stack>/<service>, or pass --all")
            }
            try await self.runOne(target)
        }

        private func runOne(_ target: String) async throws {
            let resolved = try Secrets.resolve(target, manifest: self.manifest)
            let plans = try RotationPlanner.plans(
                service: resolved.service.name,
                keys: self.keys,
                in: resolved.kind,
                apps: resolved.apps,
                hosts: resolved.hosts)
            let owned = RotationPlanner.owned(keys: self.keys, in: resolved.kind)
            let unrotated = RotationPlanner.unrotated(keys: self.keys, in: resolved.kind)

            print("  \(resolved.stack.name)/\(resolved.service.name), \(plans.count) rotation(s):")
            plans.flatMap { $0.lines() }.forEach { print($0) }
            for entry in owned {
                print("  \(entry.keys.joined(separator: " + "))")
                print("    held from \(entry.owner)")
            }
            for entry in unrotated {
                print("  \(entry.keys.joined(separator: " + "))")
                print("    not rotated  \(entry.reason)")
            }

            guard self.yes, !self.dryRun else {
                print("  nothing changed. Run it again with --yes to execute this plan.")
                return
            }
            let credential: VaultAdminCredential
            if plans.contains(where: { $0.rotation.issuer.needsVaultSession }) {
                guard let resolved = VaultAdminCredential.resolve() else {
                    throw RotationRefusal.noVaultSession
                }
                credential = resolved
            } else {
                // No plan here reaches vault, so no call carries this and the empty value is never sent.
                credential = .session("")
            }

            // Every host the plans reach is asked once before the first issuer runs. A silent host is the run refused.
            let dokkuTargets = Secrets.dokkuTargets(for: resolved)
            let adminTargets = Secrets.adminTargets(for: resolved)
            let silent = await RotationPreflight.silent(
                RotationPreflight.probes(of: plans.map { ($0, dokkuTargets, adminTargets) }), run: ShellRunner.live)
            if !silent.isEmpty {
                silent.forEach { print("  \($0) did not answer, so nothing is minted for a holder on it") }
                print("  refused: a rotation mints nothing while a holder cannot be reached")
                throw ExitCode.failure
            }

            let executor = RotationExecutor(
                vault: VaultAdmin(credential: credential),
                secrets: .onDisk(at: Secrets.secretsURL(for: resolved)),
                dokkuTargets: dokkuTargets,
                adminTargets: adminTargets,
                holderSecrets: Secrets.holderSecrets(in: resolved.stack, manifestPath: resolved.manifestPath))

            // One plan at a time, and the first failure ends the run. A later plan would issue a value while
            // an earlier one had already turned a value over that nothing took.
            for plan in plans {
                let report = await executor.execute(plan)
                report.lines().forEach { print($0) }
                guard report.succeeded else { throw ExitCode.failure }
                Secrets.stampLedger(at: Secrets.ledgerURL(self.ledger)) { state, day in
                    state.stampIssued(
                        stack: resolved.stack.name,
                        service: resolved.service.name,
                        keys: plan.keys,
                        on: day)
                }
            }
            print("  run hatchery state seal so the new values reach the encrypted backup.")
        }

        private func runAll() async throws {
            let requested = self.manifest.isEmpty ? [ManifestLocator.defaultName] : self.manifest
            let loaded = try requested.map { try ManifestLocator.load($0) }
            let manifests = loaded.map(\.manifest)
            let apps = RotationPlanner.apps(in: manifests)
            let hosts = RotationPlanner.hosts(in: manifests)
            let dokkuTargets = Secrets.dokkuTargets(in: manifests)
            let adminTargets = Secrets.adminTargets(in: manifests)

            var targets: [RotationTarget] = []
            for entry in loaded {
                let registry = KindRegistry(manifestPath: entry.path)
                for stack in entry.manifest.stacks {
                    for service in stack.services {
                        guard let kind = try registry.kindFile(for: service.kind) else { continue }
                        // What the service carries, from its config and secrets files, so a kind shared by several
                        // services plans a rotation only where the key is. A missing file reads as empty.
                        let carried = Set(
                            try ConfigSync.readDeclared(
                                config: ConfigSync.configURL(for: service, in: stack, manifestPath: entry.path),
                                secrets: ConfigSync.secretsURL(for: service, in: stack, manifestPath: entry.path)
                            ).keys)
                        targets.append(
                            RotationTarget(
                                stack: stack.name,
                                service: service.name,
                                kind: kind,
                                dokkuTargets: dokkuTargets,
                                adminTargets: adminTargets,
                                secretsURL: Secrets.secretsURL(
                                    service: service, stack: stack, manifestPath: entry.path),
                                carried: carried,
                                holderSecrets: Secrets.holderSecrets(in: stack, manifestPath: entry.path)))
                    }
                }
            }

            // The credential is resolved once, before any rotation runs, and the value is fixed here so the executor
            // closures below capture a constant.
            let vault: VaultAdmin
            if self.yes, !self.dryRun, targets.contains(where: { Self.needsVaultSession(in: $0.kind) }) {
                guard let credential = VaultAdminCredential.resolve() else {
                    throw RotationRefusal.noVaultSession
                }
                vault = VaultAdmin(credential: credential)
            } else {
                vault = VaultAdmin(credential: .session(""))
            }

            // Lines print as they happen, so a run that is killed leaves every finished step on the screen.
            let run = await RotationRun.all(
                targets: targets, apps: apps, hosts: hosts, dryRun: self.dryRun, yes: self.yes,
                makeExecutor: { target in
                    RotationExecutor(
                        vault: vault,
                        secrets: .onDisk(at: target.secretsURL),
                        dokkuTargets: target.dokkuTargets,
                        adminTargets: target.adminTargets,
                        holderSecrets: target.holderSecrets)
                },
                probe: ShellRunner.live,
                say: { line in
                    print(line)
                    // Every open stream, so no global stream is named, which Linux's Swift counts as shared state.
                    fflush(nil)
                })

            if run.outcomes.contains(where: { $0.state == .run }) {
                Secrets.stampLedger(at: Secrets.ledgerURL(self.ledger)) { state, day in
                    state.stampIssued(from: run.outcomes, on: day)
                }
            }
            guard run.silent.isEmpty || self.dryRun else { throw ExitCode.failure }
            guard !run.outcomes.contains(where: { $0.state == .failed }) else { throw ExitCode.failure }
        }

        /// Whether any of a kind file's declared, unowned rotations reaches vault, so `--all` knows to resolve
        /// a credential once before it runs any of them.
        private static func needsVaultSession(in kind: KindFile) -> Bool {
            kind.rotationGroups().contains { group in
                guard case .declared(let rotation) = group.rotation else { return false }
                return rotation.issuer.needsVaultSession
            }
        }
    }

    /// Puts a declared service's own secrets into its vault document, so the app reads them at boot.
    ///
    /// One direction only. The secrets file is what hatchery declares and what `state seal` backs up, so it is
    /// the source and the document is the copy. Reading the document back would make two sources of one fact.
    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync",
            abstract: "Set a declared service's secrets into its vault document.",
            discussion: """
                Every secret-marked key of the service goes into the app's document, less the three vault \
                keys: the app key never goes into the document it opens, and the URL is how the app finds \
                vault before it has read anything.

                The credential is the operator token this machine signed in with, and never an argument.
                """
        )

        @Argument(help: "The service, as <stack>/<service>.")
        var target: String

        @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
        var manifest: [String] = []

        @Flag(name: .long, help: "Print the names that would be set and stop.")
        var dryRun = false

        func run() async throws {
            let resolved = try Secrets.resolve(self.target, manifest: self.manifest)
            let contract = resolved.kind.contract(backend: resolved.stack.backend)
            let declared = try ConfigSync.readDeclared(
                config: ConfigSync.configURL(
                    for: resolved.service, in: resolved.stack, manifestPath: resolved.manifestPath),
                secrets: ConfigSync.secretsURL(
                    for: resolved.service, in: resolved.stack, manifestPath: resolved.manifestPath))
            let values = VaultRegistrar.documentSecrets(in: declared, contract: contract)

            print("  \(resolved.stack.name)/\(resolved.service.name), \(values.count) secret(s):")
            for name in values.keys.sorted() { print("    \(name)") }
            guard !values.isEmpty else { return }
            guard !self.dryRun else {
                print("  dry run; vault was not called")
                return
            }

            let app = declared[VaultRegistrar.appNameKey] ?? resolved.service.name
            let baseURL = declared[VaultRegistrar.urlKey].flatMap { $0.isEmpty ? nil : $0 }
                ?? VaultAdmin.defaultBaseURL
            guard let credential = VaultAdminCredential.resolve(vault: baseURL) else {
                throw RotationRefusal.noVaultSession
            }
            let vault = VaultAdmin(baseURL: baseURL, credential: credential)
            let held = try await vault.setSecrets(app: app, values: values)
            print("  \(app) now holds \(held.joined(separator: " + "))")
        }
    }

    /// Every secret the manifests declare, with who issues it, whether it is known to work, when it was issued, and when it
    /// expires.
    ///
    /// A run records the day it first sees each key, so a token older than the ledger shows that day and is put up for
    /// rotation. With `--due` it prints only the reminders and exits 1 when any is owed, for a check that runs on a schedule.
    struct Ledger: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ledger",
            abstract: "List every declared secret: issuer, liveness, issue date, expiry, and what is owed next.",
            discussion: """
                LIVE reads cannot probe for a key no issuer API can check, such as an Apple private key or a Google \
                client secret. Such a key is checked by use, and it never reads live. A key whose issue date is \
                unknown shows the day the ledger first saw it and is put up for rotation; a finished rotation, or \
                hatchery secrets issued, stamps the date. A key whose kind file declares a rotation of none \
                shows the reason as NEXT, is never put up for rotation, and owes no reminder.

                The ledger file holds names and dates, never a value.

                --json prints the same rows as one document, and --publish sends that document to pulse with the \
                roost node key, where the coop's Tokens page reads it beside the declaration. Pulse is the ruled \
                read route, house ticket 2, and the dates live in the ledger file on the Mac that runs house-rotate, \
                so that Mac is the one that publishes.
                """
        )

        @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
        var manifest: [String] = []

        @Option(name: .long, help: "The ledger file. Defaults to ~/.config/hatchery/ledger.json.")
        var ledger: String?

        @Option(name: .long, help: "Print only the reminders owed within this many days, and exit 1 when any is owed.")
        var due: Int?

        @Flag(name: .long, help: "Print the ledger as one JSON document instead of the table.")
        var json = false

        @Flag(name: .long, help: "POST the document to pulse, with the roost node key.")
        var publish = false

        @Option(name: .long, help: "The pulse instance to publish to.")
        var pulse: String = "https://pulse.jimmyhoughjr.net"

        @Option(name: .long, help: "The file holding the pulse node key.")
        var keyFile: String = "~/.roost_node_key"

        func run() async throws {
            let requested = self.manifest.isEmpty ? [ManifestLocator.defaultName] : self.manifest
            let loaded = try requested.map { try ManifestLocator.load($0) }
            let targets = try SecretLedger.targets(in: loaded)
            let url = Secrets.ledgerURL(self.ledger)
            let today = Date()

            var state = try LedgerState.load(from: url)
            let rows = SecretLedger.rows(for: targets, state: &state, today: today)
            try state.save(to: url)

            let window = self.due ?? SecretLedger.reminderDays
            let reminders = SecretLedger.reminders(for: targets, within: window, today: today)
            if let due = self.due {
                guard !reminders.isEmpty else {
                    print("  no expiry falls within \(due) day(s), and every key no API can check has one typed")
                    return
                }
                reminders.forEach { print("  \($0)") }
                throw ExitCode.failure
            }

            if self.json || self.publish {
                let document = LedgerDocument(manifests: loaded.map(\.path), rows: rows, reminders: reminders)
                let data = try document.encoded()
                if self.json { print(String(decoding: data, as: UTF8.self)) }
                guard self.publish else { return }
                let key = try Declaration.nodeKey(at: self.keyFile)
                if let reason = await Declaration.publish(data, to: self.pulse, key: key, path: LedgerDocument.pulsePath) {
                    FileHandle.standardError.write(Data("  publish: pulse did not take the ledger (\(reason))\n".utf8))
                    throw ExitCode.failure
                }
                print("  published \(rows.count) token(s) to \(self.pulse)\(LedgerDocument.pulsePath)")
                return
            }

            SecretLedger.lines(for: rows).forEach { print($0) }
            print("")
            print(
                "  \(rows.count) token(s), \(rows.filter(\.listedForRotation).count) put up for rotation, "
                    + "\(rows.filter(\.classOwed).count) owe a class")
            reminders.forEach { print("  reminder: \($0)") }
        }
    }

    /// Stamps the issue date of a key a person turned over by hand, which no rotation run records.
    struct Issued: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "issued",
            abstract: "Record the day a person issued a new value for these keys."
        )

        @Argument(help: "The service, as <stack>/<service>.")
        var target: String

        @Argument(help: "The keys a person issued.")
        var keys: [String]

        @Option(name: .long, help: "The day, as yyyy-MM-dd. Today when omitted.")
        var on: String?

        @Option(name: .long, help: "The ledger file. Defaults to ~/.config/hatchery/ledger.json.")
        var ledger: String?

        func validate() throws {
            guard DeclaredProvision.target(self.target) != nil else {
                throw ValidationError("name the service as <stack>/<service>, for example estate/vault")
            }
            guard !self.keys.isEmpty else { throw ValidationError("name at least one key") }
            if let on = self.on, LedgerDay.date(on) == nil {
                throw ValidationError("--on takes a day as yyyy-MM-dd")
            }
        }

        func run() async throws {
            guard let target = DeclaredProvision.target(self.target) else {
                throw ValidationError("name the service as <stack>/<service>, for example estate/vault")
            }
            let url = Secrets.ledgerURL(self.ledger)
            var state = try LedgerState.load(from: url)
            let day = self.on ?? LedgerDay.string(Date())
            state.stampIssued(stack: target.stack, service: target.service, keys: self.keys, on: day)
            try state.save(to: url)
            print("  \(target.stack)/\(target.service) \(self.keys.joined(separator: " + ")) issued \(day)")
        }
    }

    /// The ledger file a command reads and stamps.
    static func ledgerURL(_ path: String?) -> URL {
        path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? LedgerState.defaultURL
    }

    /// Stamps the ledger after a rotation finished.
    /// A ledger that cannot be written warns and never fails the run, because the new value is already out on every holder.
    static func stampLedger(at url: URL, _ change: (inout LedgerState, String) -> Void) {
        do {
            var state = try LedgerState.load(from: url)
            change(&state, LedgerDay.string(Date()))
            try state.save(to: url)
        } catch {
            print("  the ledger at \(url.path) was not stamped: \(error)")
            print("  run hatchery secrets issued with the keys above to record today's date")
        }
    }

    /// The service's own secrets file, which every issued value is written to before any holder is told.
    static func secretsURL(for target: Target) -> URL {
        Self.secretsURL(service: target.service, stack: target.stack, manifestPath: target.manifestPath)
    }

    /// The named service's own secrets file, resolved without a full ``Target``, for a caller that already
    /// has the service and the stack in hand from walking a manifest itself.
    static func secretsURL(service: ServiceSpec, stack: StackSpec, manifestPath: String) -> URL {
        ConfigSync.secretsURL(for: service, in: stack, manifestPath: manifestPath)
            ?? ConfigSync.configURL(for: service, in: stack, manifestPath: manifestPath)
    }

    /// The secrets file of every service in a stack that has one, by service name.
    /// A rotation writes a held value into the holder's own file too, so the next apply of that service does not set the old value again.
    static func holderSecrets(in stack: StackSpec, manifestPath: String) -> [String: SecretsFile] {
        var files: [String: SecretsFile] = [:]
        for service in stack.services {
            guard let url = ConfigSync.secretsURL(for: service, in: stack, manifestPath: manifestPath) else { continue }
            files[service.name] = .onDisk(at: url)
        }
        return files
    }

    /// Every dokku app in every stack, with the target its commands arrive at.
    static func dokkuTargets(for target: Target) -> [String: String] {
        Self.dokkuTargets(in: target.manifests)
    }

    static func dokkuTargets(in manifests: [StackManifest]) -> [String: String] {
        var targets: [String: String] = [:]
        for manifest in manifests {
            for stack in manifest.stacks where stack.backend == .dokku {
                guard let host = stack.host, !host.isEmpty else { continue }
                for service in stack.services {
                    targets[service.name] = DokkuProvider.sshTarget(host)
                }
            }
        }
        return targets
    }

    /// Every postgres cluster, with the shell account that can `docker exec` its container.
    ///
    /// `db_admin` is the setting that names it, the same one `db provision` reads. Without one the stack's own
    /// host is used, which is right when that host takes a plain shell.
    static func adminTargets(for target: Target) -> [String: String] {
        Self.adminTargets(in: target.manifests)
    }

    static func adminTargets(in manifests: [StackManifest]) -> [String: String] {
        var targets: [String: String] = [:]
        for manifest in manifests {
            for stack in manifest.stacks {
                let admin = stack.settings?[BackendSetting.dbAdmin.key] ?? stack.host
                guard let admin, !admin.isEmpty else { continue }
                for service in stack.services where service.isPostgresCluster {
                    targets[service.name] = admin
                }
            }
        }
        return targets
    }
}

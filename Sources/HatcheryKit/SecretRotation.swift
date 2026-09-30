import Foundation

// MARK: - The words a plan is printed in

extension KindFile.Issuer {
    /// What this issuer does, for a person reading the plan.
    ///
    /// `service` is the name of the service whose kind file declares the rotation. Only `vaultAppKey` reads it,
    /// because that issuer names no app of its own.
    public func label(service: String) -> String {
        switch self {
        case .vaultAppKey:
            return "vault mints a new app key for \(service)"

        case .vaultS3Key(let app):
            return "vault rotates the S3 key pair of \(app), and answers both halves once"

        case .vaultSecret(let app, let name):
            return "hatchery mints a value, and vault stores it as \(name) on \(app)"

        case .postgresRole(let server, let role):
            return "a new password for role \(role) on \(server), by ALTER ROLE"

        case .random(let bytes):
            return "hatchery mints \(bytes) random bytes"

        case .manual(let recipe):
            return "a person issues it: \(recipe)"
        }
    }

    /// Whether only a person can issue this value, so hatchery refuses the run and prints the recipe.
    public var isManual: Bool {
        if case .manual = self { return true }
        return false
    }

    /// The recipe of a person-issued value, or `nil` for an issuer hatchery runs.
    public var recipe: String? {
        if case .manual(let recipe) = self { return recipe }
        return nil
    }

    /// How a token run checks the new value works, for a person reading the plan.
    public func checkLabel(service: String) -> String {
        switch self {
        case .vaultAppKey:
            return "vault opens the secrets document of \(service) with the new key"

        case .vaultS3Key:
            return "no route checks an S3 pair, so the first signed request is the check"

        case .vaultSecret, .postgresRole, .random, .manual:
            return "no check for this issuer"
        }
    }

    /// How a token run revokes the old value, for a person reading the plan.
    public var revokeLabel: String {
        switch self {
        case .vaultAppKey:
            return "vault stopped the old key when it minted the new one"

        case .vaultS3Key:
            return "vault replaced the old pair when it minted the new one"

        case .vaultSecret, .postgresRole, .random, .manual:
            return "nothing revokes the old value for this issuer"
        }
    }
}

extension KindFile.Holder {
    /// Where this holder keeps the value, for a person reading the plan.
    public var label: String {
        switch self {
        case .dokkuConfig(let app, let key, let restart):
            return "\(key) in the config of \(app), \(restart.label)"

        case .roostrc(let host, let key):
            return "\(key) in ~/.roostrc on \(host)"

        case .launchdEnvironment(let host, let label, let key):
            return "\(key) in the launchd plist of \(label) on \(host)"

        case .systemdEnvironment(let host, let unit, let key):
            return "\(key) in the systemd environment of \(unit) on \(host)"

        case .vaultSecret(let app, let name):
            return "\(name) read from vault at boot by \(app)"

        case .file(let host, let path):
            return "\(path) on \(host), mode 600"
        }
    }

    /// Whether this holder needs a restart before it reads the new value.
    ///
    /// `roostrc` and `file` are the two that do not. Both are read fresh on each use, so the next read already
    /// carries the new value and there is nothing to stop.
    public var restarts: Bool {
        switch self {
        case .roostrc, .file: return false
        case .dokkuConfig, .launchdEnvironment, .systemdEnvironment, .vaultSecret: return true
        }
    }

    /// What this holder restarts, for a person reading the plan. Empty when it restarts nothing.
    public var restartLabel: String {
        switch self {
        case .dokkuConfig(let app, _, let restart):
            return "\(app), \(restart.label)"

        case .roostrc, .file:
            return ""

        case .launchdEnvironment(let host, let label, _):
            return "\(label) on \(host), bootstrapped again"

        case .systemdEnvironment(let host, let unit, _):
            return "\(unit) on \(host), started again"

        case .vaultSecret(let app, _):
            return "\(app), so it reads the new value from vault"
        }
    }

    /// The thing outside the kind file this holder names: a dokku app, a box, or a vault app.
    public var target: Target {
        switch self {
        case .dokkuConfig(let app, _, _): return .dokkuApp(app)
        case .roostrc(let host, _): return .host(host)
        case .launchdEnvironment(let host, _, _): return .host(host)
        case .systemdEnvironment(let host, _, _): return .host(host)
        case .vaultSecret(let app, _): return .vaultApp(app)
        case .file(let host, _): return .host(host)
        }
    }

    /// What a holder names, and therefore what has to be known before the value is turned over.
    ///
    /// - `dokkuApp`: a service the manifest declares.
    /// - `host`: a box the manifest or the host registry knows.
    /// - `vaultApp`: an app in vault, which the manifest never knows and never has to.
    public enum Target: Sendable, Equatable {
        case dokkuApp(String)
        case host(String)
        case vaultApp(String)
    }
}

extension KindFile.Restart {
    /// The words a person reads, rather than the case name.
    public var label: String {
        switch self {
        case .rolling: return "rolling deploy"
        case .stopStart: return "stop then start"
        }
    }
}

// MARK: - The plan

/// One rotation, resolved against the manifest and ready to print or to run.
///
/// `keys` is usually one key. It is two for the forge's S3 pair, where one issuer answers for both halves,
/// so the plan replaces them together rather than issuing twice.
public struct RotationPlan: Sendable, Equatable {
    public var service: String
    public var keys: [String]
    public var rotation: KindFile.Rotation
    /// The class the keys declare, or `nil` when it is owed, which the planner refuses.
    public var secretClass: SecretClass?
    /// Whether the receiver takes a list, so the new value overlaps the old until every holder has moved.
    public var list: Bool

    /// The holders that restart something, in the order their restarts run.
    public var restarting: [KindFile.Holder] {
        self.rotation.holders.filter(\.restarts)
    }

    public init(
        service: String, keys: [String], rotation: KindFile.Rotation, secretClass: SecretClass? = nil, list: Bool = false
    ) {
        self.service = service
        self.keys = keys
        self.rotation = rotation
        self.secretClass = secretClass
        self.list = list
    }

    /// The plan for a group of keys, with the class and the list flag the kind file declares for them.
    public init(service: String, keys: [String], rotation: KindFile.Rotation, in kind: KindFile) {
        self.init(
            service: service,
            keys: keys,
            rotation: rotation,
            secretClass: kind.secretClass(forKeys: keys),
            list: kind.takesList(keys: keys))
    }

    /// The line a list receiver's plan prints, and a refused one too, so the recipe a person follows keeps the overlap.
    static let overlapLine = "    overlaps the new value joins the list, every holder moves, then the old value leaves it"

    /// The plan's one key, for an issuer that answers one value.
    ///
    /// Only the S3 pair carries two keys, and only `vaultS3Key` issues for it. Any other issuer holding two
    /// keys is a declaration that says one value belongs in two places, which is not a thing hatchery invents.
    public func singleKey() throws -> String {
        guard self.keys.count == 1, let key = self.keys.first else {
            throw RotationExecutorError.notASingleKey(keys: self.keys)
        }
        return key
    }

    /// The plan as printed: the class with its check and its run, then the issuer, the holders and the restarts in the ruled order.
    ///
    /// The order is the whole point of printing it. A value reissued elsewhere rotates issuer first, then the
    /// config, then the restart, and a reader who cannot see that order cannot check the plan against the rule.
    public func lines() -> [String] {
        var lines = ["  \(self.keys.joined(separator: " + "))"]
        if let secretClass = self.secretClass {
            lines.append("    class    \(secretClass.rawValue)")
            lines.append("    before   \(secretClass.checkLabel)")
            lines.append("    runs     \(secretClass.runLabel)")
        }
        if self.list {
            lines.append(Self.overlapLine)
        }
        lines.append("    issues   \(self.rotation.issuer.label(service: self.service))")
        for holder in self.rotation.holders {
            lines.append("    holds    \(holder.label)")
        }
        if self.restarting.isEmpty {
            lines.append("    restarts nothing")
        } else {
            for holder in self.restarting {
                lines.append("    restarts \(holder.restartLabel)")
            }
        }
        if self.secretClass == .token {
            lines.append("    checks   \(self.rotation.issuer.checkLabel(service: self.service))")
            lines.append("    revokes  \(self.rotation.issuer.revokeLabel)")
        }
        return lines
    }
}

/// The way `hatchery secrets rotate` refuses to go on.
///
/// - `noKindFile`: the service's kind declares nothing, so there is no rotation to read.
/// - `notRotatable`: the named key is not a secret with a declared rotation.
/// - `nothingRotatable`: the service declares no rotatable secret at all.
/// - `unknownHolder`: a holder names something the manifest does not know, so the value would be turned over
///   while one bearer of it was never told.
/// - `manualIssuer`: only a person can issue this value. The recipe is the answer, and the run stops.
/// - `noVaultSession`: this machine holds no vault credential, and a vault issuer needs one.
/// - `noClass`: the key declares no class, so no check and no run shape apply. Nothing guesses one from the name.
/// - `noResealRoute`: a sealing key with no declared re-seal route. A mint and place would lock everything sealed under the old value.
/// - `address`: an address is renamed by a person on the device, by the recipe.
public enum RotationRefusal: Error, CustomStringConvertible, Equatable {
    case noKindFile(service: String, kind: String)
    case notRotatable(key: String, service: String, rotatable: [String])
    case nothingRotatable(service: String)
    case unknownHolder(key: String, holder: String, missing: String)
    case manualIssuer(keys: [String], recipe: String)
    case noVaultSession
    case noClass(keys: [String])
    case noResealRoute(keys: [String], recipe: String?)
    case address(keys: [String], recipe: String?)

    public var description: String {
        switch self {
        case .noClass(let keys):
            return "\(keys.joined(separator: " + ")) declares no class, so it cannot run; declare one of "
                + SecretClass.allCases.map(\.rawValue).joined(separator: ", ") + " in the kind file as class"

        case .noResealRoute(let keys, let recipe):
            return "\(keys.joined(separator: " + ")) is a sealingKey and declares no re-seal route, so it is never minted and placed; "
                + "a new value would lock everything sealed under the old one. The re-seal route is house#45. The recipe:\n"
                + "    \(recipe ?? "none declared")"

        case .address(let keys, let recipe):
            return "\(keys.joined(separator: " + ")) is an address, and a person renames it on the device. The recipe:\n"
                + "    \(recipe ?? "none declared")"

        case .noKindFile(let service, let kind):
            return "\(service) declares kind '\(kind)', and the registry beside the manifest holds no file for it"

        case .notRotatable(let key, let service, let rotatable):
            let known = rotatable.isEmpty ? "none" : rotatable.joined(separator: ", ")
            return "\(service) declares no rotation for \(key); it declares one for: \(known)"

        case .nothingRotatable(let service):
            return "\(service) declares no secret with a rotation, so there is nothing to rotate"

        case .unknownHolder(let key, let holder, let missing):
            return "\(key) names the holder '\(holder)', and \(missing) is not in the manifest; "
                + "a holder nothing can reach is a bearer that keeps the old value after the new one is issued"

        case .manualIssuer(let keys, let recipe):
            return "\(keys.joined(separator: " + ")) is issued by a person, not by hatchery. The recipe:\n"
                + "    \(recipe)"

        case .noVaultSession:
            return "This machine holds no vault credential, and vault's admin routes need one.\n"
                + "    " + VaultAdminCredential.recipe
        }
    }
}

/// Reads a service's declared rotations and resolves them against the manifest.
///
/// The resolving is the reason this is a step of its own. A rotation names holders by app and by box, and a
/// holder the manifest does not know is a bearer nothing will tell, which is exactly the outage the
/// declaration promised would not happen. So the check runs before the issuer does, never after.
public enum RotationPlanner {
    /// The plans for the named keys, or for every rotatable key when none are named.
    ///
    /// `apps` and `hosts` are what the manifest knows, passed in rather than read here, so a plan is the same
    /// on any machine and a test needs no manifest on disk.
    public static func plans(
        service: String,
        keys: [String],
        in kind: KindFile,
        apps: Set<String>,
        hosts: Set<String>
    ) throws -> [RotationPlan] {
        let groups = kind.rotationGroups()
        guard !groups.isEmpty else { throw RotationRefusal.nothingRotatable(service: service) }

        let wanted: [(keys: [String], rotation: KindFile.RotationDeclaration)]
        if keys.isEmpty {
            wanted = groups
        } else {
            let rotatable = kind.rotatableKeys()
            for key in keys where !rotatable.contains(key) {
                throw RotationRefusal.notRotatable(key: key, service: service, rotatable: rotatable)
            }
            // A named half of the forge's pair brings its other half with it, because one issuer answers for
            // both and replacing one alone would leave the app with half a key.
            wanted = groups.filter { group in group.keys.contains { keys.contains($0) } }
        }

        // A key another service owns names no issuer of its own here, so it builds no plan; ``owned(keys:in:)``
        // is where a caller reads it instead.
        let plans = wanted.compactMap { group -> RotationPlan? in
            guard case .declared(let rotation) = group.rotation else { return nil }
            return RotationPlan(service: service, keys: group.keys, rotation: rotation, in: kind)
        }
        for plan in plans {
            try Self.check(plan, apps: apps, hosts: hosts)
        }
        return plans
    }

    /// The named keys, or every rotatable key when none are named, that this service does not run itself
    /// because another service's rotation turns them over.
    ///
    /// `rotate` reads this to print where a key is held instead of planning it, and `rotate --all` reads it to
    /// leave the key for its owner's own run rather than counting it here too.
    public static func owned(keys: [String], in kind: KindFile) -> [(keys: [String], owner: String)] {
        let groups = kind.rotationGroups()
        let matching = keys.isEmpty ? groups : groups.filter { group in group.keys.contains { keys.contains($0) } }
        return matching.compactMap { group in
            guard case .owned(let owner) = group.rotation else { return nil }
            return (keys: group.keys, owner: owner)
        }
    }

    /// Refuses a plan hatchery must not run: a class owed, a class that never runs by a mint, a manual issuer, or a holder
    /// nothing can reach.
    ///
    /// The class is checked first, then the manual issuer. Each answer carries a recipe, and a complaint about a holder
    /// would bury it.
    static func check(_ plan: RotationPlan, apps: Set<String>, hosts: Set<String>) throws {
        switch plan.secretClass {
        case nil:
            throw RotationRefusal.noClass(keys: plan.keys)

        case .sealingKey?:
            // No issuer type is a re-seal route yet, so every sealing key is refused here until house#45 declares one.
            throw RotationRefusal.noResealRoute(keys: plan.keys, recipe: plan.rotation.issuer.recipe)

        case .address?:
            throw RotationRefusal.address(keys: plan.keys, recipe: plan.rotation.issuer.recipe)

        case .token?, .sharedKey?, .password?:
            break
        }
        if case .manual(let recipe) = plan.rotation.issuer {
            throw RotationRefusal.manualIssuer(keys: plan.keys, recipe: recipe)
        }
        for holder in plan.rotation.holders {
            switch holder.target {
            case .dokkuApp(let app) where !apps.contains(app):
                throw RotationRefusal.unknownHolder(
                    key: plan.keys.joined(separator: " + "), holder: holder.label,
                    missing: "the app \(app)")

            case .host(let host) where !hosts.contains(host):
                throw RotationRefusal.unknownHolder(
                    key: plan.keys.joined(separator: " + "), holder: holder.label,
                    missing: "the host \(host)")

            case .dokkuApp, .host, .vaultApp:
                continue
            }
        }
    }

    /// Every service name in every stack of every manifest, which is what a `dokkuConfig` holder must name.
    public static func apps(in manifests: [StackManifest]) -> Set<String> {
        Set(manifests.flatMap { $0.stacks.flatMap { $0.services.map(\.name) } })
    }

    /// Every box a manifest knows, by saved name and by address, which is what a host holder must name.
    public static func hosts(in manifests: [StackManifest]) -> Set<String> {
        var known: Set<String> = []
        for manifest in manifests {
            for (name, target) in manifest.savedHosts {
                known.insert(name)
                known.insert(target)
            }
            for stack in manifest.stacks {
                guard let host = stack.host, !host.isEmpty else { continue }
                known.insert(host)
            }
        }
        for entry in RoostHosts.hosts() {
            known.insert(entry.name)
            known.insert(entry.target)
        }
        return known
    }
}

// MARK: - Rotating every service at once

/// One service's kind file, with the wiring `rotate --all` needs to run it: the same box map and secrets file
/// a single `rotate` resolves per service, named up front so the runner itself never touches a manifest.
public struct RotationTarget: Sendable {
    public var stack: String
    public var service: String
    public var kind: KindFile
    public var dokkuTargets: [String: String]
    public var adminTargets: [String: String]
    public var secretsURL: URL
    /// The keys this service's config and secrets files declare, or `nil` when the caller did not read them.
    ///
    /// A kind file serves every service of its kind, and a job kind serves every job in a stack, so a rotation it
    /// declares is planned for a service only when that service carries the key. With `nil` every declared
    /// rotation is planned, which is what a test with no sidecar wants.
    public var carried: Set<String>?

    public init(
        stack: String, service: String, kind: KindFile,
        dokkuTargets: [String: String], adminTargets: [String: String], secretsURL: URL,
        carried: Set<String>? = nil
    ) {
        self.stack = stack
        self.service = service
        self.kind = kind
        self.dokkuTargets = dokkuTargets
        self.adminTargets = adminTargets
        self.secretsURL = secretsURL
        self.carried = carried
    }
}

/// What `rotate --all` did with one service's one rotation, for the table the run ends on.
///
/// - `run`: the executor finished every step.
/// - `refused`: a manual issuer or an unreachable holder stopped this key before it started, and the run
///   moved on to the next one.
/// - `failed`: the executor stopped partway; the printed report says where.
/// - `dry`: `--dry-run`, or `--yes` was not given, so the plan printed and nothing ran.
/// - `skipped`: another service owns this key's rotation, so it did not run here.
public struct RotationOutcome: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case run, refused, failed, dry, skipped
    }

    public var stack: String
    public var service: String
    public var keys: [String]
    public var state: State

    public init(stack: String, service: String, keys: [String], state: State) {
        self.stack = stack
        self.service = service
        self.keys = keys
        self.state = state
    }

    /// The one line this outcome contributes to the table `rotate --all` ends on: the service, the key, and
    /// the state, never the value.
    var line: String {
        "  \(self.stack)/\(self.service) \(self.keys.joined(separator: " + "))  \(self.state.rawValue)"
    }
}

/// Plans and runs every declared rotation of every target, issuer then holders then restarts, exactly as one
/// rotation runs today.
public enum RotationRun {
    /// A manual issuer or an unreachable holder refuses that one key and the run goes on to the next; a key
    /// another service owns is skipped, because its rotation runs once, under that service, and never here.
    /// The lines a person reads print as each key finishes, and the outcomes are handed back for the table
    /// that ends the run.
    public static func all(
        targets: [RotationTarget],
        apps: Set<String>,
        hosts: Set<String>,
        dryRun: Bool,
        yes: Bool,
        makeExecutor: @Sendable (RotationTarget) -> RotationExecutor,
        probe: CommandRunner? = nil,
        say: @Sendable (String) -> Void = { _ in }
    ) async -> RotationRunResult {
        var lines: [String] = []
        var outcomes: [RotationOutcome] = []
        // Every line is said the moment it is made, and kept for the caller. A run that is killed then leaves
        // every finished step on the screen, which the run of 2026-09-27 did not.
        func tell(_ line: String) {
            lines.append(line)
            say(line)
        }

        // The plans a run would execute, so the preflight probes every host they reach before the first issuer runs.
        var planned: [(RotationTarget, RotationPlan)] = []
        for target in targets {
            for group in target.kind.rotationGroups() {
                if let carried = target.carried, !group.keys.contains(where: { carried.contains($0) }) { continue }
                guard case .declared(let rotation) = group.rotation else { continue }
                let plan = RotationPlan(service: target.service, keys: group.keys, rotation: rotation, in: target.kind)
                guard (try? RotationPlanner.check(plan, apps: apps, hosts: hosts)) != nil else { continue }
                planned.append((target, plan))
            }
        }
        var silent: [String] = []
        if let probe {
            let probes = RotationPreflight.probes(of: planned.map { ($0.1, $0.0.dokkuTargets, $0.0.adminTargets) })
            silent = await RotationPreflight.silent(probes, run: probe)
            for host in silent {
                tell("  \(host) did not answer, so nothing is minted for a holder on it")
            }
            if !silent.isEmpty, yes, !dryRun {
                tell("  refused: a rotation mints nothing while a holder cannot be reached")
                return RotationRunResult(lines: lines, outcomes: [], silent: silent)
            }
        }

        for target in targets {
            for group in target.kind.rotationGroups() {
                // A kind shared by several services declares the key once, and only the services that carry it
                // are held to it. On 2026-09-23 the air job kind planned the serve token nine times, once per job.
                if let carried = target.carried, !group.keys.contains(where: { carried.contains($0) }) { continue }
                let heading = "  \(target.stack)/\(target.service) \(group.keys.joined(separator: " + "))"
                let classLine = "    class    \(target.kind.secretClass(forKeys: group.keys)?.rawValue ?? "owed")"

                switch group.rotation {
                case .owned(let owner):
                    tell(heading)
                    tell(classLine)
                    tell("    held from \(owner)")
                    outcomes.append(
                        RotationOutcome(
                            stack: target.stack, service: target.service, keys: group.keys, state: .skipped))

                case .declared(let rotation):
                    let plan = RotationPlan(service: target.service, keys: group.keys, rotation: rotation, in: target.kind)
                    do {
                        try RotationPlanner.check(plan, apps: apps, hosts: hosts)
                    } catch {
                        tell(heading)
                        tell(classLine)
                        if plan.list { tell(RotationPlan.overlapLine) }
                        tell("    refused  \(error)")
                        outcomes.append(
                            RotationOutcome(
                                stack: target.stack, service: target.service, keys: group.keys, state: .refused))
                        continue
                    }

                    guard yes, !dryRun else {
                        plan.lines().forEach(tell)
                        outcomes.append(
                            RotationOutcome(
                                stack: target.stack, service: target.service, keys: group.keys, state: .dry))
                        continue
                    }

                    let report = await makeExecutor(target).execute(plan)
                    report.lines().forEach(tell)
                    outcomes.append(
                        RotationOutcome(
                            stack: target.stack, service: target.service, keys: group.keys,
                            state: report.succeeded ? .run : .failed))
                }
            }
        }

        outcomes.map(\.line).forEach(tell)
        return RotationRunResult(lines: lines, outcomes: outcomes, silent: silent)
    }
}

/// What `rotate --all` did: every line it said, one outcome per key, and the hosts the preflight found silent.
public struct RotationRunResult: Sendable {
    public var lines: [String]
    public var outcomes: [RotationOutcome]
    public var silent: [String]

    public init(lines: [String], outcomes: [RotationOutcome], silent: [String]) {
        self.lines = lines
        self.outcomes = outcomes
        self.silent = silent
    }
}

// MARK: - The preflight

/// The hosts a set of plans reaches, and the check each plan's class makes, probed before any issuer runs.
///
/// A rotation that mints and then cannot deliver leaves a value in vault that no holder has. On 2026-09-27 a run
/// from a Mac off the home network did exactly that for two keys, because the planner checks the manifest and not
/// the network. So every distinct host a plan's holders and restarts reach is asked once, before the first mint, and
/// one silent host refuses the whole run.
/// The class adds its own check, house#56: a token's issuer answers, a password's database answers, and vault answers for a shared key it holds.
public enum RotationPreflight {
    /// One probe per host or per check: what to run, and the name a person reads when it fails.
    public struct Probe: Sendable, Equatable {
        public var host: String
        public var command: [String]
    }

    /// The distinct probes for these plans. `local` and its spellings are this machine, and no host probe asks it.
    /// A dokku target runs only dokku commands, so it is asked its `version`; a shell host is asked for `true`.
    public static func probes(
        of plans: [(RotationPlan, [String: String], [String: String])],
        vault: String = VaultAdmin.defaultBaseURL
    ) -> [Probe] {
        var seen: Set<String> = []
        var out: [Probe] = []
        func add(_ name: String, _ command: [String]) {
            guard !seen.contains(name) else { return }
            seen.insert(name)
            out.append(Probe(host: name, command: command))
        }
        func addHost(_ host: String, _ command: [String]) {
            guard !AdminChannel.isLocal(host) else { return }
            add(host, command)
        }
        for (plan, dokkuTargets, adminTargets) in plans {
            // The class check: what must answer before anything is minted.
            switch plan.rotation.issuer {
            case .postgresRole(let server, _):
                let admin = adminTargets[server] ?? server
                add("the database \(server) on \(admin)", Self.databaseProbe(server: server, on: admin))

            case .vaultAppKey, .vaultS3Key, .vaultSecret:
                add("vault at \(vault)", Self.vaultProbe(vault))

            case .random, .manual:
                break
            }

            for holder in plan.rotation.holders {
                switch holder {
                case .dokkuConfig(let app, _, _):
                    if let target = dokkuTargets[app] { addHost(target, Self.dokkuProbe(target)) }
                case .roostrc(let host, _), .launchdEnvironment(let host, _, _), .systemdEnvironment(let host, _, _),
                    .file(let host, _):
                    addHost(host, Self.shellProbe(host))
                case .vaultSecret:
                    add("vault at \(vault)", Self.vaultProbe(vault))
                }
            }
        }
        return out
    }

    /// Runs every probe through `run`, and answers the hosts that failed, in probe order.
    public static func silent(_ probes: [Probe], run: CommandRunner) async -> [String] {
        var silent: [String] = []
        for probe in probes {
            do {
                _ = try await run(probe.command)
            } catch {
                silent.append(probe.host)
            }
        }
        return silent
    }

    static func shellProbe(_ host: String) -> [String] {
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", host, "true"]
    }

    static func dokkuProbe(_ target: String) -> [String] {
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", target, "version"]
    }

    /// Asks the postgres server whether it takes connections, over the same `docker exec` channel the role change uses.
    static func databaseProbe(server: String, on target: String) -> [String] {
        let hop = AdminChannel.isLocal(target) ? [] : ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", target]
        return hop + ["docker", "exec", server, "pg_isready", "-U", "postgres"]
    }

    /// Asks vault's health route for a 2xx answer, through curl, so the probe runs through the same runner as the host probes.
    static func vaultProbe(_ baseURL: String) -> [String] {
        ["curl", "-fsS", "-o", "/dev/null", "--max-time", "6", baseURL + "/health"]
    }
}

// MARK: - The vault session

/// The signed-in admin's `vault_session` cookie, which vault's admin routes still take.
///
/// It is read from the environment and never from an argument. An argument lands in the shell history and in
/// `ps`, where every account on the machine reads it, which is the house pattern `rookery-vault-key` set.
/// It is the last door ``VaultAdminCredential`` tries, so a person who already has a session keeps working.
public enum VaultSession {
    public static let variable = "VAULT_SESSION"

    /// The session, or `nil` when the environment carries none or carries an empty one.
    public static func read(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let value = environment[Self.variable] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension KindFile.Issuer {
    /// Whether this issuer goes through vault's admin routes, and therefore needs a session.
    public var needsVaultSession: Bool {
        switch self {
        case .vaultAppKey, .vaultS3Key, .vaultSecret: return true
        case .postgresRole, .random, .manual: return false
        }
    }
}

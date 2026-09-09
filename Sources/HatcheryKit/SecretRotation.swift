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
        }
    }

    /// Whether this holder needs a restart before it reads the new value.
    ///
    /// `roostrc` is the one that does not. A tool reads that file on each run, so the next run has the new
    /// value and there is nothing to stop.
    public var restarts: Bool {
        switch self {
        case .roostrc: return false
        case .dokkuConfig, .launchdEnvironment, .systemdEnvironment, .vaultSecret: return true
        }
    }

    /// What this holder restarts, for a person reading the plan. Empty when it restarts nothing.
    public var restartLabel: String {
        switch self {
        case .dokkuConfig(let app, _, let restart):
            return "\(app), \(restart.label)"

        case .roostrc:
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

    public init(service: String, keys: [String], rotation: KindFile.Rotation) {
        self.service = service
        self.keys = keys
        self.rotation = rotation
    }

    /// The holders that restart something, in the order their restarts run.
    public var restarting: [KindFile.Holder] {
        self.rotation.holders.filter(\.restarts)
    }

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

    /// The plan as printed, in the ruled order: the issuer, then the holders, then the restarts.
    ///
    /// The order is the whole point of printing it. A value reissued elsewhere rotates issuer first, then the
    /// config, then the restart, and a reader who cannot see that order cannot check the plan against the rule.
    public func lines() -> [String] {
        var lines = ["  \(self.keys.joined(separator: " + "))"]
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
public enum RotationRefusal: Error, CustomStringConvertible, Equatable {
    case noKindFile(service: String, kind: String)
    case notRotatable(key: String, service: String, rotatable: [String])
    case nothingRotatable(service: String)
    case unknownHolder(key: String, holder: String, missing: String)
    case manualIssuer(keys: [String], recipe: String)
    case noVaultSession

    public var description: String {
        switch self {
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

        let wanted: [(keys: [String], rotation: KindFile.Rotation)]
        if keys.isEmpty {
            wanted = groups
        } else {
            for key in keys where kind.rotation(forKey: key) == nil {
                throw RotationRefusal.notRotatable(
                    key: key, service: service, rotatable: kind.rotatableKeys())
            }
            // A named half of the forge's pair brings its other half with it, because one issuer answers for
            // both and replacing one alone would leave the app with half a key.
            wanted = groups.filter { group in group.keys.contains { keys.contains($0) } }
        }

        let plans = wanted.map {
            RotationPlan(service: service, keys: $0.keys, rotation: $0.rotation)
        }
        for plan in plans {
            try Self.check(plan, apps: apps, hosts: hosts)
        }
        return plans
    }

    /// Refuses a plan hatchery must not run: a manual issuer, or a holder nothing can reach.
    ///
    /// The manual issuer is checked first. Its recipe is the useful answer, and a complaint about a holder
    /// would bury it.
    static func check(_ plan: RotationPlan, apps: Set<String>, hosts: Set<String>) throws {
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

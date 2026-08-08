import Foundation

/// One service's database, as a clone will create it.
///
/// The shape is read from the source service rather than declared anywhere: the tofu files
/// deliberately do not model the database (`mwlab.tf` says so in its header), and the manifest
/// has no db block. What the source's live config points at *is* the topology — same server,
/// its own database or a shared one — and the clone mirrors exactly that, the way a managed
/// provider would hand a new database on the same cluster.
public struct DatabaseClonePlan: Sendable, Equatable {
    /// The postgres dokku app the source connects to. On the shared docker network the app's
    /// name is also its hostname, which is what makes it both address and ssh-reachable target.
    public let serverApp: String
    public let port: String
    /// The scheme the source's URL used, kept so the clone's URL parses the same way.
    public let scheme: String
    public let database: String
    /// The role that owns the database — the `DATABASE_USER` / `DATABASE_URL` identity.
    public let owner: String
    /// The reduced-privilege role behind `DATABASE_APP_URL`, when the source has one.
    public let appUser: String?
    /// The config keys this plan will emit, copied from which style the source carried.
    public let emitted: Set<String>

    public init(
        serverApp: String, port: String, scheme: String, database: String, owner: String,
        appUser: String?, emitted: Set<String>
    ) {
        self.serverApp = serverApp
        self.port = port
        self.scheme = scheme
        self.database = database
        self.owner = owner
        self.appUser = appUser
        self.emitted = emitted
    }

    /// Two services pointing at the same database must provision it once and share the
    /// credentials, or the second service's minting locks the first one out.
    public var identity: String { "\(serverApp):\(port)/\(database)" }

    /// What one sentence in a plan display should say this will do.
    public var summary: String {
        "database \(database) on \(serverApp), minted credentials, created with the clone"
    }

    /// The config values this database resolves, once its credentials exist.
    public func values(_ credentials: DatabaseCredentials) -> [String: String] {
        var out: [String: String] = [:]
        let base = "\(scheme)://\(owner):\(credentials.ownerPassword)@\(serverApp):\(port)/\(database)"
        if emitted.contains("DATABASE_URL") { out["DATABASE_URL"] = base }
        if emitted.contains("DATABASE_OWNER_URL") { out["DATABASE_OWNER_URL"] = base }
        if let appUser, let appPassword = credentials.appPassword {
            if emitted.contains("DATABASE_APP_URL") {
                out["DATABASE_APP_URL"] =
                    "\(scheme)://\(appUser):\(appPassword)@\(serverApp):\(port)/\(database)"
            }
            if emitted.contains("DATABASE_APP_USER") { out["DATABASE_APP_USER"] = appUser }
            if emitted.contains("DATABASE_APP_PASSWORD") {
                out["DATABASE_APP_PASSWORD"] = appPassword
            }
        }
        if emitted.contains("DATABASE_HOST") { out["DATABASE_HOST"] = serverApp }
        if emitted.contains("DATABASE_PORT") { out["DATABASE_PORT"] = port }
        if emitted.contains("DATABASE_USER") { out["DATABASE_USER"] = owner }
        if emitted.contains("DATABASE_PASSWORD") { out["DATABASE_PASSWORD"] = credentials.ownerPassword }
        if emitted.contains("DATABASE_DB") { out["DATABASE_DB"] = database }
        return out
    }
}

/// The passwords a provisioning run minted (or re-minted) for one database.
public struct DatabaseCredentials: Sendable, Equatable {
    public let ownerPassword: String
    public let appPassword: String?

    public init(ownerPassword: String, appPassword: String?) {
        self.ownerPassword = ownerPassword
        self.appPassword = appPassword
    }
}

/// Works out whether a cloned service gets a database, and what it looks like.
public enum DatabaseClonePlanner {
    /// The connection-shaped keys a plan can resolve. `STRIPE_*` and friends stay refused;
    /// this list is only what a database on the stack's own server can satisfy.
    static let plannable: Set<String> = [
        "DATABASE_URL", "DATABASE_OWNER_URL", "DATABASE_APP_URL",
        "DATABASE_HOST", "DATABASE_PORT", "DATABASE_USER", "DATABASE_PASSWORD",
        "DATABASE_DB", "DATABASE_APP_USER", "DATABASE_APP_PASSWORD",
    ]

    /// A plan, or nil with the reason the keys must stay with a person.
    ///
    /// Nil is the honest answer for every case the clone cannot mirror: a backend whose
    /// database is managed elsewhere, a contract that never asks for one — not every stack
    /// has a database, and the contract already says which do — or a server address that is
    /// not a dokku app hatchery can reach (an RDS hostname has dots; `dokku enter` does not).
    public static func plan(
        service kind: ServiceKind,
        backend: Backend,
        sourceConfig: [String: String],
        source: StackSpec,
        target: String,
        environment: Environment
    ) -> DatabaseClonePlan? {
        guard backend == .dokku else { return nil }
        guard let contract = EnvContract.contract(for: kind, backend: backend) else { return nil }
        let needed = contract.required.intersection(plannable)
        guard !needed.isEmpty else { return nil }

        // The source's shape: a connection string when it has one, discrete keys otherwise.
        let url = Self.components(of: sourceConfig["DATABASE_URL"] ?? "")
        let host = url?.host ?? sourceConfig["DATABASE_HOST"] ?? ""
        let port = url?.port ?? sourceConfig["DATABASE_PORT"] ?? "5432"
        let sourceDB = url?.database ?? sourceConfig["DATABASE_DB"] ?? ""
        let sourceOwner = url?.user ?? sourceConfig["DATABASE_USER"] ?? ""
        guard !host.isEmpty, !sourceDB.isEmpty, !sourceOwner.isEmpty else { return nil }

        // A dokku app name is a bare word. Anything with a dot is an address somewhere else —
        // a managed cluster, another box — that hatchery cannot `enter` to run psql in.
        guard !host.contains("."), !host.contains("/"), !host.contains(":") else { return nil }

        let appComponents = Self.components(of: sourceConfig["DATABASE_APP_URL"] ?? "")
        let sourceApp = appComponents?.user ?? sourceConfig["DATABASE_APP_USER"] ?? ""

        // Emit every database key the source carried plus every one the contract requires,
        // so the clone's config answers both the style the contract asks for and the one the
        // running image actually reads.
        var emitted = needed
        for key in plannable where !(sourceConfig[key] ?? "").isEmpty {
            emitted.insert(key)
        }
        // An app role's keys are only emittable when there is an app role.
        let appUser: String?
        if !sourceApp.isEmpty {
            appUser = derived(sourceApp, source: source, target: target, environment: environment)
        } else if emitted.contains("DATABASE_APP_URL") {
            // The contract demands a second role the source never had; derive one beside the
            // owner rather than failing the whole plan.
            appUser = derived(sourceOwner + "_app", source: source, target: target, environment: environment)
        } else {
            appUser = nil
        }
        if appUser == nil {
            emitted.subtract(["DATABASE_APP_URL", "DATABASE_APP_USER", "DATABASE_APP_PASSWORD"])
        }

        return DatabaseClonePlan(
            serverApp: host,
            port: port,
            scheme: url?.scheme ?? "postgresql",
            database: derived(sourceDB, source: source, target: target, environment: environment),
            owner: derived(sourceOwner, source: source, target: target, environment: environment),
            appUser: appUser,
            emitted: emitted)
    }

    /// A postgres name for the clone's copy of a source-side name.
    ///
    /// The stack-name rewrite first — `mwlab_db` cloned to `mwlab-2` should say so — but the
    /// lab's names (`mwserver`, `payment_gateway`) mention no stack, so the fallback prefixes
    /// the target. Either way the result cannot collide with the source's name on the same
    /// server, which is the property that matters.
    static func derived(
        _ name: String, source: StackSpec, target: String, environment: Environment
    ) -> String {
        let rewritten = StackCloner.rewrite(name, from: source, to: target, environment: environment)
        return identifier(rewritten ?? "\(target)_\(name)")
    }

    /// Folds a name into a safe postgres identifier: the provisioner interpolates identifiers
    /// into SQL, so the fold is also what makes that interpolation safe.
    static func identifier(_ name: String) -> String {
        let folded = name.lowercased().map { character -> Character in
            (character.isASCII && (character.isLetter || character.isNumber)) || character == "_"
                ? character : "_"
        }
        var out = String(folded)
        if out.first?.isNumber == true { out = "db_" + out }
        if out.isEmpty { out = "db" }
        return String(out.prefix(63))
    }

    struct URLParts {
        let scheme: String
        let user: String?
        let host: String?
        let port: String?
        let database: String?
    }

    /// The pieces of a postgres URL the plan mirrors. The password is deliberately not read:
    /// nothing in a clone should ever want the source's.
    static func components(of value: String) -> URLParts? {
        guard !value.isEmpty, let parts = URLComponents(string: value),
            let scheme = parts.scheme, scheme.hasPrefix("postgres")
        else { return nil }
        let database = parts.path.hasPrefix("/") ? String(parts.path.dropFirst()) : parts.path
        return URLParts(
            scheme: scheme,
            user: parts.user,
            host: parts.host,
            port: parts.port.map(String.init),
            database: database.isEmpty ? nil : database)
    }
}

public enum DatabaseProvisionError: Error, CustomStringConvertible, Equatable {
    case statementFailed(sql: String, message: String)

    public var description: String {
        switch self {
        case .statementFailed(let sql, let message):
            return "database provisioning failed at `\(sql)`: \(message)"
        }
    }
}

/// Creates a plan's database and roles on the stack's postgres app, over ssh.
///
/// Every step is an assertion rather than a command: a role or database that already exists is
/// converged — password reset to the minted one, owner confirmed — not an error. Running it
/// twice lands in the same place, which is what lets a half-finished clone be re-run.
public struct DatabaseProvisioner: Sendable {
    private let run: CommandRunner
    private let mintPassword: @Sendable () -> String

    public init(
        run: @escaping CommandRunner = ShellRunner.live,
        mintPassword: @escaping @Sendable () -> String = { SecretMinter().token() }
    ) {
        self.run = run
        self.mintPassword = mintPassword
    }

    /// Asserts the plan's database, roles and grants on the box, and returns the credentials
    /// it minted plus one line per assertion for the person watching.
    public func provision(
        _ plan: DatabaseClonePlan, host: String
    ) async throws -> (credentials: DatabaseCredentials, report: [String]) {
        var report: [String] = []
        let ownerPassword = mintPassword()

        try await assertRole(
            plan.owner, password: ownerPassword, plan: plan, host: host, report: &report)

        var appPassword: String?
        if let appUser = plan.appUser {
            let minted = mintPassword()
            try await assertRole(appUser, password: minted, plan: plan, host: host, report: &report)
            appPassword = minted
        }

        do {
            _ = try await psql(
                "CREATE DATABASE \"\(plan.database)\" OWNER \"\(plan.owner)\"",
                plan: plan, host: host)
            report.append("created database \(plan.database), owner \(plan.owner)")
        } catch let failure as CommandFailure where failure.message.contains("already exists") {
            _ = try await psql(
                "ALTER DATABASE \"\(plan.database)\" OWNER TO \"\(plan.owner)\"",
                plan: plan, host: host)
            report.append("database \(plan.database) already existed; owner asserted")
        }

        if let appUser = plan.appUser {
            _ = try await psql(
                "GRANT CONNECT ON DATABASE \"\(plan.database)\" TO \"\(appUser)\"",
                plan: plan, host: host)
            _ = try await psql(
                "GRANT USAGE ON SCHEMA public TO \"\(appUser)\"",
                plan: plan, host: host, database: plan.database)
            // Tables the owner's migrations create later are readable by the app role without
            // anyone coming back to re-grant.
            _ = try await psql(
                "ALTER DEFAULT PRIVILEGES FOR ROLE \"\(plan.owner)\" IN SCHEMA public "
                    + "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"\(appUser)\"",
                plan: plan, host: host, database: plan.database)
            report.append("granted \(appUser) connect and table access on \(plan.database)")
        }

        return (DatabaseCredentials(ownerPassword: ownerPassword, appPassword: appPassword), report)
    }

    private func assertRole(
        _ role: String, password: String, plan: DatabaseClonePlan, host: String,
        report: inout [String]
    ) async throws {
        do {
            _ = try await psql(
                "CREATE ROLE \"\(role)\" LOGIN PASSWORD '\(password)'", plan: plan, host: host)
            report.append("created role \(role), minted password")
        } catch let failure as CommandFailure where failure.message.contains("already exists") {
            // Converged rather than left alone: an existing role with an unknown password is a
            // service that cannot connect, which is the exact failure this exists to prevent.
            _ = try await psql(
                "ALTER ROLE \"\(role)\" WITH LOGIN PASSWORD '\(password)'", plan: plan, host: host)
            report.append("role \(role) already existed; password re-minted")
        }
    }

    private func psql(
        _ sql: String, plan: DatabaseClonePlan, host: String, database: String? = nil
    ) async throws -> Data {
        let output: Data
        do {
            output = try await run(Self.command(sql, plan: plan, host: host, database: database))
        } catch let failure as CommandFailure {
            if failure.message.contains("already exists") { throw failure }
            throw DatabaseProvisionError.statementFailed(sql: sql, message: failure.message)
        }
        // `dokku enter` stands between psql and this process, and an exec chain that long is
        // not trusted to carry an exit status faithfully. These statements print nothing on
        // success, so an ERROR in the output is an error whatever the status said.
        let text = String(decoding: output, as: UTF8.self)
        if text.contains("ERROR:") {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("already exists") {
                throw CommandFailure(command: "psql", status: 1, message: message)
            }
            throw DatabaseProvisionError.statementFailed(sql: sql, message: message)
        }
        return output
    }

    /// The whole path from here to a psql prompt: ssh as dokku, `enter` the postgres app's
    /// running container, run psql as the in-container superuser over the local socket.
    ///
    /// The SQL travels through two shells (ssh's remote command joins arguments with spaces),
    /// so it is single-quoted for the remote one. Identifiers were folded to `[a-z0-9_]` by the
    /// planner and passwords are minted base64url, so nothing inside needs further escaping —
    /// but the quoting is done properly anyway rather than relying on that.
    static func command(
        _ sql: String, plan: DatabaseClonePlan, host: String, database: String? = nil
    ) -> [String] {
        var remote = [
            "enter", plan.serverApp, "web",
            "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-tA",
        ]
        if let database { remote += ["-d", database] }
        remote += ["-c", shellQuoted(sql)]
        return ["ssh", "-o", "BatchMode=yes", DokkuProvider.sshTarget(host)] + remote
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

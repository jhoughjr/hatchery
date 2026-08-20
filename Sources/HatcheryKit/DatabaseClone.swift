import Foundation

/// What a clone's database starts with.
///
/// The choice is the operator's, per clone: `full` is the one-click default — a clone of a
/// running stack behaves like the running stack, gateway registrations and all — until the
/// person says it should not be, which is what `schema` (tables, no rows) and `none` (empty;
/// the app's own tooling owns the schema) are for.
public enum DatabaseCloneMode: String, Sendable, Codable, CaseIterable, Equatable {
    case none
    case schema
    case full

    /// What the plan display says this mode will do.
    var carrying: String {
        switch self {
        case .none: return "created empty"
        case .schema: return "schema copied, no rows"
        case .full: return "schema and data copied"
        }
    }
}

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
    /// What the new database starts with.
    public let mode: DatabaseCloneMode
    /// The source's database, for `schema` and `full` copies.
    public let sourceDatabase: String?
    /// The server the source's database lives on — pre-rewrite, so a cross-environment
    /// clone knows its copy would have to cross servers.
    public let sourceServer: String?
    /// A managed cluster rather than a postgres app on a box. `serverApp` is then the
    /// cluster's name as the operator knows it, and the host and port the URLs need come
    /// back from provisioning, because only the platform knows them.
    public let managed: Bool

    public init(
        serverApp: String, port: String, scheme: String, database: String, owner: String,
        appUser: String?, emitted: Set<String>, mode: DatabaseCloneMode = .full,
        sourceDatabase: String? = nil, sourceServer: String? = nil, managed: Bool = false
    ) {
        self.managed = managed
        self.serverApp = serverApp
        self.port = port
        self.scheme = scheme
        self.database = database
        self.owner = owner
        self.appUser = appUser
        self.emitted = emitted
        self.mode = mode
        self.sourceDatabase = sourceDatabase
        self.sourceServer = sourceServer
    }

    /// Two services pointing at the same database must provision it once and share the
    /// credentials, or the second service's minting locks the first one out.
    public var identity: String { "\(serverApp):\(port)/\(database)" }

    /// What one sentence in a plan display should say this will do.
    public var summary: String {
        managed
            ? "database \(database) in managed cluster \(serverApp), minted credentials, \(mode.carrying)"
            : "database \(database) on \(serverApp), minted credentials, \(mode.carrying)"
    }

    /// Whether the copy stays inside one server. A same-server copy pipes inside the
    /// container; a cross-server copy needs the admin transport to bridge two containers.
    var sameServerCopy: Bool {
        sourceServer == serverApp
    }

    /// The config values this database resolves, once its credentials exist.
    public func values(_ credentials: DatabaseCredentials) -> [String: String] {
        var out: [String: String] = [:]
        // A managed cluster answers with its own host and port, and insists on TLS.
        let host = credentials.endpoint?.host ?? serverApp
        let port = credentials.endpoint?.port ?? self.port
        let query = managed ? "?sslmode=require" : ""
        let base = "\(scheme)://\(owner):\(credentials.ownerPassword)@\(host):\(port)/\(database)\(query)"
        if emitted.contains("DATABASE_URL") { out["DATABASE_URL"] = base }
        if emitted.contains("DATABASE_OWNER_URL") { out["DATABASE_OWNER_URL"] = base }
        if let appUser, let appPassword = credentials.appPassword {
            if emitted.contains("DATABASE_APP_URL") {
                out["DATABASE_APP_URL"] =
                    "\(scheme)://\(appUser):\(appPassword)@\(host):\(port)/\(database)\(query)"
            }
            if emitted.contains("DATABASE_APP_USER") { out["DATABASE_APP_USER"] = appUser }
            if emitted.contains("DATABASE_APP_PASSWORD") {
                out["DATABASE_APP_PASSWORD"] = appPassword
            }
        }
        if emitted.contains("DATABASE_HOST") { out["DATABASE_HOST"] = host }
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
    /// Where the database answers, when provisioning learned that rather than the plan
    /// knowing it: a managed cluster's host and port.
    public let endpoint: DatabaseEndpoint?

    public init(ownerPassword: String, appPassword: String?, endpoint: DatabaseEndpoint? = nil) {
        self.ownerPassword = ownerPassword
        self.appPassword = appPassword
        self.endpoint = endpoint
    }
}

public struct DatabaseEndpoint: Sendable, Equatable {
    public let host: String
    public let port: String

    public init(host: String, port: String) {
        self.host = host
        self.port = port
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
    ///
    /// `targetBackend` is where the clone will run when that differs from the source. An
    /// App Platform clone gets its database in the managed cluster `cluster` names, and the
    /// plan is nil without a cluster name, because there is nowhere else for it to go.
    public static func plan(
        service kind: ServiceKind,
        backend: Backend,
        sourceConfig: [String: String],
        source: StackSpec,
        target: String,
        environment: Environment,
        mode: DatabaseCloneMode = .full,
        targetBackend: Backend? = nil,
        cluster: String? = nil
    ) -> DatabaseClonePlan? {
        let destination = targetBackend ?? backend
        switch destination {
        case .dokku: break
        case .appPlatform:
            guard let cluster, !cluster.isEmpty else { return nil }
            return managedPlan(
                service: kind, sourceConfig: sourceConfig, source: source, target: target,
                environment: environment, cluster: cluster)
        case .aws, .cloudRun: return nil
        }
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

        // The database server is per-environment by name — mwstack-pg-dev is the dev server —
        // so a clone headed for another environment targets that environment's server, the
        // same substitution every other value gets. A server that does not exist yet fails at
        // provision time with the reason, which is better than quietly parking a staging
        // stack's data on the dev server.
        let serverApp =
            StackCloner.rewrite(host, from: source, to: target, environment: environment) ?? host

        let appComponents = Self.components(of: sourceConfig["DATABASE_APP_URL"] ?? "")
        let sourceApp = appComponents?.user ?? sourceConfig["DATABASE_APP_USER"] ?? ""

        // Role names are renamed only when the clone shares the source's server, where the
        // names would collide. On another server they are kept verbatim, because the role
        // name is part of the schema: MWServer's row-level security policies say
        // `TO mwserver_app` by name, and a renamed role restores into policies that bind
        // nothing — a clone that runs but silently answers as if logged out. One clone per
        // environment server owns those names; a second clone of the same source onto the
        // same server will re-mint their passwords and take them over.
        let crossServer = serverApp != host
        func roleName(_ name: String) -> String {
            crossServer
                ? identifier(name)
                : derived(name, source: source, target: target, environment: environment)
        }

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
            appUser = roleName(sourceApp)
        } else if emitted.contains("DATABASE_APP_URL") {
            // The contract demands a second role the source never had; derive one beside the
            // owner rather than failing the whole plan.
            appUser = roleName(sourceOwner + "_app")
        } else {
            appUser = nil
        }
        if appUser == nil {
            emitted.subtract(["DATABASE_APP_URL", "DATABASE_APP_USER", "DATABASE_APP_PASSWORD"])
        }

        return DatabaseClonePlan(
            serverApp: serverApp,
            port: port,
            scheme: url?.scheme ?? "postgresql",
            database: derived(sourceDB, source: source, target: target, environment: environment),
            owner: roleName(sourceOwner),
            appUser: appUser,
            emitted: emitted,
            mode: mode,
            sourceDatabase: sourceDB,
            sourceServer: host)
    }

    /// The plan for a database in a managed cluster.
    ///
    /// The cluster is another server by definition, so role names are kept verbatim, the
    /// same reason a cross-server dokku clone keeps them: MWServer's policies bind roles by
    /// name. The copy is `.none` for now. A managed cluster is not a container hatchery can
    /// pipe a dump into, and the trusted-source path is its own slice.
    static func managedPlan(
        service kind: ServiceKind, sourceConfig: [String: String], source: StackSpec,
        target: String, environment: Environment, cluster: String
    ) -> DatabaseClonePlan? {
        guard let contract = EnvContract.contract(for: kind, backend: .appPlatform) else { return nil }
        let needed = contract.required.intersection(plannable)
        guard !needed.isEmpty else { return nil }

        let url = Self.components(of: sourceConfig["DATABASE_URL"] ?? "")
        let sourceDB = url?.database ?? sourceConfig["DATABASE_DB"] ?? ""
        let sourceOwner = url?.user ?? sourceConfig["DATABASE_USER"] ?? ""
        guard !sourceDB.isEmpty, !sourceOwner.isEmpty else { return nil }
        let appComponents = Self.components(of: sourceConfig["DATABASE_APP_URL"] ?? "")
        let sourceApp = appComponents?.user ?? sourceConfig["DATABASE_APP_USER"] ?? ""

        // The platform contract retired the discrete keys, so only the URLs travel.
        var emitted = needed
        if !(sourceConfig["DATABASE_APP_URL"] ?? "").isEmpty { emitted.insert("DATABASE_APP_URL") }
        if !(sourceConfig["DATABASE_OWNER_URL"] ?? "").isEmpty { emitted.insert("DATABASE_OWNER_URL") }
        let appUser: String? = sourceApp.isEmpty ? nil : identifier(sourceApp)
        if appUser == nil { emitted.remove("DATABASE_APP_URL") }

        return DatabaseClonePlan(
            serverApp: cluster,
            port: "25060",
            scheme: url?.scheme ?? "postgresql",
            database: derived(sourceDB, source: source, target: target, environment: environment),
            owner: identifier(sourceOwner),
            appUser: appUser,
            emitted: emitted,
            mode: .none,
            sourceDatabase: sourceDB,
            sourceServer: url?.host ?? sourceConfig["DATABASE_HOST"],
            managed: true)
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

/// Where a service's config says its database lives, as one displayable line.
public enum DatabaseTarget {
    /// "mwserver @ mwstack-pg-dev:5432", from the connection string or the discrete keys —
    /// nil when the config names no database at all. Never includes credentials.
    public static func describe(_ config: [String: String]) -> String? {
        if let parts = DatabaseClonePlanner.components(of: config["DATABASE_URL"] ?? ""),
            let host = parts.host {
            let database = parts.database ?? "?"
            let port = parts.port.map { ":\($0)" } ?? ""
            return "\(database) @ \(host)\(port)"
        }
        let host = config["DATABASE_HOST"] ?? ""
        let database = config["DATABASE_DB"] ?? ""
        guard !host.isEmpty, !database.isEmpty else { return nil }
        let port = (config["DATABASE_PORT"] ?? "").isEmpty ? "" : ":\(config["DATABASE_PORT"]!)"
        return "\(database) @ \(host)\(port)"
    }
}

public enum DatabaseProvisionError: Error, CustomStringConvertible, Equatable {
    case statementFailed(sql: String, message: String)
    /// The server is not a dokku app and no admin target is configured to reach it another way.
    case unreachableServer(app: String, hint: String)

    public var description: String {
        switch self {
        case .statementFailed(let sql, let message):
            return "database provisioning failed at `\(Self.redacted(sql))`: \(Self.redacted(message))"
        case .unreachableServer(let app, let hint):
            return "cannot reach the database server '\(app)': \(hint)"
        }
    }

    /// A failed CREATE ROLE carries its password; an error message ends up on a terminal and
    /// in logs, which are exactly the places a password must not be.
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(
            of: "PASSWORD '[^']*'", with: "PASSWORD '\u{2026}'", options: .regularExpression)
    }
}

/// How provisioning statements reach psql on the database server.
///
/// The onboarding guide's shape — postgres as a plain dokku app — goes through `dokku enter`.
/// The lab's actual shape — postgres as a compose container dokku has never heard of — needs a
/// real shell that can `docker exec`, which is what the stack's `db_admin` setting names.
enum DatabaseTransport: Sendable, Equatable {
    case dokkuEnter
    case adminExec(String)
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
    ///
    /// `admin` is the stack's `db_admin` setting: a real shell target that can `docker exec`
    /// the database container, for the (lab's actual) case where postgres is not a dokku app.
    public func provision(
        _ plan: DatabaseClonePlan, host: String, admin: String? = nil,
        network: String? = nil
    ) async throws -> (credentials: DatabaseCredentials, report: [String]) {
        var report: [String] = []
        // The per-environment database server is hatchery's own idea, so its existence is
        // hatchery's own assertion: a clone targeting a server that does not exist yet
        // creates it — same image and network as the estate's, its own volume — instead of
        // sending a person to do it. Needs the admin channel and the stack's network;
        // without either, the old honest refusal stands.
        if let admin, let network {
            try await ensureServer(
                plan, host: host, admin: admin, network: network, report: &report)
        }
        let transport = try await chooseTransport(plan: plan, host: host, admin: admin, report: &report)
        let ownerPassword = mintPassword()

        try await assertRole(
            plan.owner, password: ownerPassword, plan: plan, host: host, via: transport,
            report: &report)

        var appPassword: String?
        if let appUser = plan.appUser {
            let minted = mintPassword()
            try await assertRole(
                appUser, password: minted, plan: plan, host: host, via: transport, report: &report)
            appPassword = minted
        }

        do {
            _ = try await psql(
                "CREATE DATABASE \"\(plan.database)\" OWNER \"\(plan.owner)\"",
                plan: plan, host: host, via: transport)
            report.append("created database \(plan.database), owner \(plan.owner)")
        } catch let failure as CommandFailure where failure.message.contains("already exists") {
            _ = try await psql(
                "ALTER DATABASE \"\(plan.database)\" OWNER TO \"\(plan.owner)\"",
                plan: plan, host: host, via: transport)
            report.append("database \(plan.database) already existed; owner asserted")
        }

        if let appUser = plan.appUser {
            _ = try await psql(
                "GRANT CONNECT ON DATABASE \"\(plan.database)\" TO \"\(appUser)\"",
                plan: plan, host: host, via: transport)
            _ = try await psql(
                "GRANT USAGE ON SCHEMA public TO \"\(appUser)\"",
                plan: plan, host: host, via: transport, database: plan.database)
            // Tables the owner's migrations create later are readable by the app role without
            // anyone coming back to re-grant.
            _ = try await psql(
                "ALTER DEFAULT PRIVILEGES FOR ROLE \"\(plan.owner)\" IN SCHEMA public "
                    + "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"\(appUser)\"",
                plan: plan, host: host, via: transport, database: plan.database)
            report.append("granted \(appUser) connect and table access on \(plan.database)")
        }

        try await copyContents(of: plan, host: host, via: transport, report: &report)

        return (DatabaseCredentials(ownerPassword: ownerPassword, appPassword: appPassword), report)
    }

    /// Fills the new database from the source's, as the mode asks.
    ///
    /// MWServer does not create its own schema at boot — the lab's databases were initialised
    /// by MacWorkStack-infra's db/init matrix — so an empty database is a running app with no
    /// tables. The dump restores as the clone's owner, so every copied object belongs to the
    /// clone's role rather than the source's.
    private func copyContents(
        of plan: DatabaseClonePlan, host: String, via transport: DatabaseTransport,
        report: inout [String]
    ) async throws {
        guard plan.mode != .none else { return }
        guard let sourceDatabase = plan.sourceDatabase else { return }
        // The dump pipeline interpolates these into a remote shell; the clone-side names were
        // folded by the planner, but the source's came from config and get checked here.
        guard Self.isPlainName(sourceDatabase), plan.sourceServer.map(Self.isPlainName) != false
        else {
            report.append(
                "\(plan.mode.rawValue) copy skipped: the source database's name is not a "
                    + "plain identifier; created empty")
            return
        }

        // The copy converges like every other step: the target schema is reset first, so a
        // re-run lands in the same place instead of tripping over a half-restored attempt —
        // a serve restart mid-restore left functions without tables, and the next copy died
        // on "already exists". This resets only the clone's own database, which hatchery
        // created moments ago; the source is never touched.
        _ = try await psql(
            "DROP SCHEMA IF EXISTS public CASCADE", plan: plan, host: host, via: transport,
            database: plan.database)
        _ = try await psql(
            "CREATE SCHEMA public", plan: plan, host: host, via: transport,
            database: plan.database)
        _ = try await psql(
            "ALTER SCHEMA public OWNER TO \"\(plan.owner)\"", plan: plan, host: host,
            via: transport, database: plan.database)

        // --no-owner AND --no-acl: the dump must carry no reference to the source's roles.
        // Ownership was handled from the start, but the ACLs slipped through — GRANTs naming
        // `mwserver_app` restored fine on the server where that role exists and killed the
        // copy on the one where it does not, which is how "0 keys needed" became 2 after
        // create. The clone's own grants are asserted after the copy; the source's are the
        // one thing that must not travel.
        let flags = plan.mode == .schema ? "--schema-only " : ""
        let restore = "psql -q -v ON_ERROR_STOP=1 -U \(plan.owner) -d \(plan.database)"
        let command: [String]
        if plan.sameServerCopy {
            let pipeline =
                "pg_dump -U postgres --no-owner --no-acl \(flags)-d \(sourceDatabase) | " + restore
            command = Self.shellCommand(pipeline, plan: plan, host: host, via: transport)
        } else if case .adminExec(let admin) = transport, let sourceServer = plan.sourceServer {
            // Two servers, one box, one admin: the dump leaves the source's container and
            // pipes straight into the target's — which is how a staging clone fills its
            // database from dev's server once staging's exists.
            let pipeline =
                "docker exec \(sourceServer) pg_dump -U postgres --no-owner --no-acl \(flags)"
                + "-d \(sourceDatabase) | docker exec -i \(plan.serverApp) " + restore
            command = ["ssh", "-o", "BatchMode=yes", admin, "sh", "-c", Self.shellQuoted(pipeline)]
        } else {
            report.append(
                "\(plan.mode.rawValue) copy skipped: the source database lives on "
                    + "\(plan.sourceServer ?? "another server") and the dokku channel cannot "
                    + "bridge servers — set db_admin to copy across them; created empty")
            return
        }

        do {
            _ = try await run(command)
        } catch let failure as CommandFailure {
            throw DatabaseProvisionError.statementFailed(
                sql: "pg_dump \(sourceDatabase) → \(plan.database)", message: failure.message)
        }

        // The schema reset above took the app role's grants and default privileges with it,
        // so every one is re-asserted over what just arrived.
        if let appUser = plan.appUser {
            _ = try await psql(
                "GRANT USAGE ON SCHEMA public TO \"\(appUser)\"",
                plan: plan, host: host, via: transport, database: plan.database)
            _ = try await psql(
                "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public "
                    + "TO \"\(appUser)\"",
                plan: plan, host: host, via: transport, database: plan.database)
            _ = try await psql(
                "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"\(appUser)\"",
                plan: plan, host: host, via: transport, database: plan.database)
            _ = try await psql(
                "ALTER DEFAULT PRIVILEGES FOR ROLE \"\(plan.owner)\" IN SCHEMA public "
                    + "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"\(appUser)\"",
                plan: plan, host: host, via: transport, database: plan.database)
        }
        let what = plan.mode == .schema ? "schema" : "schema and data"
        let whence = plan.sameServerCopy
            ? sourceDatabase : "\(sourceDatabase) on \(plan.sourceServer ?? "?")"
        report.append("\(what) copied from \(whence)")
    }

    /// A name safe to place in a remote shell pipeline: letters, digits, underscore, dash.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty
            && name.allSatisfy {
                ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" || $0 == "-"
            }
    }

    /// A shell pipeline on the database server, through whichever transport is in use — the
    /// one place a remote `sh -c` is allowed, because a dump has to pipe into a restore.
    static func shellCommand(
        _ pipeline: String, plan: DatabaseClonePlan, host: String, via transport: DatabaseTransport
    ) -> [String] {
        let remote = ["sh", "-c", shellQuoted(pipeline)]
        switch transport {
        case .dokkuEnter:
            return ["ssh", "-o", "BatchMode=yes", DokkuProvider.sshTarget(host)]
                + ["enter", plan.serverApp, "web"] + remote
        case .adminExec(let admin):
            return ["ssh", "-o", "BatchMode=yes", admin]
                + ["docker", "exec", "-i", plan.serverApp] + remote
        }
    }

    /// Whether the plan's server can be reached at all, without creating anything.
    ///
    /// For the plan screen: a staging clone targets staging's database server by name, and
    /// discovering that the server does not exist belongs on the plan — where the person
    /// still has the form in front of them — not in the wreckage after the create click.
    /// Nil when reachable; otherwise one sentence saying what to do about it.
    public func probe(
        _ plan: DatabaseClonePlan, host: String, admin: String?
    ) async -> String? {
        var report: [String] = []
        do {
            _ = try await chooseTransport(plan: plan, host: host, admin: admin, report: &report)
            return nil
        } catch {
            return "database server '\(plan.serverApp)' does not exist yet — \(error). "
                + "hatchery creates it during the clone when the stack has a docker network "
                + "and an admin channel; otherwise the database keys fall to the boot checklist."
        }
    }

    /// Creates the plan's server when the box has no such container, and waits for its
    /// postgres to answer. Convergent: an existing server is left exactly alone.
    private func ensureServer(
        _ plan: DatabaseClonePlan, host: String, admin: String, network: String,
        report: inout [String]
    ) async throws {
        do {
            _ = try await psql("SELECT 1", plan: plan, host: host, via: .adminExec(admin))
            return
        } catch let error as DatabaseProvisionError {
            // psql() wraps transport failures; unwrap to see whether this is the one
            // failure we exist to fix.
            guard case .statementFailed(_, let message) = error,
                message.contains("No such container")
            else { return }  // Anything else: chooseTransport will surface it properly.
        } catch {
            return
        }

        let create = "docker run -d --name \(plan.serverApp) --network \(network) "
            + "--restart unless-stopped -e POSTGRES_PASSWORD=\(mintPassword()) "
            + "-v \(plan.serverApp)-data:/var/lib/postgresql/data postgres:17-alpine"
        let wait = "for i in $(seq 1 30); do "
            + "docker exec \(plan.serverApp) pg_isready -h 127.0.0.1 -U postgres "
            + ">/dev/null 2>&1 && exit 0; sleep 2; done; exit 1"
        do {
            _ = try await run([
                "ssh", "-o", "BatchMode=yes", admin, "sh", "-c", Self.shellQuoted(create),
            ])
            _ = try await run([
                "ssh", "-o", "BatchMode=yes", admin, "sh", "-c", Self.shellQuoted(wait),
            ])
            report.append(
                "created database server \(plan.serverApp) on \(network) (postgres:17-alpine)")
        } catch let failure as CommandFailure {
            throw DatabaseProvisionError.statementFailed(
                sql: "create server \(plan.serverApp)", message: failure.message)
        }
    }

    /// One probe decides the road for every statement after it.
    ///
    /// `dokku enter` first, because that is the shape the onboarding guide describes. When
    /// dokku answers that the app does not exist — the lab's postgres is a compose container
    /// dokku has never heard of — the admin target takes over, probed before it is trusted.
    /// No admin configured is a sentence naming the setting, not a mystery.
    private func chooseTransport(
        plan: DatabaseClonePlan, host: String, admin: String?, report: inout [String]
    ) async throws -> DatabaseTransport {
        do {
            _ = try await psql("SELECT 1", plan: plan, host: host, via: .dokkuEnter)
            return .dokkuEnter
        } catch let error as DatabaseProvisionError {
            guard case .statementFailed(_, let message) = error,
                message.contains("does not exist")
            else { throw error }
            guard let admin, !admin.isEmpty else {
                throw DatabaseProvisionError.unreachableServer(
                    app: plan.serverApp,
                    hint: "it is not a dokku app, and the stack sets no db_admin. Set db_admin "
                        + "to a shell target that can docker-exec it (e.g. jimmy@\(bareHost(host)))")
            }
            _ = try await psql("SELECT 1", plan: plan, host: host, via: .adminExec(admin))
            report.append("reached \(plan.serverApp) via \(admin) (not a dokku app)")
            return .adminExec(admin)
        }
    }

    private func bareHost(_ host: String) -> String {
        host.split(separator: "@").last.map(String.init) ?? host
    }

    private func assertRole(
        _ role: String, password: String, plan: DatabaseClonePlan, host: String,
        via transport: DatabaseTransport, report: inout [String]
    ) async throws {
        do {
            _ = try await psql(
                "CREATE ROLE \"\(role)\" LOGIN PASSWORD '\(password)'",
                plan: plan, host: host, via: transport)
            report.append("created role \(role), minted password")
        } catch let failure as CommandFailure where failure.message.contains("already exists") {
            // Converged rather than left alone: an existing role with an unknown password is a
            // service that cannot connect, which is the exact failure this exists to prevent.
            _ = try await psql(
                "ALTER ROLE \"\(role)\" WITH LOGIN PASSWORD '\(password)'",
                plan: plan, host: host, via: transport)
            report.append("role \(role) already existed; password re-minted")
        }
    }

    private func psql(
        _ sql: String, plan: DatabaseClonePlan, host: String, via transport: DatabaseTransport,
        database: String? = nil
    ) async throws -> Data {
        let output: Data
        do {
            output = try await run(
                Self.command(sql, plan: plan, host: host, via: transport, database: database))
        } catch let failure as CommandFailure {
            if failure.message.contains("already exists") { throw failure }
            throw DatabaseProvisionError.statementFailed(sql: sql, message: failure.message)
        }
        // `dokku enter` or a docker exec stands between psql and this process, and an exec
        // chain that long is not trusted to carry an exit status faithfully. These statements
        // print nothing consequential on success, so an ERROR in the output is an error
        // whatever the status said.
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

    /// The whole path from here to a psql prompt, by transport: ssh as dokku and `enter` the
    /// postgres app, or ssh as the admin and `docker exec` the container of the same name.
    /// Either way psql runs as the in-container superuser over the local socket.
    ///
    /// The SQL travels through two shells (ssh's remote command joins arguments with spaces),
    /// so it is single-quoted for the remote one. Identifiers were folded to `[a-z0-9_]` by the
    /// planner and passwords are minted base64url, so nothing inside needs further escaping —
    /// but the quoting is done properly anyway rather than relying on that.
    static func command(
        _ sql: String, plan: DatabaseClonePlan, host: String, via transport: DatabaseTransport,
        database: String? = nil
    ) -> [String] {
        var psql = ["psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-tA"]
        if let database { psql += ["-d", database] }
        psql += ["-c", shellQuoted(sql)]

        switch transport {
        case .dokkuEnter:
            return ["ssh", "-o", "BatchMode=yes", DokkuProvider.sshTarget(host)]
                + ["enter", plan.serverApp, "web"] + psql
        case .adminExec(let admin):
            return ["ssh", "-o", "BatchMode=yes", admin]
                + ["docker", "exec", "-i", plan.serverApp] + psql
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

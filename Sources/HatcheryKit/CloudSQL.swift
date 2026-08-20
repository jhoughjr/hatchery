import Foundation

public enum CloudSQLError: Error, Equatable, CustomStringConvertible {
    case noGcloud
    case instanceNotFound(String)
    case refused(String, detail: String)

    public var description: String {
        switch self {
        case .noGcloud:
            return "gcloud is not on this machine, and Cloud SQL answers only through it: "
                + "brew install --cask google-cloud-sdk, then gcloud auth login"
        case .instanceNotFound(let name):
            return "no Cloud SQL instance named '\(name)' is visible to gcloud. "
                + "Check the name in the console, or the db_cluster setting"
        case .refused(let what, let detail):
            return "gcloud refused \(what): \(detail)"
        }
    }
}

/// Creates a plan's database and roles in a Cloud SQL Postgres instance.
///
/// Through gcloud, because Google signs its API calls in ways curl alone cannot. Two
/// differences from the DigitalOcean provisioner: Cloud SQL lets hatchery choose the
/// passwords, so it mints them, and the instance's Postgres admin credential is the
/// operator's, not hatchery's, so ownership and the app role's grants are reported as
/// pending statements rather than run. Convergent like the others: an existing database
/// is kept, an existing user gets a fresh password, and running twice lands in the same
/// place.
public struct CloudSQLProvisioner: Sendable {
    private let execute: CommandExecutor
    private let mintPassword: @Sendable () -> String

    public init(
        execute: @escaping CommandExecutor = ShellRunner.liveExecutor,
        mintPassword: @escaping @Sendable () -> String = { SecretMinter().token() }
    ) {
        self.execute = execute
        self.mintPassword = mintPassword
    }

    struct Instance: Equatable {
        let name: String
        /// project:region:instance, the name the Cloud SQL socket and proxy go by.
        let connectionName: String
        let address: String?
        let version: String
    }

    public func provision(
        _ plan: DatabaseClonePlan, admin: String? = nil
    ) async throws -> (credentials: DatabaseCredentials, report: [String]) {
        let which = try? await self.execute(["sh", "-c", "command -v gcloud"], nil)
        guard which?.status == 0 else { throw CloudSQLError.noGcloud }
        var report: [String] = []
        let instance = try await self.instance(named: plan.serverApp)
        report.append(
            "instance \(instance.name) (\(instance.version)) answers as \(instance.connectionName)"
                + (instance.address.map { " at \($0)" } ?? ", no public address"))

        // The database.
        let existing = try await self.names(
            ["sql", "databases", "list", "--instance", instance.name, "--format", "value(name)"],
            what: "list databases")
        if existing.contains(plan.database) {
            report.append("database \(plan.database) already existed")
        } else {
            try await self.gcloud(
                ["sql", "databases", "create", plan.database, "--instance", instance.name],
                what: "create database \(plan.database)")
            report.append("created database \(plan.database)")
        }

        // The roles, with passwords hatchery minted.
        let users = try await self.names(
            ["sql", "users", "list", "--instance", instance.name, "--format", "value(name)"],
            what: "list users")
        let ownerPassword = mintPassword()
        try await self.assertUser(
            plan.owner, password: ownerPassword, known: users, instance: instance, report: &report)
        var appPassword: String?
        if let appUser = plan.appUser {
            let minted = mintPassword()
            try await self.assertUser(
                appUser, password: minted, known: users, instance: instance, report: &report)
            appPassword = minted
        }

        // Ownership and grants need the instance's Postgres admin, which is the operator's.
        var statements = ["ALTER DATABASE \"\(plan.database)\" OWNER TO \"\(plan.owner)\""]
        if let appUser = plan.appUser {
            statements += [
                "GRANT CONNECT ON DATABASE \"\(plan.database)\" TO \"\(appUser)\"",
                "GRANT USAGE ON SCHEMA public TO \"\(appUser)\"",
                "ALTER DEFAULT PRIVILEGES FOR ROLE \"\(plan.owner)\" IN SCHEMA public "
                    + "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"\(appUser)\"",
            ]
        }
        report.append(
            "ownership and grants are pending: run as the postgres user of \(instance.name), "
                + "for example through gcloud sql connect \(instance.name) --user=postgres:")
        statements.forEach { report.append("  \($0);") }
        let endpoint = instance.address.map { DatabaseEndpoint(host: $0, port: "5432") }
            ?? DatabaseEndpoint(host: "/cloudsql/\(instance.connectionName)", port: "5432")
        let credentials = DatabaseCredentials(
            ownerPassword: ownerPassword, appPassword: appPassword, endpoint: endpoint)
        try await self.copyContents(
            of: plan, credentials: credentials, instance: instance, admin: admin, report: &report)
        return (credentials, report)
    }

    /// Fills the new database from the source's, as the mode asks, from the trusted source.
    ///
    /// Cloud SQL grants every user it creates the cloudsqlsuperuser role, so the clone's
    /// owner can reset its own schema and receive the dump without an admin credential.
    /// What it needs is a path: the trusted source must be an authorized network on the
    /// instance, or run the Auth Proxy, and the report says so when psql cannot connect.
    private func copyContents(
        of plan: DatabaseClonePlan, credentials: DatabaseCredentials, instance: Instance,
        admin: String?, report: inout [String]
    ) async throws {
        guard plan.mode != .none else { return }
        guard let sourceDatabase = plan.sourceDatabase, let sourceServer = plan.sourceServer
        else { return }
        guard let admin else {
            report.append(
                "\(plan.mode.rawValue) copy skipped: a copy into Cloud SQL runs from the "
                    + "source box's admin channel, and the stack has no db_admin; created empty")
            return
        }
        guard let address = instance.address else {
            report.append(
                "\(plan.mode.rawValue) copy skipped: \(instance.name) has no public address, so "
                    + "the trusted source would need the Auth Proxy; created empty")
            return
        }
        guard DatabaseProvisioner.isPlainName(sourceDatabase),
            DatabaseProvisioner.isPlainName(sourceServer)
        else {
            report.append(
                "\(plan.mode.rawValue) copy skipped: the source database or server name is "
                    + "not a plain identifier; created empty")
            return
        }
        let ownerURL = "postgresql://\(plan.owner):\(credentials.ownerPassword)@\(address):5432/\(plan.database)?sslmode=require"
        func remote(_ sql: String) async throws -> CommandOutput {
            try await self.execute(
                ["ssh", "-o", "BatchMode=yes", admin, "psql", ownerURL, "-q", "-v", "ON_ERROR_STOP=1", "-c", sql], nil)
        }

        let which = try? await self.execute(
            ["ssh", "-o", "BatchMode=yes", admin, "command", "-v", "psql"], nil)
        guard which?.status == 0 else {
            report.append(
                "\(plan.mode.rawValue) copy skipped: \(admin) has no psql to reach the instance "
                    + "with; install postgresql-client there; created empty")
            return
        }
        let reach = try await remote("SELECT 1")
        guard reach.status == 0 else {
            report.append(
                "\(plan.mode.rawValue) copy skipped: \(admin) cannot reach \(instance.name) at "
                    + "\(address). Authorize its address on the instance, gcloud sql instances "
                    + "patch \(instance.name) --authorized-networks=<its ip>/32, or run the Auth "
                    + "Proxy there; created empty")
            return
        }

        for sql in ["DROP SCHEMA IF EXISTS public CASCADE", "CREATE SCHEMA public"] {
            let output = try await remote(sql)
            guard output.status == 0 else {
                throw DatabaseProvisionError.statementFailed(sql: sql, message: output.combined)
            }
        }
        let flags = plan.mode == .schema ? "--schema-only " : ""
        let pipeline =
            "docker exec \(sourceServer) pg_dump -U postgres --no-owner --no-acl \(flags)"
            + "-d \(sourceDatabase) | psql -q -v ON_ERROR_STOP=1 '\(ownerURL)'"
        let copy = try await self.execute(
            ["ssh", "-o", "BatchMode=yes", admin, "sh", "-c", DatabaseProvisioner.shellQuoted(pipeline)], nil)
        guard copy.status == 0 else {
            throw DatabaseProvisionError.statementFailed(
                sql: "pg_dump \(sourceDatabase) → \(plan.database)",
                message: DatabaseProvisionError.redacted(copy.combined))
        }
        if let appUser = plan.appUser {
            for sql in [
                "GRANT USAGE ON SCHEMA public TO \"\(appUser)\"",
                "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"\(appUser)\"",
                "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"\(appUser)\"",
                "ALTER DEFAULT PRIVILEGES FOR ROLE \"\(plan.owner)\" IN SCHEMA public "
                    + "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"\(appUser)\"",
            ] {
                let output = try await remote(sql)
                guard output.status == 0 else {
                    throw DatabaseProvisionError.statementFailed(sql: sql, message: output.combined)
                }
            }
        }
        let what = plan.mode == .schema ? "schema" : "schema and data"
        report.append("\(what) copied from \(sourceDatabase) on \(sourceServer), through \(admin)")
    }

    func instance(named name: String) async throws -> Instance {
        let output = try await self.execute(
            ["gcloud", "sql", "instances", "describe", name, "--format", "json"], nil)
        guard output.status == 0 else {
            if output.combined.contains("NOT_FOUND") || output.combined.contains("does not exist") {
                throw CloudSQLError.instanceNotFound(name)
            }
            throw CloudSQLError.refused("describe instance \(name)", detail: output.combined)
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8))
            as? [String: Any],
            let connectionName = root["connectionName"] as? String
        else { throw CloudSQLError.refused("describe instance \(name)", detail: "not JSON") }
        let addresses = root["ipAddresses"] as? [[String: Any]] ?? []
        let primary = addresses.first { $0["type"] as? String == "PRIMARY" }?["ipAddress"] as? String
        return Instance(
            name: name, connectionName: connectionName, address: primary,
            version: root["databaseVersion"] as? String ?? "POSTGRES")
    }

    private func assertUser(
        _ user: String, password: String, known: [String], instance: Instance,
        report: inout [String]
    ) async throws {
        if known.contains(user) {
            try await self.gcloud(
                ["sql", "users", "set-password", user, "--instance", instance.name, "--password", password],
                what: "reset the password of \(user)")
            report.append("user \(user) already existed; password reset")
        } else {
            try await self.gcloud(
                ["sql", "users", "create", user, "--instance", instance.name, "--password", password],
                what: "create user \(user)")
            report.append("created user \(user)")
        }
    }

    private func names(_ args: [String], what: String) async throws -> [String] {
        let output = try await self.execute(["gcloud"] + args, nil)
        guard output.status == 0 else {
            throw CloudSQLError.refused(what, detail: output.combined)
        }
        return output.standardOutput.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private func gcloud(_ args: [String], what: String) async throws {
        let output = try await self.execute(["gcloud"] + args + ["--quiet"], nil)
        guard output.status == 0 else {
            // A password on the command line must not reach a terminal or a log.
            let detail = output.combined.replacingOccurrences(
                of: "--password[ =][^ ]+", with: "--password …", options: .regularExpression)
            throw CloudSQLError.refused(what, detail: detail)
        }
    }
}

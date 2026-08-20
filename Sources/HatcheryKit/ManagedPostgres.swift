import Foundation

public enum ManagedPostgresError: Error, Equatable, CustomStringConvertible {
    case noToken
    case clusterNotFound(String)
    case apiRefused(String, status: Int)
    case unreadable(String)

    public var description: String {
        switch self {
        case .noToken:
            return "DIGITALOCEAN_TOKEN is not set, and the managed cluster answers only to it"
        case .clusterNotFound(let name):
            return "no managed Postgres cluster named '\(name)' is visible to this token. "
                + "Check the name in the DigitalOcean console, or the db_cluster setting"
        case .apiRefused(let what, let status):
            return "the DigitalOcean API refused \(what) with HTTP \(status)"
        case .unreadable(let what):
            return "the DigitalOcean API answered \(what) with something that is not JSON"
        }
    }
}

/// Creates a plan's database and roles in a DigitalOcean managed Postgres cluster.
///
/// The cluster is not a container hatchery can `docker exec`, so everything goes through
/// the platform's API, and the platform keeps some decisions for itself: it mints the
/// passwords, and a role it creates cannot be given ownership of anything through the API.
/// So the database and the roles are asserted through the API, and the ownership and the
/// grants run as the cluster's admin over psql from this machine when psql is present. When
/// it is not, the statements are reported, not lost.
///
/// Convergent like the dokku provisioner: an existing database is kept, an existing role
/// gets its password reset to a fresh one, and running twice lands in the same place.
public struct ManagedPostgresProvisioner: Sendable {
    private let execute: CommandExecutor
    private let environment: [String: String]

    static let api = "https://api.digitalocean.com/v2"

    public init(
        execute: @escaping CommandExecutor = ShellRunner.liveExecutor,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.execute = execute
        self.environment = environment
    }

    struct Cluster: Equatable {
        let id: String
        let name: String
        let host: String
        let port: Int
        let adminUser: String
        let adminPassword: String
        let defaultDatabase: String
    }

    /// Asserts the plan's database and roles in the cluster the plan names, and returns the
    /// credentials the platform minted, with the cluster's endpoint, plus one line per step.
    public func provision(
        _ plan: DatabaseClonePlan
    ) async throws -> (credentials: DatabaseCredentials, report: [String]) {
        guard let token = self.environment["DIGITALOCEAN_TOKEN"], !token.isEmpty else {
            throw ManagedPostgresError.noToken
        }
        var report: [String] = []
        let cluster = try await self.cluster(named: plan.serverApp, token: token)
        report.append("cluster \(cluster.name) answers at \(cluster.host):\(cluster.port)")

        // The database.
        let existing = try await self.names(
            at: "databases/\(cluster.id)/dbs", key: "dbs", token: token)
        if existing.contains(plan.database) {
            report.append("database \(plan.database) already existed")
        } else {
            _ = try await self.post(
                "databases/\(cluster.id)/dbs", body: ["name": plan.database], token: token,
                what: "create database \(plan.database)")
            report.append("created database \(plan.database)")
        }

        // The roles. The platform mints the password on create, and hands out a fresh one
        // on reset, so either way the value is the platform's and never ours to choose.
        let users = try await self.names(
            at: "databases/\(cluster.id)/users", key: "users", token: token)
        let ownerPassword = try await self.assertUser(
            plan.owner, known: users, cluster: cluster, token: token, report: &report)
        var appPassword: String?
        if let appUser = plan.appUser {
            appPassword = try await self.assertUser(
                appUser, known: users, cluster: cluster, token: token, report: &report)
        }

        // Ownership and grants: the API has no verb for them, so they run as the admin.
        var statements = [
            "ALTER DATABASE \"\(plan.database)\" OWNER TO \"\(plan.owner)\""
        ]
        if let appUser = plan.appUser {
            statements += [
                "GRANT CONNECT ON DATABASE \"\(plan.database)\" TO \"\(appUser)\"",
                "GRANT USAGE ON SCHEMA public TO \"\(appUser)\"",
                "ALTER DEFAULT PRIVILEGES FOR ROLE \"\(plan.owner)\" IN SCHEMA public "
                    + "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"\(appUser)\"",
            ]
        }
        try await self.runAsAdmin(statements, in: plan.database, cluster: cluster, report: &report)

        let credentials = DatabaseCredentials(
            ownerPassword: ownerPassword, appPassword: appPassword,
            endpoint: DatabaseEndpoint(host: cluster.host, port: String(cluster.port)))
        return (credentials, report)
    }

    // MARK: the cluster

    func cluster(named name: String, token: String) async throws -> Cluster {
        let body = try await self.get("databases", token: token, what: "list clusters")
        guard let root = body as? [String: Any],
            let clusters = root["databases"] as? [[String: Any]]
        else { throw ManagedPostgresError.unreadable("list clusters") }
        for entry in clusters {
            guard entry["name"] as? String == name, entry["engine"] as? String == "pg",
                let id = entry["id"] as? String,
                let connection = entry["connection"] as? [String: Any],
                let host = connection["host"] as? String
            else { continue }
            return Cluster(
                id: id, name: name, host: host,
                port: connection["port"] as? Int ?? 25060,
                adminUser: connection["user"] as? String ?? "doadmin",
                adminPassword: connection["password"] as? String ?? "",
                defaultDatabase: connection["database"] as? String ?? "defaultdb")
        }
        throw ManagedPostgresError.clusterNotFound(name)
    }

    private func assertUser(
        _ user: String, known: [String], cluster: Cluster, token: String,
        report: inout [String]
    ) async throws -> String {
        let path = "databases/\(cluster.id)/users"
        let answer: Any
        if known.contains(user) {
            answer = try await self.post(
                "\(path)/\(user)/reset_auth", body: [:], token: token,
                what: "reset the password of \(user)")
            report.append("role \(user) already existed; password reset")
        } else {
            answer = try await self.post(
                path, body: ["name": user], token: token, what: "create role \(user)")
            report.append("created role \(user)")
        }
        guard let root = answer as? [String: Any], let entry = root["user"] as? [String: Any],
            let password = entry["password"] as? String, !password.isEmpty
        else { throw ManagedPostgresError.unreadable("the password of \(user)") }
        return password
    }

    private func runAsAdmin(
        _ statements: [String], in database: String, cluster: Cluster, report: inout [String]
    ) async throws {
        let which = try? await self.execute(["sh", "-c", "command -v psql"], nil)
        guard which?.status == 0 else {
            report.append("psql is not on this machine, so the grants are pending. Run as \(cluster.adminUser):")
            statements.forEach { report.append("  \($0);") }
            return
        }
        for (index, sql) in statements.enumerated() {
            // The first statement changes the owner and runs against the admin's database.
            // The rest are grants inside the new database.
            let target = index == 0 ? cluster.defaultDatabase : database
            let url = "postgresql://\(cluster.adminUser):\(cluster.adminPassword)@\(cluster.host):\(cluster.port)/\(target)?sslmode=require"
            let output = try await self.execute(
                ["psql", url, "-v", "ON_ERROR_STOP=1", "-qAt", "-c", sql], nil)
            guard output.status == 0 else {
                throw DatabaseProvisionError.statementFailed(
                    sql: sql, message: output.combined)
            }
        }
        report.append("owner and grants asserted as \(cluster.adminUser)")
    }

    // MARK: the wire

    private func names(at path: String, key: String, token: String) async throws -> [String] {
        let body = try await self.get(path, token: token, what: "list \(key)")
        guard let root = body as? [String: Any], let rows = root[key] as? [[String: Any]] else {
            throw ManagedPostgresError.unreadable("list \(key)")
        }
        return rows.compactMap { $0["name"] as? String }
    }

    private func get(_ path: String, token: String, what: String) async throws -> Any {
        try await self.call(["-X", "GET"], path: path, token: token, what: what)
    }

    private func post(
        _ path: String, body: [String: String], token: String, what: String
    ) async throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await self.call(
            ["-X", "POST", "-H", "Content-Type: application/json",
             "-d", String(decoding: data, as: UTF8.self)],
            path: path, token: token, what: what)
    }

    /// One API call through curl. The status code rides on the last line of stdout, so a
    /// refusal is told apart from a body that merely fails to parse.
    private func call(
        _ method: [String], path: String, token: String, what: String
    ) async throws -> Any {
        let argv = ["curl", "-sS", "--max-time", "30", "-w", "\n%{http_code}",
                    "-H", "Authorization: Bearer \(token)"] + method
            + ["\(Self.api)/\(path)"]
        let output = try await self.execute(argv, nil)
        var lines = output.standardOutput.split(separator: "\n", omittingEmptySubsequences: false)
        let status = Int(lines.popLast()?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        guard (200..<300).contains(status) else {
            throw ManagedPostgresError.apiRefused(what, status: status)
        }
        let body = lines.joined(separator: "\n")
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else {
            throw ManagedPostgresError.unreadable(what)
        }
        return parsed
    }
}

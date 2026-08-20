import Foundation
import Testing

@testable import HatcheryKit

@Suite("A clone's database in a managed cluster")
struct ManagedPostgresTests {
    private let source = StackSpec(
        name: "mwlab", backend: .dokku, host: "dokku@192.168.0.103", settings: ["db_cluster": "mws-pg"])
    private let config = [
        "DATABASE_URL": "postgresql://mwserver:old@mwstack-pg-dev:5432/mwserver",
        "DATABASE_APP_URL": "postgresql://mwserver_app:old@mwstack-pg-dev:5432/mwserver",
        "DATABASE_HOST": "mwstack-pg-dev", "DATABASE_USER": "mwserver", "DATABASE_DB": "mwserver",
    ]

    @Test("a clone onto App Platform plans a managed database, URLs only, copy as asked")
    func plansManaged() {
        let plan = DatabaseClonePlanner.plan(
            service: .mwserver, backend: .dokku, sourceConfig: config, source: source,
            target: "mwcloud", environment: Environment(rawValue: "staging"),
            targetBackend: .appPlatform, cluster: "mws-pg")
        let unwrapped = try! #require(plan)
        #expect(unwrapped.managed)
        #expect(unwrapped.serverApp == "mws-pg")
        #expect(unwrapped.owner == "mwserver")
        #expect(unwrapped.appUser == "mwserver_app")
        #expect(unwrapped.mode == .full)
        let schemaOnly = DatabaseClonePlanner.plan(
            service: .mwserver, backend: .dokku, sourceConfig: config, source: source,
            target: "mwcloud", environment: Environment(rawValue: "staging"), mode: .schema,
            targetBackend: .appPlatform, cluster: "mws-pg")
        #expect(schemaOnly?.mode == .schema)
        #expect(unwrapped.emitted == ["DATABASE_URL", "DATABASE_APP_URL"])
        #expect(unwrapped.summary.contains("managed cluster mws-pg"))
    }

    @Test("without a cluster there is nowhere to go, and a dokku clone is untouched")
    func refusesWithoutCluster() {
        #expect(
            DatabaseClonePlanner.plan(
                service: .mwserver, backend: .dokku, sourceConfig: config, source: source,
                target: "mwcloud", environment: Environment(rawValue: "staging"),
                targetBackend: .appPlatform, cluster: nil) == nil)
        let dokku = DatabaseClonePlanner.plan(
            service: .mwserver, backend: .dokku, sourceConfig: config, source: source,
            target: "mwlab-2", environment: Environment(rawValue: "dev"))
        #expect(dokku?.managed == false)
    }

    @Test("managed URLs carry the cluster's endpoint and sslmode=require")
    func managedValues() {
        let plan = DatabaseClonePlan(
            serverApp: "mws-pg", port: "25060", scheme: "postgresql", database: "mwcloud_mwserver",
            owner: "mwserver", appUser: "mwserver_app",
            emitted: ["DATABASE_URL", "DATABASE_APP_URL"], mode: .none, managed: true)
        let values = plan.values(
            DatabaseCredentials(
                ownerPassword: "o", appPassword: "a",
                endpoint: DatabaseEndpoint(host: "pg.db.ondigitalocean.com", port: "25060")))
        #expect(values["DATABASE_URL"] == "postgresql://mwserver:o@pg.db.ondigitalocean.com:25060/mwcloud_mwserver?sslmode=require")
        #expect(values["DATABASE_APP_URL"] == "postgresql://mwserver_app:a@pg.db.ondigitalocean.com:25060/mwcloud_mwserver?sslmode=require")
    }

    /// A fake DigitalOcean: one cluster, the database absent, the owner present, the app
    /// role absent, and no psql on the machine.
    private final class FakeDO: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [String] = []
        func handle(_ argv: [String]) -> CommandOutput {
            lock.lock(); defer { lock.unlock() }
            if argv.first == "sh" { return CommandOutput(status: 1, standardOutput: "") }
            if argv.first == "ssh" {
                calls.append("ssh " + argv.dropFirst(4).joined(separator: " "))
                return CommandOutput(status: 0, standardOutput: "")
            }
            let url = argv.last ?? ""
            let method = argv[argv.firstIndex(of: "-X").map { $0 + 1 } ?? 0]
            let path = url.replacingOccurrences(of: "https://api.digitalocean.com/v2/", with: "")
            calls.append("\(method) \(path)")
            func ok(_ body: String) -> CommandOutput {
                CommandOutput(status: 0, standardOutput: body + "\n200")
            }
            switch (method, path) {
            case ("GET", "databases"):
                return ok(#"{"databases": [{"id": "c1", "name": "mws-pg", "engine": "pg", "connection": {"host": "pg.db.ondigitalocean.com", "port": 25060, "user": "doadmin", "password": "adm", "database": "defaultdb"}}]}"#)
            case ("GET", "databases/c1/dbs"):
                return ok(#"{"dbs": [{"name": "defaultdb"}]}"#)
            case ("POST", "databases/c1/dbs"):
                return ok(#"{"db": {"name": "mwcloud_mwserver"}}"#)
            case ("GET", "databases/c1/users"):
                return ok(#"{"users": [{"name": "doadmin"}, {"name": "mwserver"}]}"#)
            case ("POST", "databases/c1/users/mwserver/reset_auth"):
                return ok(#"{"user": {"name": "mwserver", "password": "fresh-owner"}}"#)
            case ("POST", "databases/c1/users"):
                return ok(#"{"user": {"name": "mwserver_app", "password": "fresh-app"}}"#)
            default:
                return CommandOutput(status: 0, standardOutput: "{}\n404")
            }
        }
    }

    @Test("provisioning creates what is missing, resets what exists, and reports pending grants without psql")
    func provisions() async throws {
        let fake = FakeDO()
        let provisioner = ManagedPostgresProvisioner(
            execute: { argv, _ in fake.handle(argv) },
            environment: ["DIGITALOCEAN_TOKEN": "dop_v1_x"])
        let plan = DatabaseClonePlan(
            serverApp: "mws-pg", port: "25060", scheme: "postgresql", database: "mwcloud_mwserver",
            owner: "mwserver", appUser: "mwserver_app",
            emitted: ["DATABASE_URL", "DATABASE_APP_URL"], mode: .none, managed: true)
        let (credentials, report) = try await provisioner.provision(plan)

        #expect(credentials.ownerPassword == "fresh-owner")
        #expect(credentials.appPassword == "fresh-app")
        #expect(credentials.endpoint == DatabaseEndpoint(host: "pg.db.ondigitalocean.com", port: "25060"))
        #expect(fake.calls.contains("POST databases/c1/dbs"))
        #expect(fake.calls.contains("POST databases/c1/users/mwserver/reset_auth"))
        #expect(report.contains("created database mwcloud_mwserver"))
        #expect(report.contains("role mwserver already existed; password reset"))
        #expect(report.contains("created role mwserver_app"))
        #expect(report.contains { $0.contains("grants are pending") })
        #expect(report.contains { $0.contains("ALTER DATABASE \"mwcloud_mwserver\" OWNER TO \"mwserver\"") })
    }

    @Test("no token and an unknown cluster are named, not guessed around")
    func refusals() async {
        let fake = FakeDO()
        let noToken = ManagedPostgresProvisioner(execute: { argv, _ in fake.handle(argv) }, environment: [:])
        let plan = DatabaseClonePlan(
            serverApp: "other-pg", port: "25060", scheme: "postgresql", database: "d",
            owner: "o", appUser: nil, emitted: ["DATABASE_URL"], mode: .none, managed: true)
        await #expect(throws: ManagedPostgresError.noToken) { try await noToken.provision(plan) }
        let wrongCluster = ManagedPostgresProvisioner(
            execute: { argv, _ in fake.handle(argv) }, environment: ["DIGITALOCEAN_TOKEN": "t"])
        await #expect(throws: ManagedPostgresError.clusterNotFound("other-pg")) {
            try await wrongCluster.provision(plan)
        }
    }

    @Test("a full copy runs from the trusted source into the cluster, as the owner, after a schema reset")
    func copiesThroughTheTrustedSource() async throws {
        let fake = FakeDO()
        let provisioner = ManagedPostgresProvisioner(
            execute: { argv, _ in fake.handle(argv) },
            environment: ["DIGITALOCEAN_TOKEN": "dop_v1_x"])
        let plan = DatabaseClonePlan(
            serverApp: "mws-pg", port: "25060", scheme: "postgresql", database: "mwcloud_mwserver",
            owner: "mwserver", appUser: "mwserver_app",
            emitted: ["DATABASE_URL"], mode: .full,
            sourceDatabase: "mwserver", sourceServer: "mwstack-pg-dev", managed: true)
        let (_, report) = try await provisioner.provision(plan, admin: "jimmy@192.168.0.103")

        let ssh = fake.calls.filter { $0.hasPrefix("ssh") }
        #expect(ssh.first == "ssh command -v psql")
        #expect(ssh.contains { $0.contains("DROP SCHEMA IF EXISTS public CASCADE") })
        #expect(ssh.contains { $0.hasPrefix("ssh sh -c") })
        #expect(ssh.contains { $0.contains("GRANT USAGE ON SCHEMA public") })
        #expect(report.contains("schema and data copied from mwserver on mwstack-pg-dev, through jimmy@192.168.0.103"))
    }

    @Test("without an admin channel the copy is skipped and the plan says created empty")
    func copyNeedsAdmin() async throws {
        let fake = FakeDO()
        let provisioner = ManagedPostgresProvisioner(
            execute: { argv, _ in fake.handle(argv) },
            environment: ["DIGITALOCEAN_TOKEN": "dop_v1_x"])
        let plan = DatabaseClonePlan(
            serverApp: "mws-pg", port: "25060", scheme: "postgresql", database: "mwcloud_mwserver",
            owner: "mwserver", appUser: nil, emitted: ["DATABASE_URL"], mode: .full,
            sourceDatabase: "mwserver", sourceServer: "mwstack-pg-dev", managed: true)
        let (_, report) = try await provisioner.provision(plan)
        #expect(report.contains { $0.contains("full copy skipped") && $0.contains("db_admin") })
        #expect(!fake.calls.contains { $0.hasPrefix("ssh") })
    }
}

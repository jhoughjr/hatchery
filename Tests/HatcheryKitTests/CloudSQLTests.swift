import Foundation
import Testing

@testable import HatcheryKit

@Suite("A clone's database in a Cloud SQL instance")
struct CloudSQLTests {
    private let source = StackSpec(name: "mwlab", backend: .dokku, host: "dokku@192.168.0.103")
    private let config = [
        "DATABASE_URL": "postgresql://mwserver:old@mwstack-pg-dev:5432/mwserver",
        "DATABASE_APP_URL": "postgresql://mwserver_app:old@mwstack-pg-dev:5432/mwserver",
    ]

    @Test("a clone onto Cloud Run plans a managed database on port 5432")
    func plansManaged() {
        let plan = DatabaseClonePlanner.plan(
            service: .mwserver, backend: .dokku, sourceConfig: config, source: source,
            target: "mwgcp", environment: Environment(rawValue: "staging"),
            targetBackend: .cloudRun, cluster: "mws-sql")
        #expect(plan?.managed == true)
        #expect(plan?.serverApp == "mws-sql")
        #expect(plan?.port == "5432")
        #expect(plan?.emitted == ["DATABASE_URL", "DATABASE_APP_URL"])
        #expect(plan?.mode == .full)
    }

    @Test("Cloud Run's cost is a floor, and the instance adds nothing")
    func costFloor() {
        let lines = PlatformCost.lines(backend: .cloudRun, services: 3, managedDatabases: 2, cluster: "mws-sql")
        #expect(lines.count == 3)
        #expect(lines[0].text.contains("billed per request"))
        #expect(lines[1].text == "2 database(s) in the existing instance mws-sql: no added charge")
        #expect(lines.last?.monthlyUSD == 0)
    }

    /// A fake gcloud: one instance with a public address, the database absent, the owner
    /// present, the app user absent.
    private final class FakeGcloud: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [String] = []
        func handle(_ argv: [String]) -> CommandOutput {
            lock.lock(); defer { lock.unlock() }
            if argv.first == "sh" { return CommandOutput(status: 0, standardOutput: "/usr/bin/gcloud") }
            if argv.first == "ssh" {
                calls.append("ssh " + argv.dropFirst(4).joined(separator: " "))
                // psql is there, and the instance answers.
                return CommandOutput(status: 0, standardOutput: "1")
            }
            let joined = argv.dropFirst().joined(separator: " ")
            calls.append(joined)
            if joined.hasPrefix("sql instances describe mws-sql") {
                return CommandOutput(status: 0, standardOutput: #"{"connectionName": "mws-lab:us-central1:mws-sql", "databaseVersion": "POSTGRES_16", "ipAddresses": [{"type": "PRIMARY", "ipAddress": "34.1.2.3"}]}"#)
            }
            if joined.hasPrefix("sql instances describe") {
                return CommandOutput(status: 1, standardOutput: "", standardError: "ERROR: NOT_FOUND")
            }
            if joined.hasPrefix("sql databases list") { return CommandOutput(status: 0, standardOutput: "postgres\n") }
            if joined.hasPrefix("sql users list") { return CommandOutput(status: 0, standardOutput: "postgres\nmwserver\n") }
            return CommandOutput(status: 0, standardOutput: "")
        }
    }

    @Test("provisioning creates what is missing, resets what exists, mints passwords, and reports pending grants")
    func provisions() async throws {
        let fake = FakeGcloud()
        let provisioner = CloudSQLProvisioner(
            execute: { argv, _ in fake.handle(argv) }, mintPassword: { "minted" })
        let plan = DatabaseClonePlan(
            serverApp: "mws-sql", port: "5432", scheme: "postgresql", database: "mwgcp_mwserver",
            owner: "mwserver", appUser: "mwserver_app", emitted: ["DATABASE_URL"], mode: .none, managed: true)
        let (credentials, report) = try await provisioner.provision(plan)

        #expect(credentials.ownerPassword == "minted")
        #expect(credentials.endpoint == DatabaseEndpoint(host: "34.1.2.3", port: "5432", socket: "/cloudsql/mws-lab:us-central1:mws-sql"))
        #expect(fake.calls.contains("sql databases create mwgcp_mwserver --instance mws-sql --quiet"))
        #expect(fake.calls.contains("sql users set-password mwserver --instance mws-sql --password minted --quiet"))
        #expect(fake.calls.contains("sql users create mwserver_app --instance mws-sql --password minted --quiet"))
        #expect(report.contains("created database mwgcp_mwserver"))
        #expect(report.contains("user mwserver already existed; password reset"))
        #expect(report.contains { $0.contains("gcloud sql connect mws-sql --user=postgres") })
        #expect(plan.values(credentials)["DATABASE_URL"] == "postgresql://mwserver:minted@/mwgcp_mwserver?host=/cloudsql/mws-lab:us-central1:mws-sql")
    }

    @Test("an unknown instance and a missing gcloud are named")
    func refusals() async {
        let fake = FakeGcloud()
        let plan = DatabaseClonePlan(
            serverApp: "other", port: "5432", scheme: "postgresql", database: "d", owner: "o",
            appUser: nil, emitted: ["DATABASE_URL"], mode: .none, managed: true)
        let provisioner = CloudSQLProvisioner(execute: { argv, _ in fake.handle(argv) })
        await #expect(throws: CloudSQLError.instanceNotFound("other")) { try await provisioner.provision(plan) }
        let none = CloudSQLProvisioner(execute: { _, _ in CommandOutput(status: 1, standardOutput: "") })
        await #expect(throws: CloudSQLError.noGcloud) { try await none.provision(plan) }
    }

    @Test("a full copy runs from the trusted source as the owner, once the instance answers")
    func copies() async throws {
        let fake = FakeGcloud()
        let provisioner = CloudSQLProvisioner(
            execute: { argv, _ in fake.handle(argv) }, mintPassword: { "minted" })
        let plan = DatabaseClonePlan(
            serverApp: "mws-sql", port: "5432", scheme: "postgresql", database: "mwgcp_mwserver",
            owner: "mwserver", appUser: "mwserver_app", emitted: ["DATABASE_URL"], mode: .full,
            sourceDatabase: "mwserver", sourceServer: "mwstack-pg-dev", managed: true)
        let (_, report) = try await provisioner.provision(plan, admin: "jimmy@192.168.0.103")
        let ssh = fake.calls.filter { $0.hasPrefix("ssh") }
        #expect(ssh.first == "ssh command -v psql")
        #expect(ssh.contains { $0.contains("-c SELECT 1") })
        #expect(ssh.contains { $0.contains("DROP SCHEMA IF EXISTS public CASCADE") })
        #expect(ssh.contains { $0.hasPrefix("ssh sh -c") && $0.contains("pg_dump") })
        #expect(report.contains("schema and data copied from mwserver on mwstack-pg-dev, through jimmy@192.168.0.103"))
    }

    @Test("without an admin channel the copy is skipped and the plan says created empty")
    func copyNeedsAdmin() async throws {
        let fake = FakeGcloud()
        let provisioner = CloudSQLProvisioner(execute: { argv, _ in fake.handle(argv) })
        let plan = DatabaseClonePlan(
            serverApp: "mws-sql", port: "5432", scheme: "postgresql", database: "mwgcp_mwserver",
            owner: "mwserver", appUser: nil, emitted: ["DATABASE_URL"], mode: .full,
            sourceDatabase: "mwserver", sourceServer: "mwstack-pg-dev", managed: true)
        let (_, report) = try await provisioner.provision(plan)
        #expect(report.contains { $0.contains("full copy skipped") && $0.contains("db_admin") })
    }
}

import Foundation
import Testing

@testable import HatcheryKit

private func labStack() -> StackSpec {
    StackSpec(
        name: "mwlab",
        backend: .dokku,
        environment: .dev,
        host: "dokku@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/mwserver-tf"),
        services: [
            ServiceSpec(
                name: "mwlab", kind: .mwserver, image: "mwserver2:arm64-abc",
                domains: ["mwlab.opi"], configFile: "mwlab.config.json"),
            ServiceSpec(
                name: "paylab", kind: .paymentGateway, image: "pay:arm64-def",
                domains: ["paylab.opi"], configFile: "paylab.config.json"),
        ])
}

@Suite("Planning a clone's database")
struct DatabaseClonePlannerTests {
    /// The lab's real shape: both connection strings and the discrete keys, one server app.
    @Test("mirrors an mwserver's shape — same server, target-named database and roles")
    func mirrorsMwserver() throws {
        let plan = try #require(
            DatabaseClonePlanner.plan(
                service: .mwserver, backend: .dokku,
                sourceConfig: [
                    "DATABASE_URL": "postgresql://mwserver:pw@mwstack-pg-dev:5432/mwserver",
                    "DATABASE_APP_URL": "postgresql://mwserver_app:pw@mwstack-pg-dev:5432/mwserver",
                    "DATABASE_HOST": "mwstack-pg-dev",
                    "DATABASE_DB": "mwserver",
                    "DATABASE_USER": "mwserver",
                ],
                source: labStack(), target: "mwlab-2", environment: .staging))

        // The server is per-environment by name, and this clone is leaving dev: it targets
        // staging's server, the same substitution every other value gets.
        #expect(plan.serverApp == "mwstack-pg-staging")
        #expect(plan.port == "5432")
        #expect(plan.scheme == "postgresql")
        // `mwserver` names no stack, so the target prefixes it — either way it cannot
        // collide with the source's database on the same server.
        #expect(plan.database == "mwlab_2_mwserver")
        #expect(plan.owner == "mwlab_2_mwserver")
        #expect(plan.appUser == "mwlab_2_mwserver_app")
        // Both styles the source carried are emitted, so old images and new agree.
        #expect(plan.emitted.contains("DATABASE_URL"))
        #expect(plan.emitted.contains("DATABASE_APP_URL"))
        #expect(plan.emitted.contains("DATABASE_HOST"))
    }

    @Test("a clone staying in its environment stays on its server")
    func sameEnvironmentSameServer() throws {
        let plan = try #require(
            DatabaseClonePlanner.plan(
                service: .mwserver, backend: .dokku,
                sourceConfig: [
                    "DATABASE_URL": "postgresql://mwserver:pw@mwstack-pg-dev:5432/mwserver"
                ],
                source: labStack(), target: "mwlab-2", environment: .dev))

        #expect(plan.serverApp == "mwstack-pg-dev")
        // The database and roles are still the clone's own — same server never means same data.
        #expect(plan.database == "mwlab_2_mwserver")
    }

    @Test("a gateway with only discrete keys gets discrete keys back")
    func discreteOnly() throws {
        let plan = try #require(
            DatabaseClonePlanner.plan(
                service: .paymentGateway, backend: .dokku,
                sourceConfig: [
                    "DATABASE_HOST": "mwstack-pg-dev",
                    "DATABASE_PORT": "5432",
                    "DATABASE_DB": "payment_gateway",
                    "DATABASE_USER": "payment_gateway",
                    "DATABASE_PASSWORD": "old",
                ],
                source: labStack(), target: "mwlab-2", environment: .staging))

        #expect(plan.database == "mwlab_2_payment_gateway")
        #expect(plan.appUser == nil)
        #expect(plan.emitted.contains("DATABASE_PASSWORD"))
        #expect(!plan.emitted.contains("DATABASE_APP_URL"))

        let values = plan.values(DatabaseCredentials(ownerPassword: "minted", appPassword: nil))
        #expect(values["DATABASE_HOST"] == "mwstack-pg-staging")
        #expect(values["DATABASE_USER"] == "mwlab_2_payment_gateway")
        #expect(values["DATABASE_PASSWORD"] == "minted")
        #expect(values["DATABASE_DB"] == "mwlab_2_payment_gateway")
    }

    @Test("composes the clone's connection strings from the minted credentials")
    func composesURLs() throws {
        let plan = try #require(
            DatabaseClonePlanner.plan(
                service: .mwserver, backend: .dokku,
                sourceConfig: [
                    "DATABASE_URL": "postgresql://mwserver:pw@mwstack-pg-dev:5432/mwserver",
                    "DATABASE_APP_URL": "postgresql://mwserver_app:pw@mwstack-pg-dev:5432/mwserver",
                ],
                source: labStack(), target: "mwlab-2", environment: .staging))

        let values = plan.values(
            DatabaseCredentials(ownerPassword: "ownerpw", appPassword: "apppw"))
        #expect(
            values["DATABASE_URL"]
                == "postgresql://mwlab_2_mwserver:ownerpw@mwstack-pg-staging:5432/mwlab_2_mwserver")
        #expect(
            values["DATABASE_APP_URL"]
                == "postgresql://mwlab_2_mwserver_app:apppw@mwstack-pg-staging:5432/mwlab_2_mwserver")
        // Nothing in the composed values is the source's.
        #expect(!values.values.contains { $0.contains("pw@mwstack") && !$0.contains("ownerpw") && !$0.contains("apppw") })
    }

    @Test("a managed server, another backend, or a db-free service plans nothing")
    func plansNothing() {
        // Dotted host: not a dokku app hatchery can enter.
        #expect(
            DatabaseClonePlanner.plan(
                service: .mwserver, backend: .dokku,
                sourceConfig: ["DATABASE_URL": "postgresql://u:p@db.example.com:25060/x"],
                source: labStack(), target: "mwlab-2", environment: .staging) == nil)
        // Managed backend: the database is the provider's, not the box's.
        #expect(
            DatabaseClonePlanner.plan(
                service: .mwserver, backend: .appPlatform,
                sourceConfig: ["DATABASE_URL": "postgresql://u:p@pg:5432/x"],
                source: labStack(), target: "mwlab-2", environment: .staging) == nil)
        // No shape in the source: nothing to mirror.
        #expect(
            DatabaseClonePlanner.plan(
                service: .mwserver, backend: .dokku, sourceConfig: [:],
                source: labStack(), target: "mwlab-2", environment: .staging) == nil)
    }

    @Test("folds names into safe postgres identifiers")
    func foldsIdentifiers() {
        #expect(DatabaseClonePlanner.identifier("mwlab-2") == "mwlab_2")
        #expect(DatabaseClonePlanner.identifier("MW.Lab") == "mw_lab")
        #expect(DatabaseClonePlanner.identifier("2fast") == "db_2fast")
    }
}

@Suite("Provisioning a clone's database")
struct DatabaseProvisionerTests {
    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []
        func record(_ argv: [String]) {
            lock.lock()
            commands.append(argv)
            lock.unlock()
        }
        func all() -> [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }
    }

    private func plan(
        appUser: String? = "mwlab_2_app",
        mode: DatabaseCloneMode = .none,
        sourceDatabase: String? = nil,
        sourceServer: String? = nil
    ) -> DatabaseClonePlan {
        DatabaseClonePlan(
            serverApp: "mwstack-pg-dev", port: "5432", scheme: "postgresql",
            database: "mwlab_2_mwserver", owner: "mwlab_2_mwserver", appUser: appUser,
            emitted: ["DATABASE_URL"], mode: mode,
            sourceDatabase: sourceDatabase, sourceServer: sourceServer)
    }

    @Test("asserts roles, database and grants through the postgres app, over ssh")
    func assertsEverything() async throws {
        let recorded = Recorded()
        let provisioner = DatabaseProvisioner(
            run: { argv in
                recorded.record(argv)
                return Data()
            },
            mintPassword: { "minted" })

        let (credentials, report) = try await provisioner.provision(
            plan(), host: "192.168.0.103")

        #expect(credentials.ownerPassword == "minted")
        #expect(credentials.appPassword == "minted")
        let commands = recorded.all()
        // Every statement travels the same road: ssh as dokku, enter the postgres app, psql.
        for command in commands {
            #expect(Array(command.prefix(4)) == ["ssh", "-o", "BatchMode=yes", "dokku@192.168.0.103"])
            #expect(command.contains("enter"))
            #expect(command.contains("mwstack-pg-dev"))
            #expect(command.contains("psql"))
        }
        let sql = commands.compactMap(\.last).joined(separator: "\n")
        #expect(sql.contains("CREATE ROLE \"mwlab_2_mwserver\""))
        #expect(sql.contains("CREATE DATABASE \"mwlab_2_mwserver\" OWNER \"mwlab_2_mwserver\""))
        #expect(sql.contains("GRANT CONNECT"))
        #expect(report.contains { $0.contains("created database mwlab_2_mwserver") })
    }

    @Test("an existing role is converged — password re-minted, not an error")
    func convergesExistingRole() async throws {
        let recorded = Recorded()
        let provisioner = DatabaseProvisioner(
            run: { argv in
                recorded.record(argv)
                if argv.last?.contains("CREATE ROLE") == true {
                    throw CommandFailure(
                        command: "psql", status: 1,
                        message: "ERROR:  role \"mwlab_2_mwserver\" already exists")
                }
                return Data()
            },
            mintPassword: { "minted" })

        let (_, report) = try await provisioner.provision(plan(appUser: nil), host: "192.168.0.103")

        let sql = recorded.all().compactMap(\.last).joined(separator: "\n")
        #expect(sql.contains("ALTER ROLE \"mwlab_2_mwserver\" WITH LOGIN PASSWORD"))
        #expect(report.contains { $0.contains("already existed") })
    }

    @Test("an ERROR in the output is a failure even when the exit status lied")
    func distrustsExitStatus() async throws {
        let provisioner = DatabaseProvisioner(
            run: { _ in Data("ERROR:  permission denied to create role".utf8) },
            mintPassword: { "minted" })

        await #expect(throws: DatabaseProvisionError.self) {
            _ = try await provisioner.provision(plan(appUser: nil), host: "192.168.0.103")
        }
    }

    @Test("a statement failure names the statement, with the password redacted")
    func namesTheStatement() async throws {
        let provisioner = DatabaseProvisioner(
            run: { argv in
                if argv.last?.contains("CREATE ROLE") == true {
                    throw CommandFailure(command: "ssh", status: 255, message: "connection refused")
                }
                return Data()
            },
            mintPassword: { "s3cretminted" })

        do {
            _ = try await provisioner.provision(plan(appUser: nil), host: "192.168.0.103")
            Issue.record("expected provisioning to fail")
        } catch let error as DatabaseProvisionError {
            #expect("\(error)".contains("CREATE ROLE"))
            #expect("\(error)".contains("connection refused"))
            // The failed statement carries the minted password; the error must not.
            #expect(!"\(error)".contains("s3cretminted"))
        }
    }

    @Test("falls back to the admin's docker exec when the server is not a dokku app")
    func fallsBackToAdmin() async throws {
        let recorded = Recorded()
        let provisioner = DatabaseProvisioner(
            run: { argv in
                recorded.record(argv)
                if argv.contains("enter") {
                    throw CommandFailure(
                        command: "ssh", status: 20,
                        message: "!     App mwstack-pg-dev does not exist")
                }
                return Data()
            },
            mintPassword: { "minted" })

        let (credentials, report) = try await provisioner.provision(
            plan(appUser: nil), host: "192.168.0.103", admin: "jimmy@opi.local")

        #expect(credentials.ownerPassword == "minted")
        #expect(report.contains { $0.contains("via jimmy@opi.local") })
        // Exactly one dokku attempt — the probe — and everything else through the admin.
        let dokku = recorded.all().filter { $0.contains("enter") }
        #expect(dokku.count == 1)
        let admin = recorded.all().filter { $0.contains("docker") }
        for command in admin {
            #expect(Array(command.prefix(4)) == ["ssh", "-o", "BatchMode=yes", "jimmy@opi.local"])
            #expect(command.contains("exec"))
            #expect(command.contains("mwstack-pg-dev"))
        }
        #expect(admin.contains { $0.last?.contains("CREATE ROLE") == true })
    }

    @Test("a full clone pipes the source database into the new one, as the new owner")
    func copiesFullDatabase() async throws {
        let recorded = Recorded()
        let provisioner = DatabaseProvisioner(
            run: { argv in
                recorded.record(argv)
                return Data()
            },
            mintPassword: { "minted" })

        _ = try await provisioner.provision(
            plan(mode: .full, sourceDatabase: "mwserver", sourceServer: "mwstack-pg-dev"),
            host: "192.168.0.103")

        let pipelines = recorded.all().filter { $0.contains("sh") }
        #expect(pipelines.count == 1)
        let pipeline = pipelines[0].last ?? ""
        #expect(pipeline.contains("pg_dump -U postgres --no-owner --no-acl -d mwserver"))
        #expect(pipeline.contains("psql -q -v ON_ERROR_STOP=1 -U mwlab_2_mwserver -d mwlab_2_mwserver"))
        let sql = recorded.all().compactMap(\.last).joined(separator: "\n")
        // The target schema resets before the restore, so a re-run converges instead of
        // dying on a half-restored attempt's leftovers.
        #expect(sql.contains("DROP SCHEMA IF EXISTS public CASCADE"))
        #expect(sql.contains("ALTER SCHEMA public OWNER TO \"mwlab_2_mwserver\""))
        // And the reset takes the grants with it, so they re-assert over what arrived.
        #expect(sql.contains("ON ALL TABLES IN SCHEMA public"))
        #expect(sql.contains("ON ALL SEQUENCES IN SCHEMA public"))
        let dropIndex = recorded.all().firstIndex { $0.last?.contains("DROP SCHEMA") == true }
        let copyIndex = recorded.all().firstIndex { $0.last?.contains("pg_dump") == true }
        #expect(dropIndex != nil && copyIndex != nil && dropIndex! < copyIndex!)
    }

    @Test("a schema clone dumps structure only, and none dumps nothing")
    func schemaAndNone() async throws {
        let recorded = Recorded()
        let provisioner = DatabaseProvisioner(
            run: { argv in
                recorded.record(argv)
                return Data()
            },
            mintPassword: { "minted" })

        _ = try await provisioner.provision(
            plan(mode: .schema, sourceDatabase: "mwserver", sourceServer: "mwstack-pg-dev"),
            host: "192.168.0.103")
        let schema = recorded.all().compactMap(\.last).joined(separator: "\n")
        #expect(schema.contains("--schema-only"))

        let none = Recorded()
        let empty = DatabaseProvisioner(
            run: { argv in
                none.record(argv)
                return Data()
            },
            mintPassword: { "minted" })
        _ = try await empty.provision(
            plan(mode: .none, sourceDatabase: "mwserver", sourceServer: "mwstack-pg-dev"),
            host: "192.168.0.103")
        #expect(!none.all().compactMap(\.last).joined().contains("pg_dump"))
    }

    @Test("a copy across servers bridges the two containers through the admin")
    func crossServerCopyViaAdmin() async throws {
        let recorded = Recorded()
        let provisioner = DatabaseProvisioner(
            run: { argv in
                recorded.record(argv)
                if argv.contains("enter") {
                    // Not a dokku app: the probe falls through to the admin.
                    throw CommandFailure(
                        command: "ssh", status: 20,
                        message: "!     App mwstack-pg-dev does not exist")
                }
                return Data()
            },
            mintPassword: { "minted" })

        let (_, report) = try await provisioner.provision(
            plan(mode: .full, sourceDatabase: "mwserver", sourceServer: "mwstack-pg-prod"),
            host: "192.168.0.103", admin: "jimmy@opi.local")

        let pipeline = recorded.all().compactMap(\.last).first { $0.contains("pg_dump") } ?? ""
        #expect(pipeline.contains("docker exec mwstack-pg-prod pg_dump"))
        #expect(pipeline.contains("docker exec -i mwstack-pg-dev psql"))
        #expect(report.contains { $0.contains("copied from mwserver on mwstack-pg-prod") })
    }

    @Test("a cross-server copy without an admin is skipped naming the setting")
    func skipsCrossServerCopyWithoutAdmin() async throws {
        let recorded = Recorded()
        let provisioner = DatabaseProvisioner(
            run: { argv in
                recorded.record(argv)
                return Data()
            },
            mintPassword: { "minted" })

        let (_, report) = try await provisioner.provision(
            plan(mode: .full, sourceDatabase: "mwserver", sourceServer: "mwstack-pg-prod"),
            host: "192.168.0.103")

        #expect(!recorded.all().compactMap(\.last).joined().contains("pg_dump"))
        #expect(report.contains { $0.contains("db_admin") })
    }

    @Test("a source database with a hostile name is never placed in a pipeline")
    func refusesHostileNames() async throws {
        let recorded = Recorded()
        let provisioner = DatabaseProvisioner(
            run: { argv in
                recorded.record(argv)
                return Data()
            },
            mintPassword: { "minted" })

        let (_, report) = try await provisioner.provision(
            plan(mode: .full, sourceDatabase: "db; rm -rf /", sourceServer: "mwstack-pg-dev"),
            host: "192.168.0.103")

        #expect(!recorded.all().compactMap(\.last).joined().contains("pg_dump"))
        #expect(report.contains { $0.contains("not a plain identifier") })
    }

    @Test("the probe answers nil for a reachable server, a sentence for a missing one")
    func probesTheServer() async throws {
        let reachable = DatabaseProvisioner(run: { _ in Data() }, mintPassword: { "x" })
        #expect(await reachable.probe(plan(), host: "192.168.0.103", admin: nil) == nil)

        let missing = DatabaseProvisioner(
            run: { argv in
                if argv.contains("enter") {
                    throw CommandFailure(
                        command: "ssh", status: 20,
                        message: "!     App mwstack-pg-dev does not exist")
                }
                throw CommandFailure(
                    command: "ssh", status: 1,
                    message: "Error response from daemon: No such container: mwstack-pg-dev")
            },
            mintPassword: { "x" })
        let warning = await missing.probe(
            plan(), host: "192.168.0.103", admin: "jimmy@opi.local")
        #expect(warning?.contains("mwstack-pg-dev") == true)
        #expect(warning?.contains("not reachable") == true)
    }

    @Test("a non-dokku server with no admin configured names the missing setting")
    func namesTheMissingAdmin() async throws {
        let provisioner = DatabaseProvisioner(
            run: { _ in
                throw CommandFailure(
                    command: "ssh", status: 20, message: "!     App mwstack-pg-dev does not exist")
            },
            mintPassword: { "minted" })

        do {
            _ = try await provisioner.provision(plan(appUser: nil), host: "dokku@192.168.0.103")
            Issue.record("expected provisioning to fail")
        } catch let error as DatabaseProvisionError {
            #expect("\(error)".contains("db_admin"))
            #expect("\(error)".contains("mwstack-pg-dev"))
        }
    }
}

@Suite("Reading service shapes out of tofu files")
struct TofuShapeReaderTests {
    private let declaration = """
        # mwserver app 'mwlab', authored by hand.
        resource "dokku_app" "mwlab" {
          app_name = "mwlab"

          ports = {
            "80" = {
              scheme         = "http"
              container_port = "8080"
            }
          }

          networks = {
            attach_post_create = "macworkstack-infra_default"
          }
        }

        resource "dokku_app" "paylab" {
          count = var.enable_paylab ? 1 : 0
          app_name = "paylab"

          ports = {
            "80" = { scheme = "http", container_port = "9090" }
          }
        }
        """

    @Test("finds each app's port, network and gating")
    func readsShapes() {
        let shapes = TofuShapeReader.shapes(
            inTofuDirectory: "/infra",
            list: { _ in ["stack.tf", "README.md"] },
            read: { _ in self.declaration })

        #expect(shapes["mwlab"]?.containerPort == 8080)
        #expect(shapes["mwlab"]?.network == "macworkstack-infra_default")
        #expect(shapes["mwlab"]?.gated == false)
        #expect(shapes["paylab"]?.containerPort == 9090)
        #expect(shapes["paylab"]?.network == nil)
        #expect(shapes["paylab"]?.gated == true)
    }

    @Test("an unreadable directory is no shapes, never a guess")
    func unreadableIsEmpty() {
        let shapes = TofuShapeReader.shapes(
            inTofuDirectory: "/nope",
            list: { _ in throw CocoaError(.fileReadNoSuchFile) },
            read: { _ in "" })
        #expect(shapes.isEmpty)
    }
}

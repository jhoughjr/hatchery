import Foundation
import Testing

@testable import HatcheryKit

/// A cluster shaped like the box's, declaring what the fixture says is inside it.
private func clusterService(databases: [DatabaseSpec]) -> ServiceSpec {
    ServiceSpec(
        name: "mwstack-pg-staging",
        kind: ServiceKind(rawValue: "mwstack-pg-staging"),
        image: "postgres:17-alpine",
        configFile: "mwstack-pg-staging.config.json",
        container: ContainerSpec(
            image: "postgres:17-alpine",
            network: "macworkstack-infra_default",
            ports: [ContainerSpec.PortMap(host: 5434, container: 5432)],
            restart: "unless-stopped"),
        databases: databases)
}

private func boxStack(_ service: ServiceSpec) -> StackSpec {
    StackSpec(
        name: "box", backend: .host, environment: .prod, host: "jimmy@192.168.0.103",
        services: [service])
}

@Suite("Provisioning what a manifest declares")
struct DeclaredProvisionTests {
    @Test("one request per declared database, and the ones the cluster holds are marked")
    func issuesOneRequestPerDeclaredDatabase() throws {
        let inventory = try recordedCluster("mwstack-pg-staging.pg.json")
        let service = clusterService(databases: inventory.specs() + [
            DatabaseSpec(name: "mwlab_3_mwserver", owner: "mwserver", appRole: "mwlab_3_mwserver_app")
        ])

        let requests = DeclaredProvision.requests(for: service, in: inventory)

        #expect(requests.map(\.database) == [
            "mwlab_2_payment_gateway", "mwlab_2_communication_gateway", "mwlab_2_mwserver",
            "mwlab_3_mwserver",
        ])
        #expect(requests.filter(\.exists).map(\.database) == [
            "mwlab_2_payment_gateway", "mwlab_2_communication_gateway", "mwlab_2_mwserver",
        ])
        // The one the cluster does not hold is the only one an assertion would go out for.
        #expect(requests.filter { !$0.exists }.map(\.database) == ["mwlab_3_mwserver"])
    }

    @Test("a request carries the declared owner and app role, and copies nothing")
    func carriesTheDeclaration() throws {
        let inventory = try recordedCluster("mwstack-pg-staging.pg.json")
        let service = clusterService(databases: inventory.specs())

        let requests = DeclaredProvision.requests(for: service, in: inventory)
        let mwserver = try #require(requests.first { $0.database == "mwlab_2_mwserver" })

        #expect(mwserver.plan.serverApp == "mwstack-pg-staging")
        #expect(mwserver.plan.owner == "mwserver")
        #expect(mwserver.plan.appUser == "mwlab_2_mwserver_app")
        #expect(mwserver.plan.port == "5432")
        #expect(mwserver.plan.mode == .none)
        #expect(mwserver.plan.sourceDatabase == nil)

        let gateway = try #require(requests.first { $0.database == "mwlab_2_payment_gateway" })
        #expect(gateway.plan.appUser == nil)
        #expect(!gateway.plan.emitted.contains("DATABASE_APP_URL"))
    }

    @Test("the target is a stack and a service, and anything else is refused")
    func readsTheTarget() {
        #expect(DeclaredProvision.target("box/rookery-pg")?.stack == "box")
        #expect(DeclaredProvision.target("box/rookery-pg")?.service == "rookery-pg")
        #expect(DeclaredProvision.target("rookery-pg") == nil)
        #expect(DeclaredProvision.target("/rookery-pg") == nil)
        #expect(DeclaredProvision.target("box/") == nil)
    }

    @Test("a service that is no cluster, and a cluster with nothing adopted, are refused by name")
    func refusesWhatItCannotProvision() throws {
        var notACluster = clusterService(databases: [])
        notACluster.container = ContainerSpec(image: "4km3/dnsmasq:latest", network: "host")
        notACluster.databases = nil

        #expect(throws: DeclaredProvision.Refusal.notACluster(service: "mwstack-pg-staging")) {
            _ = try DeclaredProvision.resolve(
                ("box", "mwstack-pg-staging"), in: StackManifest(stacks: [boxStack(notACluster)]))
        }
        #expect(throws: DeclaredProvision.Refusal.noDatabases(service: "mwstack-pg-staging")) {
            _ = try DeclaredProvision.resolve(
                ("box", "mwstack-pg-staging"),
                in: StackManifest(stacks: [boxStack(clusterService(databases: []))]))
        }
        #expect(throws: DeclaredProvision.Refusal.noSuchService(stack: "box", service: "absent")) {
            _ = try DeclaredProvision.resolve(
                ("box", "absent"),
                in: StackManifest(stacks: [boxStack(clusterService(databases: []))]))
        }
    }
}

@Suite("Grading a cluster against its declaration")
struct ClusterStatusTests {
    /// The answers the grade asks for, in order: docker inspect, pg_isready, then the two selects.
    ///
    /// The executor is replaced, so no test opens an ssh connection or reaches a box.
    static func reporter(
        inspect: String, ready: Int32 = 0, databases: String
    ) -> StatusReporter {
        StatusReporter(execute: { argv, _ in
            if argv.contains("pg_isready") { return CommandOutput(status: ready, standardOutput: "") }
            if argv.contains("-Atc") {
                let sql = argv.last ?? ""
                if sql.contains("pg_roles") { return CommandOutput(status: 0, standardOutput: "postgres\n") }
                return CommandOutput(status: 0, standardOutput: databases)
            }
            return CommandOutput(status: 0, standardOutput: inspect)
        })
    }

    static let running = """
        [{"Id":"a","Name":"/mwstack-pg-staging","Config":{"Image":"postgres:17-alpine"},\
        "State":{"Status":"running","Running":true},"HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}},\
        "Mounts":[]}]
        """

    @Test("a cluster holding every declared database is ready")
    func readyWhenEveryDatabaseIsThere() async throws {
        let declared = try recordedCluster("mwstack-pg-staging.pg.json").specs()
        let service = clusterService(databases: declared)
        let reporter = Self.reporter(
            inspect: Self.running,
            databases: "postgres|postgres\nmwlab_2_payment_gateway|payment_gateway\n"
                + "mwlab_2_communication_gateway|communication_gateway\nmwlab_2_mwserver|mwserver\n")

        let health = await reporter.status(of: service, in: boxStack(service))

        #expect(health.state == .ready)
        #expect(health.reasons.isEmpty)
    }

    @Test("a missing database is degraded, and the reason names it")
    func degradedWhenADatabaseIsMissing() async throws {
        let declared = try recordedCluster("mwstack-pg-staging.pg.json").specs()
        let service = clusterService(databases: declared)
        let reporter = Self.reporter(
            inspect: Self.running,
            databases: "postgres|postgres\nmwlab_2_payment_gateway|payment_gateway\n"
                + "mwlab_2_mwserver|mwserver\n")

        let health = await reporter.status(of: service, in: boxStack(service))

        #expect(health.state == .degraded)
        #expect(health.reasons == ["the cluster does not hold mwlab_2_communication_gateway"])
    }

    @Test("a running container whose postgres is not accepting connections is degraded")
    func degradedWhenPostgresIsNotReady() async throws {
        let declared = try recordedCluster("mwstack-pg-staging.pg.json").specs()
        let service = clusterService(databases: declared)
        let reporter = Self.reporter(inspect: Self.running, ready: 1, databases: "")

        let health = await reporter.status(of: service, in: boxStack(service))

        #expect(health.state == .degraded)
        #expect(health.reasons == [
            "the container is running, and postgres is not accepting connections"
        ])
    }
}

@Suite("The declaration a cluster publishes")
struct DeclaredClusterDocumentTests {
    @Test("the document carries the databases, and a service without them gains no field")
    func carriesTheDatabases() throws {
        let declared = try recordedCluster("rookery-pg.pg.json").specs()
        var cluster = clusterService(databases: declared)
        cluster.name = "rookery-pg"
        var plain = clusterService(databases: [])
        plain.name = "lan-dns"
        plain.databases = nil
        plain.container = ContainerSpec(image: "4km3/dnsmasq:latest", network: "host")

        let document = Declaration(
            manifests: [(manifest: StackManifest(stacks: [
                StackSpec(
                    name: "box", backend: .host, host: "jimmy@192.168.0.103",
                    services: [cluster, plain])
            ]), path: "box/hatchery.json")])

        let service = try #require(document.stacks.first?.services.first)
        #expect(service.databases == [
            Declaration.Database(name: "rookery", owner: "rookery", appRole: "rookery_app")
        ])
        #expect(document.stacks.first?.services.last?.databases == nil)
        #expect(!String(decoding: try document.encoded(), as: UTF8.self)
            .contains("\"databases\" : [\n\n        ]"))
    }

    @Test("a manifest write leaves the two findings empty, as it does the sidecar ones")
    func aWriteFillsNoFinding() throws {
        let declared = try recordedCluster("rookery-pg.pg.json").specs()
        let cluster = clusterService(databases: declared)

        let document = Declaration(
            manifests: [(manifest: StackManifest(stacks: [boxStack(cluster)]), path: "box/hatchery.json")])

        #expect(document.stacks.first?.services.first?.findings.isEmpty == true)
    }

    @Test("an undeclared database and an orphan role each become a finding of their own code")
    func fillsBothFindings() throws {
        let inventory = try recordedCluster("mwstack-pg-staging.pg.json")
        // Only one of the three is declared, so the other two are undeclared and their owners fall out
        // of the accounted set.
        let declared = [
            DatabaseSpec(name: "mwlab_2_mwserver", owner: "mwserver", appRole: "mwlab_2_mwserver_app")
        ]

        let findings = DeclarationAudit.databaseFindings(in: inventory, against: declared)

        let undeclared = findings.filter { $0.code == FindingCode.undeclaredDatabase }
        #expect(undeclared.count == 2)
        #expect(undeclared.contains { $0.text.contains("mwlab_2_payment_gateway") })
        #expect(undeclared.contains { $0.text.contains("mwlab_2_communication_gateway") })
        // No finding ever names the cluster's own databases.
        #expect(!findings.contains { $0.text.contains("template0") })
        #expect(!findings.contains { $0.text.contains("template1") })

        let orphan = try #require(findings.first { $0.code == FindingCode.orphanRole })
        #expect(orphan.text.contains("mwserver_app"))
        #expect(!orphan.text.contains("pg_read_all_data"))
    }

    @Test("a cluster whose declaration accounts for everything raises no finding")
    func aCleanClusterIsClean() throws {
        let inventory = try recordedCluster("rookery-pg.pg.json")

        #expect(DeclarationAudit.databaseFindings(in: inventory, against: inventory.specs()).isEmpty)
    }
}

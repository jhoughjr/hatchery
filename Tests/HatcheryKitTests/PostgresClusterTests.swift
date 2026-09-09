import Foundation
import Testing

@testable import HatcheryKit

/// The two `psql -Atc` answers recorded off the opi on 2026-09-09, read only.
///
/// The fixtures are the real bytes rather than a hand-written sample, because the owners the clusters carry
/// are the whole surprise: staging's `mwlab_2_mwserver` is owned by `mwserver`, which no naming rule predicts.
func recordedCluster(_ name: String) throws -> ClusterInventory {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    return try ClusterInventory.decode(
        try Data(contentsOf: fixtures.appendingPathComponent(name)))
}

@Suite("Reading a postgres cluster off the box")
struct PostgresClusterTests {
    @Test("rookery's cluster declares its one database, with the app role the cluster holds")
    func adoptsRookery() throws {
        let inventory = try recordedCluster("rookery-pg.pg.json")

        #expect(inventory.databases.count == 4)
        #expect(inventory.specs() == [
            DatabaseSpec(name: "rookery", owner: "rookery", appRole: "rookery_app")
        ])
    }

    @Test("staging declares three databases, whose owners are not named after them")
    func adoptsStaging() throws {
        let inventory = try recordedCluster("mwstack-pg-staging.pg.json")

        #expect(inventory.specs() == [
            DatabaseSpec(
                name: "mwlab_2_payment_gateway", owner: "payment_gateway", appRole: nil),
            DatabaseSpec(
                name: "mwlab_2_communication_gateway", owner: "communication_gateway", appRole: nil),
            DatabaseSpec(
                name: "mwlab_2_mwserver", owner: "mwserver", appRole: "mwlab_2_mwserver_app"),
        ])
    }

    @Test("the cluster's own databases are the image's, so nothing declares them")
    func skipsTheClusterOwnDatabases() throws {
        let inventory = try recordedCluster("rookery-pg.pg.json")

        let declared = inventory.declarableDatabases.map(\.name)
        #expect(declared == ["rookery"])
        #expect(!declared.contains("postgres"))
        #expect(inventory.undeclaredDatabases(against: inventory.specs()).isEmpty)
    }

    @Test("a database the manifest does not declare is a finding, and the templates are not")
    func findsAnUndeclaredDatabase() throws {
        let inventory = try recordedCluster("mwstack-pg-staging.pg.json")

        let declared = [DatabaseSpec(name: "mwlab_2_mwserver", owner: "mwserver")]
        #expect(inventory.undeclaredDatabases(against: declared)
            == ["mwlab_2_payment_gateway", "mwlab_2_communication_gateway"])
    }

    @Test("staging's one orphan is mwserver_app, and the declared app role is not one")
    func findsTheOneOrphanRole() throws {
        let inventory = try recordedCluster("mwstack-pg-staging.pg.json")

        let orphans = inventory.orphanRoles(against: inventory.specs())
        #expect(orphans.contains("mwserver_app"))
        // The app role of a declared database is accounted for by the declaration that names it.
        #expect(!orphans.contains("mwlab_2_mwserver_app"))
        // Every owner of a database is accounted for, and so is the superuser.
        #expect(!orphans.contains("mwserver"))
        #expect(!orphans.contains("payment_gateway"))
        #expect(!orphans.contains("communication_gateway"))
        #expect(!orphans.contains("postgres"))
        // The reserved prefix is postgres's own namespace, and no role in it belongs to a service.
        #expect(!orphans.contains(where: { $0.hasPrefix("pg_") }))
    }

    @Test("rookery's roles are all accounted for once its database is declared")
    func rookeryHasNoOrphans() throws {
        let inventory = try recordedCluster("rookery-pg.pg.json")

        #expect(inventory.orphanRoles(against: inventory.specs()).isEmpty)
    }

    @Test("the read is two selects and a pg_isready, quoted for the shell the hop lands in")
    func readsOverTheAdminChannel() {
        #expect(ClusterReader.databasesCommand("rookery-pg", on: "jimmy@192.168.0.103") == [
            "ssh", "-o", "BatchMode=yes", "jimmy@192.168.0.103",
            "docker", "exec", "rookery-pg", "psql", "-U", "postgres", "-Atc",
            "'select datname, pg_get_userbyid(datdba) from pg_database'",
        ])
        #expect(ClusterReader.rolesCommand("rookery-pg", on: "local") == [
            "docker", "exec", "rookery-pg", "psql", "-U", "postgres", "-Atc",
            "select rolname from pg_roles",
        ])
        #expect(ClusterReader.readyCommand("rookery-pg", on: "local") == [
            "docker", "exec", "rookery-pg", "pg_isready", "-U", "postgres",
        ])
    }
}

@Suite("Declaring databases in the manifest")
struct DeclaredDatabaseManifestTests {
    /// A cluster shaped like the box's, with the image the guard reads.
    static func cluster(databases: [DatabaseSpec]? = nil) -> ServiceSpec {
        ServiceSpec(
            name: "rookery-pg",
            kind: ServiceKind(rawValue: "rookery-pg"),
            image: "postgres:17-alpine",
            configFile: "rookery-pg.config.json",
            container: ContainerSpec(image: "postgres:17-alpine", network: "rookery_default"),
            databases: databases)
    }

    static func manifest(_ service: ServiceSpec) -> StackManifest {
        StackManifest(
            stacks: [
                StackSpec(name: "box", backend: .host, host: "jimmy@192.168.0.103", services: [service])
            ])
    }

    @Test("a manifest with databases decodes back to the same declaration")
    func roundTrips() throws {
        let declared = [
            DatabaseSpec(name: "rookery", owner: "rookery", appRole: "rookery_app", notes: "the work record")
        ]
        let written = Self.manifest(Self.cluster(databases: declared))

        let read = try StackManifest.decode(from: try written.encoded())

        #expect(read == written)
        #expect(read.stack(named: "box")?.service(named: "rookery-pg")?.databases == declared)
    }

    @Test("a service declaring no database gains no key")
    func encodesNothingWhenAbsent() throws {
        let data = try Self.manifest(Self.cluster()).encoded()

        #expect(!String(decoding: data, as: UTF8.self).contains("databases"))
    }

    @Test("the guard is the image, so a cluster whose kind is its own name is still a cluster")
    func acceptsAContainerKindedAfterItself() throws {
        let service = Self.cluster(databases: [DatabaseSpec(name: "rookery", owner: "rookery")])

        #expect(service.kind == ServiceKind(rawValue: "rookery-pg"))
        #expect(service.isPostgresCluster)
        #expect(throws: Never.self) { try Self.manifest(service).validate() }
    }

    @Test("a service that runs something other than postgres declares no database")
    func refusesDatabasesOffACluster() throws {
        var service = Self.cluster(databases: [DatabaseSpec(name: "rookery", owner: "rookery")])
        service.container = ContainerSpec(image: "4km3/dnsmasq:latest", network: "host")

        #expect(!service.isPostgresCluster)
        #expect(throws: ManifestError.databasesOffCluster(stack: "box", service: "rookery-pg")) {
            try Self.manifest(service).validate()
        }
    }

    @Test("adopting replaces the whole list, so a database that has left leaves the declaration")
    func replacesTheList() {
        let before = Self.manifest(
            Self.cluster(databases: [
                DatabaseSpec(name: "rookery", owner: "rookery"),
                DatabaseSpec(name: "gone", owner: "gone"),
            ]))

        let after = before.settingDatabases(
            stack: "box", service: "rookery-pg",
            to: [DatabaseSpec(name: "rookery", owner: "rookery", appRole: "rookery_app")])

        #expect(after.stack(named: "box")?.service(named: "rookery-pg")?.databases
            == [DatabaseSpec(name: "rookery", owner: "rookery", appRole: "rookery_app")])
    }
}

import ArgumentParser
import Foundation
import HatcheryKit
import ScanKit

/// Databases, outside a clone.
///
/// Provisioning already existed, but only inside `stack clone`: a database arrived because a
/// stack was copied, and there was no way to ask for one on its own. A new service then had a
/// person paste `CREATE ROLE` into psql by hand — the one step of standing a service up that
/// hatchery knew how to do and did not offer.
struct Database: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Provision a database server and a database on it.",
        subcommands: [Provision.self, Adopt.self]
    )

    /// The databases inside a cluster that already runs, declared into the manifest.
    ///
    /// The box stack declares the three clusters as containers, and a container declaration says nothing
    /// about what is inside it. This reads the cluster and writes what is there, so a declared database
    /// becomes a `hatchery db provision` that has already run.
    struct Adopt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Declare the databases inside a postgres cluster the box already runs.",
            discussion: """
                Reads `pg_database` and `pg_roles` over a read-only docker exec, and writes one \
                declaration per database into the cluster's service: its name, the role \
                `pg_get_userbyid(datdba)` names as its owner, and a role named `<database>_app` as \
                its app role when the cluster holds one.

                The cluster's own databases — postgres, template0 and template1 — belong to the \
                image, so nothing declares them. The whole list is replaced rather than merged, \
                because a database that has left the cluster must leave the declaration with it.

                Nothing is written to the cluster. Provisioning owns the writes, and this reads.
                """
        )

        @Argument(help: "The box the cluster runs on, as user@host, or `local`.")
        var target: String

        @Argument(help: "The postgres container, as docker names it, which is also the service in the stack.")
        var container: String

        @Option(name: .shortAndLong, help: "The stack that declares the cluster.")
        var stack: String

        @Option(name: .shortAndLong, help: "Path to the stack manifest.")
        var manifest: String = "hatchery.json"

        @Flag(name: .long, help: "Show what would be written without writing anything.")
        var dryRun: Bool = false

        func run() async throws {
            let manifestPath = try ManifestLocator.resolve(manifest)
            let manifestDirectory = URL(fileURLWithPath: manifestPath).deletingLastPathComponent().path
            let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
            let parsed = try StackManifest.decode(from: data)

            guard let spec = parsed.stack(named: stack) else {
                throw ValidationError("no stack named '\(stack)' in \(manifestPath)")
            }
            guard let service = spec.service(named: container) else {
                throw ValidationError("stack '\(stack)' declares no service named '\(container)'")
            }
            guard service.isPostgresCluster else {
                throw ValidationError(
                    "service '\(container)' in stack '\(stack)' is not a postgres container; "
                        + "its image is \(service.container?.image ?? service.image)")
            }

            // Two adopters against one manifest collide, so this takes the same lock the box
            // door takes. A dry run writes nothing and takes no lock.
            let lock = AdoptLock(manifestDirectory: manifestDirectory)
            if !dryRun {
                do {
                    try lock.acquire()
                } catch let error as AdoptLockError {
                    throw ValidationError(error.description)
                }
            }
            defer { if !dryRun { lock.release() } }

            let inventory: ClusterInventory
            do {
                inventory = try await ClusterReader().inventory(of: container, on: target)
            } catch let failure as CommandFailure {
                throw ValidationError("could not read \(container) on \(target): \(failure.message)")
            }

            let specs = inventory.specs()
            print("\(container) on \(target)")
            for database in specs {
                let appRole = database.appRole.map { ", app role \($0)" } ?? ", no app role"
                print("  \(database.name)  owner \(database.owner)\(appRole)")
            }
            let orphans = inventory.orphanRoles(against: specs)
            if !orphans.isEmpty {
                print("  roles owning no database: \(orphans.joined(separator: ", "))")
            }

            if dryRun {
                print("  dry run; nothing written")
                return
            }
            let written = parsed.settingDatabases(stack: stack, service: container, to: specs)
            try written.write(to: manifestPath)
            print("  declared \(specs.count) database(s) on \(stack)/\(container)")
            if let line = await StateMaintenance.seal(after: manifestPath) { print("  \(line)") }
        }
    }

    /// Creates the server if it is absent, then the database, the roles and the grants.
    struct Provision: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a database, its roles and its grants, on a server of your own.",
            discussion: """
                The server is yours, not one you borrow. When --server names a container that \
                does not exist and --network is given, it is created first — postgres:17-alpine, \
                its own named volume, restart unless-stopped — so a service does not have to \
                move in beside somebody else's database.

                Every step is an assertion, so running it twice lands in the same place: an \
                existing role has its password re-minted, an existing database has its owner \
                confirmed. That is what lets a half-finished run be re-run.

                --admin is the shell account that can `docker exec` the server, as user@host. \
                Use `local` when the container runs on this machine. The database is created \
                where that account points, which for this estate is the pi rather than a laptop.

                The minted passwords are printed. They exist only in the answer to this \
                command — nothing stores them — so hiding them would mean provisioning again, \
                and the second run would re-mint and lock the first one out.
                """
        )

        @Option(name: .long, help: "The postgres container. Created when absent, if --network is given.")
        var server: String?

        @Option(name: .long, help: "Database to create.")
        var database: String?

        @Option(name: .long, help: "Role that owns the database. Defaults to the database name.")
        var owner: String?

        @Option(name: .long, help: "Optional reduced-privilege role, for the app's own connection.")
        var appUser: String?

        @Option(name: .long, help: "Shell account that can docker-exec the server, as user@host, or `local`.")
        var admin: String?

        @Option(
            name: .long,
            help: "Assert every database a manifest declares on one cluster, as <stack>/<service>. The stack's host is the admin channel.")
        var declared: String?

        @Option(name: .shortAndLong, help: "Path to the stack manifest, with --declared.")
        var manifest: String = "hatchery.json"

        @Option(name: .long, help: "The box the server runs on. Used to reach a dokku-managed postgres.")
        var host: String = ""

        @Option(name: .long, help: "Docker network to create the server on. Without it, an absent server is an error rather than something to create.")
        var network: String?

        @Option(name: .long, help: "Port the server listens on.")
        var port: Int = 5432

        @Option(
            name: .long,
            help: "Host port to publish the server on. Without it the server answers only its own network.")
        var publish: Int?

        func run() async throws {
            if let declared {
                try await self.runDeclared(declared)
                return
            }
            guard let server, let database, let admin else {
                throw ValidationError(
                    "provision needs --server, --database and --admin, or --declared <stack>/<service>")
            }
            let owner = owner ?? database
            // These names reach a shell on the box. The planner folds the names it derives;
            // names given by hand are checked here instead, so this door is not the weak one.
            for (label, value) in [
                ("server", server), ("database", database), ("owner", owner),
            ] + (appUser.map { [("app-user", $0)] } ?? []) + (network.map { [("network", $0)] } ?? []) {
                guard DatabaseProvisioner.isPlainName(value) else {
                    throw ValidationError(
                        "\(label) '\(value)' is not a plain name; use letters, digits, _ and -")
                }
            }

            var emitted: Set<String> = [
                "DATABASE_URL", "DATABASE_HOST", "DATABASE_PORT", "DATABASE_USER",
                "DATABASE_PASSWORD", "DATABASE_DB",
            ]
            if appUser != nil {
                emitted.formUnion(["DATABASE_APP_URL", "DATABASE_APP_USER", "DATABASE_APP_PASSWORD"])
            }

            let plan = DatabaseClonePlan(
                serverApp: server, port: String(port), scheme: "postgresql",
                database: database, owner: owner, appUser: appUser, emitted: emitted,
                // Nothing is being copied: this database starts empty, and the service's own
                // migrations own the schema from here.
                mode: .none)

            let provisioner = DatabaseProvisioner()
            let (credentials, report) = try await provisioner.provision(
                plan, host: host, admin: admin, network: network,
                publish: publish.map(String.init))

            for line in report { print("  \(line)") }
            print("")
            let values = plan.values(credentials)
            for key in values.keys.sorted() {
                print("\(key)=\(values[key] ?? "")")
            }
        }

        /// Asserts every database a cluster's declaration names, and leaves the ones that are already there.
        ///
        /// An assertion over an existing role re-mints its password, which would lock out the service already
        /// connecting with it, so a database the cluster holds is reported and skipped. The passwords of the
        /// ones this does mint are printed, on the same rule the single-database door prints them.
        private func runDeclared(_ target: String) async throws {
            guard let parsed = DeclaredProvision.target(target) else {
                throw ValidationError("--declared takes <stack>/<service>, for example box/rookery-pg")
            }
            let manifestPath = try ManifestLocator.resolve(manifest)
            let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
            let loaded = try StackManifest.decode(from: data)

            let resolved: (service: ServiceSpec, host: String)
            do {
                resolved = try DeclaredProvision.resolve(parsed, in: loaded)
            } catch let refusal as DeclaredProvision.Refusal {
                throw ValidationError(refusal.description)
            }

            let inventory = try await ClusterReader().inventory(
                of: resolved.service.name, on: resolved.host)
            let requests = DeclaredProvision.requests(for: resolved.service, in: inventory)

            print("\(resolved.service.name) on \(resolved.host)")
            let provisioner = DatabaseProvisioner()
            for request in requests where request.exists {
                print("  \(request.database)  already there")
            }
            for request in requests where !request.exists {
                let (credentials, report) = try await provisioner.provision(
                    request.plan, host: resolved.host, admin: resolved.host)
                print("  \(request.database)  asserted")
                for line in report { print("    \(line)") }
                let values = request.plan.values(credentials)
                for key in values.keys.sorted() {
                    print("    \(key)=\(values[key] ?? "")")
                }
            }
        }
    }
}

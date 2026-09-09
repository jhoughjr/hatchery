import Foundation

/// One declared database, as a `--declared` provision would put it to the cluster.
///
/// A declared database is a provision that has already run, so the usual answer is that there is nothing to
/// do. `exists` carries that answer, and the run asserts only the databases the cluster does not hold: an
/// assertion over an existing role re-mints its password, which would lock out the service already using it.
public struct DeclaredProvisionRequest: Sendable, Equatable {
    public var plan: DatabaseClonePlan
    public var exists: Bool

    public init(plan: DatabaseClonePlan, exists: Bool) {
        self.plan = plan
        self.exists = exists
    }

    public var database: String { self.plan.database }
}

/// Turns a service's declared databases into the provisions that would assert them.
///
/// This is the whole of what `--declared` decides, kept away from the box so the decision can be read without
/// one. The provisioner then runs the requests that are not already there.
public enum DeclaredProvision {
    /// Why a `--declared` run has nothing it can do.
    ///
    /// - `noSuchService`: the target does not name a service of that stack.
    /// - `notACluster`: the service runs something other than postgres, so it holds no database.
    /// - `noDatabases`: the service is a cluster, and nothing has been adopted from it yet.
    /// - `noHost`: the stack names no box, so there is no channel to reach the cluster on.
    public enum Refusal: Error, CustomStringConvertible, Equatable {
        case noSuchService(stack: String, service: String)
        case notACluster(service: String)
        case noDatabases(service: String)
        case noHost(stack: String)

        public var description: String {
            switch self {
            case .noSuchService(let stack, let service):
                return "stack '\(stack)' declares no service named '\(service)'"

            case .notACluster(let service):
                return "service '\(service)' is not a postgres container, so it declares no database"

            case .noDatabases(let service):
                return "service '\(service)' declares no database; hatchery db adopt reads them off the box"

            case .noHost(let stack):
                return "stack '\(stack)' declares no host, so there is no box to reach the cluster on"
            }
        }
    }

    /// `<stack>/<service>`, as `--declared` takes it.
    public static func target(_ text: String) -> (stack: String, service: String)? {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// The service a target names, with the box to reach it on.
    public static func resolve(
        _ target: (stack: String, service: String), in manifest: StackManifest
    ) throws -> (service: ServiceSpec, host: String) {
        guard let stack = manifest.stack(named: target.stack),
            let service = stack.service(named: target.service)
        else {
            throw Refusal.noSuchService(stack: target.stack, service: target.service)
        }
        guard service.isPostgresCluster else { throw Refusal.notACluster(service: service.name) }
        guard !service.declaredDatabases.isEmpty else {
            throw Refusal.noDatabases(service: service.name)
        }
        guard let host = stack.host, !host.isEmpty else { throw Refusal.noHost(stack: target.stack) }
        return (service, host)
    }

    /// One request per declared database, marked against what the cluster holds.
    ///
    /// The plans carry `mode: .none`, because nothing is being copied: a declared database either exists
    /// already or is stood up empty, and the service's own migrations own the schema either way.
    public static func requests(
        for service: ServiceSpec, in cluster: ClusterInventory
    ) -> [DeclaredProvisionRequest] {
        let port = service.container?.ports.first.map { String($0.container) } ?? "5432"
        let held = Set(cluster.databases.map(\.name))
        return service.declaredDatabases.map { database in
            var emitted: Set<String> = [
                "DATABASE_URL", "DATABASE_HOST", "DATABASE_PORT", "DATABASE_USER",
                "DATABASE_PASSWORD", "DATABASE_DB",
            ]
            if database.appRole != nil {
                emitted.formUnion(["DATABASE_APP_URL", "DATABASE_APP_USER", "DATABASE_APP_PASSWORD"])
            }
            return DeclaredProvisionRequest(
                plan: DatabaseClonePlan(
                    serverApp: service.name, port: port, scheme: "postgresql",
                    database: database.name, owner: database.owner, appUser: database.appRole,
                    emitted: emitted, mode: .none),
                exists: held.contains(database.name))
        }
    }
}

// MARK: - What a cluster's declaration says about it

extension Declaration {
    /// One declared database in the published document.
    ///
    /// The owner and the app role are role names and never credentials, so the document carries them the way
    /// it carries a domain. A reader can then see that a database has no app role at all, which is the shape
    /// several of the lab's databases are in.
    public struct Database: Codable, Sendable, Equatable {
        public var name: String
        public var owner: String
        public var appRole: String?

        public init(name: String, owner: String, appRole: String? = nil) {
            self.name = name
            self.owner = owner
            self.appRole = appRole
        }

        public init(_ spec: DatabaseSpec) {
            self.name = spec.name
            self.owner = spec.owner
            self.appRole = spec.appRole
        }
    }
}

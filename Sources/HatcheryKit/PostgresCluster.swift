import Foundation

/// What one postgres cluster holds, as `pg_database` and `pg_roles` answer it.
///
/// This is the read side of a declared database: the manifest says what should be inside a cluster, and this
/// says what is. Both questions are answered over the same read-only `docker exec`, so the declaration and
/// the grade never read the cluster differently.
public struct ClusterInventory: Sendable, Equatable {
    /// One row of `select datname, pg_get_userbyid(datdba) from pg_database`.
    public struct Database: Sendable, Equatable {
        public var name: String
        /// The role `datdba` points at, which is the role a declared owner must match.
        public var owner: String

        public init(name: String, owner: String) {
            self.name = name
            self.owner = owner
        }
    }

    public var databases: [Database]
    public var roles: [String]

    public init(databases: [Database], roles: [String]) {
        self.databases = databases
        self.roles = roles
    }
}

// MARK: - Reading the two answers

extension ClusterInventory {
    /// The databases every cluster carries, which no service declares.
    ///
    /// `template0` and `template1` are the templates, and `postgres` is the maintenance database the image
    /// creates. Declaring any of them would put a service's name on something the image owns.
    public static let clusterOwn: Set<String> = ["postgres", "template0", "template1"]

    /// The two `psql -Atc` answers, as the box prints them.
    ///
    /// `-A` prints unaligned rows and `-t` drops the header, so a database row is `name|owner` and a role row
    /// is the name alone. A row that carries no separator is skipped rather than read as half a row.
    public static func read(databases: Data, roles: Data) -> ClusterInventory {
        ClusterInventory(
            databases: Self.rows(databases).compactMap { row in
                let parts = row.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return Database(name: String(parts[0]), owner: String(parts[1]))
            },
            roles: Self.rows(roles))
    }

    /// A recorded cluster, from a fixture holding the container's name and the two raw answers.
    public static func decode(_ json: Data) throws -> ClusterInventory {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let databases = object["databases"] as? String,
            let roles = object["roles"] as? String
        else {
            throw ClusterReadError.unreadableAnswer("the fixture holds no databases and roles answer")
        }
        return Self.read(databases: Data(databases.utf8), roles: Data(roles.utf8))
    }

    static func rows(_ output: Data) -> [String] {
        String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The databases a service declares, which is every one the image does not own.
    public var declarableDatabases: [Database] {
        self.databases.filter { !Self.clusterOwn.contains($0.name) }
    }

    public func database(named name: String) -> Database? {
        self.databases.first { $0.name == name }
    }
}

// MARK: - What the cluster would be declared as

extension ClusterInventory {
    /// One ``DatabaseSpec`` per declarable database, in the order the cluster listed them.
    ///
    /// The owner is whatever `datdba` points at, so a database whose owner is not named after it keeps its
    /// real owner. A role named `<database>_app` is that database's app role, which is the convention
    /// `hatchery db provision` mints them under.
    public func specs() -> [DatabaseSpec] {
        let roles = Set(self.roles)
        return self.declarableDatabases.map { database in
            let appRole = database.name + "_app"
            return DatabaseSpec(
                name: database.name,
                owner: database.owner,
                appRole: roles.contains(appRole) ? appRole : nil)
        }
    }
}

// MARK: - Findings

extension ClusterInventory {
    /// The databases in the cluster that the manifest does not declare.
    public func undeclaredDatabases(against declared: [DatabaseSpec]) -> [String] {
        let names = Set(declared.map(\.name))
        return self.declarableDatabases.map(\.name).filter { !names.contains($0) }
    }

    /// The roles that own no database and answer to no declared database.
    ///
    /// `postgres` is the superuser and `doadmin` is the managed platform's, so neither belongs to a service.
    /// A `pg_` name is reserved: postgres refuses to create a role under that prefix, so every one of them is
    /// the image's own. A declared owner or app role is accounted for by the declaration that names it.
    public func orphanRoles(against declared: [DatabaseSpec]) -> [String] {
        var accounted: Set<String> = ["postgres", "doadmin"]
        for spec in declared {
            accounted.insert(spec.owner)
            if let appRole = spec.appRole { accounted.insert(appRole) }
        }
        let owners = Set(self.databases.map(\.owner))
        return self.roles.filter { role in
            !role.hasPrefix("pg_") && !accounted.contains(role) && !owners.contains(role)
        }
    }
}

/// Why a cluster could not be read.
///
/// - `unreadableAnswer`: the box answered, and the answer is not the two row lists psql prints.
public enum ClusterReadError: Error, CustomStringConvertible, Equatable {
    case unreadableAnswer(String)

    public var description: String {
        switch self {
        case .unreadableAnswer(let detail):
            return "the cluster did not answer with a readable inventory (\(detail))"
        }
    }
}

// MARK: - The read-only door on the box

/// Reads a postgres cluster on a box, and writes nothing to it.
///
/// Every statement here is a select or a `pg_isready`, sent through the same `docker exec` the provisioner
/// uses. Provisioning owns the writes; this type exists so a declaration and a grade can read a cluster
/// without going near them.
public struct ClusterReader: Sendable {
    private let run: CommandRunner

    public init(run: @escaping CommandRunner = ShellRunner.live) {
        self.run = run
    }

    public func inventory(of container: String, on target: String) async throws -> ClusterInventory {
        let databases = try await self.run(Self.databasesCommand(container, on: target))
        let roles = try await self.run(Self.rolesCommand(container, on: target))
        return ClusterInventory.read(databases: databases, roles: roles)
    }

    /// Whether postgres inside the container is accepting connections.
    ///
    /// A cluster that is up and not yet accepting connections answers nonzero, which is the one thing this
    /// question is for, so a failure is an answer of `false` rather than a throw.
    public func isReady(_ container: String, on target: String) async -> Bool {
        ((try? await self.run(Self.readyCommand(container, on: target))) != nil)
    }

    static let databasesSelect = "select datname, pg_get_userbyid(datdba) from pg_database"
    static let rolesSelect = "select rolname from pg_roles"

    static func databasesCommand(_ container: String, on target: String) -> [String] {
        Self.psql(Self.databasesSelect, container: container, target: target)
    }

    static func rolesCommand(_ container: String, on target: String) -> [String] {
        Self.psql(Self.rolesSelect, container: container, target: target)
    }

    static func readyCommand(_ container: String, on target: String) -> [String] {
        AdminChannel.prefix(target) + ["docker", "exec", container, "pg_isready", "-U", "postgres"]
    }

    /// The SQL travels through the remote shell when the box is another machine, so it is quoted for that
    /// shell and left bare when there is no second shell to parse it.
    static func psql(_ sql: String, container: String, target: String) -> [String] {
        let prefix = AdminChannel.prefix(target)
        return prefix + ["docker", "exec", container, "psql", "-U", "postgres", "-Atc"]
            + [prefix.isEmpty ? sql : DatabaseProvisioner.shellQuoted(sql)]
    }
}

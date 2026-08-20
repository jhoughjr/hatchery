import Foundation

/// A stack-level clone plan, plus where each service's configuration was actually read from.
///
/// The origin travels with the plan because it changes how much to trust it: a plan from the
/// box's live config covers keys someone set by hand, a plan from the declared sidecar misses
/// exactly those — and the person judging the plan should know which they are looking at.
public struct PlannedClone: Sendable {
    public let plan: ClonePlan
    /// By service name: a line describing where that service's config came from.
    public let origins: [String: String]
    /// What will go wrong at create as things stand — an unreachable database server,
    /// mostly. The plan is still shown; these lines are what to fix before creating.
    public let warnings: [String]
    /// What will happen to each domain's reachability — the front door is part of the
    /// clone, and a domain that will resolve nowhere says so here, not after health polls.
    public let exposure: [ExposurePlan]
    /// What the platform will bill per month for what the create makes. Empty for a
    /// self-hosted backend, which bills nothing per app.
    public let costs: [CostLine]

    public init(
        plan: ClonePlan, origins: [String: String], warnings: [String] = [],
        exposure: [ExposurePlan] = [], costs: [CostLine] = []
    ) {
        self.plan = plan
        self.origins = origins
        self.warnings = warnings
        self.exposure = exposure
        self.costs = costs
    }
}

/// Plans a whole stack's clone, one service at a time.
///
/// This is the loop the CLI ran inline until the dashboard needed it too: read each service's
/// config — live from the box when the backend can answer, the declared sidecar otherwise —
/// rewrite the domains, and put every key through the cloner's classification. One
/// implementation, because two of these drifting apart is how the CLI and the browser come to
/// promise different clones.
public struct StackClonePlanner: Sendable {
    public typealias LiveRead = @Sendable (ServiceSpec, StackSpec) async throws -> [String: String]
    public typealias DeclaredRead = @Sendable (URL) throws -> [String: String]
    /// Whether a planned database's server answers, before anything is created.
    public typealias ServerProbe = @Sendable (DatabaseClonePlan, String, String?) async -> String?

    /// Named references, not literals, so they can sit in default-argument positions — a
    /// closure literal there trips the task allocator (issue #36).
    public static let liveRead: LiveRead = { service, stack in
        try await LiveConfigReader().config(for: service, in: stack)
    }
    public static let declaredRead: DeclaredRead = { try ConfigSync.readDeclared(at: $0) }
    public static let serverProbe: ServerProbe = { plan, host, admin in
        await DatabaseProvisioner().probe(plan, host: host, admin: admin)
    }

    private let cloner: StackCloner
    private let readLive: LiveRead
    private let readDeclared: DeclaredRead
    private let probe: ServerProbe

    public init(
        cloner: StackCloner = StackCloner(),
        readLive: @escaping LiveRead = StackClonePlanner.liveRead,
        readDeclared: @escaping DeclaredRead = StackClonePlanner.declaredRead,
        probe: @escaping ServerProbe = StackClonePlanner.serverProbe
    ) {
        self.cloner = cloner
        self.readLive = readLive
        self.readDeclared = readDeclared
        self.probe = probe
    }

    /// An unreadable sidecar is not an empty one. Planning from `[:]` would report every key
    /// as never-set, which is a different claim entirely — so the plan refuses instead.
    public struct UnreadableConfig: Error, CustomStringConvertible {
        public let service: String
        public let path: String
        public let underlying: String

        public var description: String {
            "cannot read \(service)'s config: \(path): \(underlying)"
        }
    }

    public func plan(
        stack source: StackSpec,
        into target: String,
        environment: Environment,
        manifestPath: String,
        databaseMode: DatabaseCloneMode = .full,
        targetBackend: Backend? = nil,
        cluster: String? = nil
    ) async throws -> PlannedClone {
        var services: [ClonedService] = []
        var origins: [String: String] = [:]

        for service in source.services {
            // The box's config, not the sidecar, when the backend can answer: the declared
            // file misses exactly the keys someone set by hand — the drift `config audit`
            // exists to find. When live reading fails or isn't supported the declared file
            // stands in, and the origin says which one the plan was made from.
            let url = ConfigSync.configURL(for: service, in: source, manifestPath: manifestPath)
            let config: [String: String]
            let origin: String
            do {
                config = try await readLive(service, source)
                origin = "live config on \(source.hostAddress ?? source.backend.rawValue)"
            } catch {
                let why = error is LiveConfigError
                    ? "" : " — live read failed: \(error); the box may disagree"
                do {
                    config = try readDeclared(url)
                    origin = "declared file\(why)"
                } catch {
                    throw UnreadableConfig(
                        service: service.name, path: url.path, underlying: "\(error)")
                }
            }

            // Through the planner's rewrite, not a plain stack-name substitution. A sibling
            // service's domain (`paylab.opi`) contains no stack name, so the naive version
            // left it untouched — and a clone claiming production's domain is not a clone.
            let domains = service.domains.map {
                StackCloner.rewrite($0, from: source, to: target, environment: environment) ?? $0
            }

            let planned = try await cloner.plan(
                service: service, from: source, into: target, environment: environment,
                sourceConfig: config, domains: domains, databaseMode: databaseMode,
                targetBackend: targetBackend, cluster: cluster)
            services.append(planned)
            // Keyed by the clone-side name, which is what every display looks services up by.
            origins[planned.name] = origin
        }

        // Each distinct database server, probed once. A staging clone targets staging's
        // server by name; a server that does not exist should be a line on this plan, not a
        // provisioning failure after the create click.
        var warnings: [String] = []
        var probed: Set<String> = []
        let host = source.host ?? source.settings?["host"] ?? ""
        let admin = source.settings?["db_admin"]
        for service in services {
            guard let database = service.database else { continue }
            // A managed cluster is not a dokku app to probe. Its existence is checked by
            // name at provision time, and box init --backend appPlatform checks it up front.
            guard !database.managed else { continue }
            let server = "\(database.serverApp):\(database.port)"
            guard !probed.contains(server) else { continue }
            probed.insert(server)
            if let warning = await probe(database, host, admin) {
                warnings.append(warning)
            }
        }

        // The clone carries the source's settings, so its exposure provider is the
        // source's; the domains are the clone's own, already rewritten.
        let exposure = await Exposure.provider(for: source)
            .plan(domains: services.flatMap(\.domains), stack: source)

        // Money, before the create: a platform bills per app the moment it exists.
        let costs = PlatformCost.lines(
            backend: targetBackend ?? source.backend, services: services.count,
            managedDatabases: Set(services.compactMap { $0.database?.identity }).count,
            cluster: cluster)

        return PlannedClone(
            plan: ClonePlan(
                source: source.name, target: target, environment: environment,
                services: services),
            origins: origins,
            warnings: warnings,
            exposure: exposure, costs: costs)
    }
}

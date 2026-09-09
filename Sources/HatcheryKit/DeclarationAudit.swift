import Foundation

/// The machine's word for a kind of finding.
public enum FindingCode {
    /// The sidecar declares a different set of keys than the box runs with.
    public static let staleSidecar = "stale-sidecar"
    /// A key the contract marks secret is still in the sidecar rather than the secrets file.
    public static let secretInSidecar = "secret-in-sidecar"
    /// The cluster holds a database that the manifest does not declare.
    public static let undeclaredDatabase = "undeclared-database"
    /// The cluster holds a role that owns no database and answers to no declared database.
    public static let orphanRole = "orphan-role"
}

/// Fills the declaration's findings by comparing what each service declares against what it runs with.
///
/// `hatchery config audit` already asks both questions and prints the answers on a terminal, where nothing
/// off the box can read them. This asks the same questions and puts the answers in the published document,
/// so the coop draws them beside the gap instead of a person having to ssh in to find out.
///
/// A service the box will not answer for produces no finding rather than an error: an unreadable service is
/// already visible as a gap, and a second complaint about it says nothing new.
public struct DeclarationAudit: Sendable {
    private let reader: LiveConfigReader
    private let cluster: ClusterReader

    public init(reader: LiveConfigReader = LiveConfigReader(), cluster: ClusterReader = ClusterReader()) {
        self.reader = reader
        self.cluster = cluster
    }

    /// The findings for every service in every manifest, keyed `<stack>/<service>`.
    public func findings(
        for manifests: [(manifest: StackManifest, path: String)]
    ) async -> [String: [Declaration.Finding]] {
        var result: [String: [Declaration.Finding]] = [:]
        for loaded in manifests {
            let registry = KindRegistry(manifestPath: loaded.path)
            for stack in loaded.manifest.stacks {
                for service in stack.services {
                    let found = await self.findings(
                        for: service, in: stack, manifestPath: loaded.path, registry: registry)
                    guard !found.isEmpty else { continue }
                    result["\(stack.name)/\(service.name)"] = found
                }
            }
        }
        return result
    }

    func findings(
        for service: ServiceSpec, in stack: StackSpec, manifestPath: String, registry: KindRegistry
    ) async -> [Declaration.Finding] {
        // A cluster is asked about first, because its findings are about what is inside it rather than
        // about its sidecar, and a cluster's sidecar is usually just the image's own environment.
        var findings = await self.databaseFindings(for: service, in: stack)

        // The sidecar's own content, never the merge with the secrets file. A key still here is a key
        // `hatchery config split` has not moved yet.
        let sidecarURL = ConfigSync.configURL(for: service, in: stack, manifestPath: manifestPath)
        guard let sidecar = try? ConfigSync.readDeclared(at: sidecarURL) else { return findings }

        if let contract = EnvContract.contract(
            for: service.kind, backend: stack.backend, registry: registry)
        {
            findings += ConfigValidator.secretInSidecar(sidecar, against: contract).map {
                Declaration.Finding(
                    code: FindingCode.secretInSidecar,
                    text: "\($0.key) is a secret still in the sidecar; hatchery config split moves it out")
            }
        }

        // The declaration is both files, because a key moved to the secrets file is declared, not missing.
        let secretsURL = ConfigSync.secretsURL(for: service, in: stack, manifestPath: manifestPath)
        let declared = (try? ConfigSync.readDeclared(config: sidecarURL, secrets: secretsURL)) ?? sidecar

        // For host backend services, the live config includes the image's own environment, so we need
        // to strip it before comparing with the declared config. Dokku services don't need this because
        // dokku's config:export already returns only the runtime-set values.
        var live: [String: String]?
        if stack.backend == .host {
            // Fetch the full container environment and the image environment
            if let liveData = try? await self.reader.config(for: service, in: stack),
               let imageEnv = try? await self.reader.imageEnvironment(
                   for: service.image, on: stack.host ?? "") {
                // Use the contract if available to understand which keys are declared
                let contract = EnvContract.contract(
                    for: service.kind, backend: stack.backend, registry: registry)
                // The image inspection already carries the full environment, so we can use
                // a dummy ContainerInspection to apply the declaredEnvironment logic
                let dummy = ContainerInspection(
                    id: "", name: service.name, image: service.image, state: "running", running: true,
                    environment: liveData, spec: ContainerSpec(image: service.image))
                live = dummy.declaredEnvironment(against: imageEnv, contract: contract)
            }
        } else {
            live = try? await self.reader.config(for: service, in: stack)
        }

        if let live, let stale = Self.staleSidecar(live: live, declared: declared) {
            findings.append(stale)
        }
        return findings
    }

    /// What the cluster holds that its declaration does not account for.
    ///
    /// A service that is not a postgres cluster, and a stack that names no box, produce nothing rather than an
    /// error. A cluster the box will not answer for produces nothing too, on the same rule as a service whose
    /// config cannot be read: an unreadable cluster is already visible as a gap.
    public func databaseFindings(
        for service: ServiceSpec, in stack: StackSpec
    ) async -> [Declaration.Finding] {
        guard service.isPostgresCluster, let host = stack.host, !host.isEmpty else { return [] }
        guard let inventory = try? await self.cluster.inventory(of: service.name, on: host) else { return [] }
        return Self.databaseFindings(in: inventory, against: service.declaredDatabases)
    }

    /// The two findings a cluster and its declaration produce together.
    ///
    /// Only names appear in the text. A role name is not a credential, and the coop draws it beside the gap
    /// so a person can see which role to account for.
    static func databaseFindings(
        in inventory: ClusterInventory, against declared: [DatabaseSpec]
    ) -> [Declaration.Finding] {
        var findings: [Declaration.Finding] = []
        for database in inventory.undeclaredDatabases(against: declared) {
            findings.append(
                Declaration.Finding(
                    code: FindingCode.undeclaredDatabase,
                    text: "the cluster holds \(database), and the manifest does not declare it; "
                        + "hatchery db adopt writes it in"))
        }
        let orphans = inventory.orphanRoles(against: declared)
        if !orphans.isEmpty {
            findings.append(
                Declaration.Finding(
                    code: FindingCode.orphanRole,
                    text: "the cluster holds \(orphans.count) role(s) owning no database and named by no "
                        + "declaration: \(orphans.joined(separator: ", "))"))
        }
        return findings
    }

    /// The finding for a key set that no longer matches the box, or `nil` when the two agree.
    ///
    /// Only key names appear in the text. The values are the whole reason the sidecar is gitignored, and a
    /// published document that named one would defeat that.
    static func staleSidecar(live: [String: String], declared: [String: String]) -> Declaration.Finding? {
        let difference = ConfigSync.diff(live: live, declared: declared)
        guard !difference.added.isEmpty || !difference.removed.isEmpty else { return nil }

        var parts: [String] = []
        if !difference.added.isEmpty {
            parts.append("the box also runs with \(difference.added.joined(separator: ", "))")
        }
        if !difference.removed.isEmpty {
            parts.append("the box does not run with \(difference.removed.joined(separator: ", "))")
        }
        return Declaration.Finding(
            code: FindingCode.staleSidecar,
            text: "the sidecar declares a different set of keys than the box runs with: "
                + parts.joined(separator: ", and "))
    }
}

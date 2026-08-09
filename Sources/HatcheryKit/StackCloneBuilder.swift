import Foundation

/// Creates a planned clone: the stack, its services, their config, their databases — and then
/// asks tofu whether the result deploys.
///
/// One implementation, because the CLI and the dashboard each had their own copy of this loop,
/// line for line, and every fix had to be made twice. The planner was extracted for exactly that
/// reason; this is the other half.
public struct StackCloneBuilder: Sendable {
    public struct Options: Sendable {
        public let target: String
        public let tofuDir: String
        public let host: String?
        public let environment: Environment
        /// Overrides for the shapes read from the source's tofu files. Nil means use what the
        /// source used; the old defaults (8080, no network) are the last resort, not the first.
        public let port: Int?
        public let network: String?
        public let gated: Bool?
        /// Run `tofu apply` after a clean plan, so the clone ends running rather than written.
        public let apply: Bool

        public init(
            target: String, tofuDir: String, host: String? = nil, environment: Environment,
            port: Int? = nil, network: String? = nil, gated: Bool? = nil, apply: Bool = false
        ) {
            self.target = target
            self.tofuDir = tofuDir
            self.host = host
            self.environment = environment
            self.port = port
            self.network = network
            self.gated = gated
            self.apply = apply
        }
    }

    public struct ServiceOutcome: Sendable {
        public let name: String
        /// How many config values landed in the service's file without a person.
        public let resolved: Int
        /// What database provisioning did, one line per assertion. Empty when the service
        /// needs no database.
        public let databaseReport: [String]
        /// Keys a person still has to supply before the service boots.
        public let unresolved: [ClonedKey]
        /// Optional keys the source set that the clone dropped — not blockers, but the clone
        /// is quietly less than its source until someone decides about them.
        public let optionalSkipped: [ClonedKey]
    }

    public struct Outcome: Sendable {
        public let manifest: StackManifest
        public let manifestPath: String
        public let services: [ServiceOutcome]
        public let sealed: String?
        /// What `tofu plan` said about the finished clone, when it could be asked.
        public let plan: PlanOutcome?
        public let applied: String?
        /// Why an asked-for apply did not run.
        public let applySkipped: String?

        public var unresolvedCount: Int {
            services.reduce(0) { $0 + $1.unresolved.count }
        }
    }

    /// The worst outcome this has: services written, then the target vanished mid-loop.
    public struct HalfWritten: Error, CustomStringConvertible {
        public let target: String
        public let written: [String]
        public let manifestPath: String

        public var description: String {
            "'\(target)' vanished from the manifest mid-clone after "
                + "[\(written.joined(separator: ", "))] were written; inspect \(manifestPath)"
        }
    }

    private let bootstrapper: StackBootstrapper
    private let scaffolder: Scaffolder
    private let deployer: Deployer
    private let provisioner: DatabaseProvisioner
    private let readConfig: @Sendable (URL) throws -> [String: String]
    private let writeConfig: @Sendable (URL, [String: String]) throws -> Void
    private let saveManifest: @Sendable (StackManifest, String) throws -> Void
    private let sealState: @Sendable (String) async -> String?
    private let readShapes: @Sendable (String) -> [String: ServiceShape]

    public init(
        bootstrapper: StackBootstrapper = StackBootstrapper(),
        scaffolder: Scaffolder = Scaffolder(),
        deployer: Deployer = Deployer(),
        provisioner: DatabaseProvisioner = DatabaseProvisioner(),
        readConfig: @escaping @Sendable (URL) throws -> [String: String] = {
            try ConfigSync.readDeclared(at: $0)
        },
        writeConfig: @escaping @Sendable (URL, [String: String]) throws -> Void = {
            try ConfigSync.encoded($1).write(to: $0)
        },
        saveManifest: @escaping @Sendable (StackManifest, String) throws -> Void = {
            try $0.encoded().write(to: URL(fileURLWithPath: $1))
        },
        sealState: @escaping @Sendable (String) async -> String? = {
            await StateMaintenance.seal(after: $0)
        },
        readShapes: @escaping @Sendable (String) -> [String: ServiceShape] = {
            TofuShapeReader.shapes(inTofuDirectory: $0)
        }
    ) {
        self.bootstrapper = bootstrapper
        self.scaffolder = scaffolder
        self.deployer = deployer
        self.provisioner = provisioner
        self.readConfig = readConfig
        self.writeConfig = writeConfig
        self.saveManifest = saveManifest
        self.sealState = sealState
        self.readShapes = readShapes
    }

    /// `onProgress` narrates as the work happens — one line per step, the same lines the
    /// outcome summarises — so a watchable job has something to show while a full-copy
    /// database dump takes its time. The default swallows them; the CLI reads the outcome.
    public func build(
        planned: PlannedClone,
        source: StackSpec,
        manifest: StackManifest,
        manifestPath: String,
        options: Options,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Outcome {
        var settings = source.settings ?? [:]
        let host = options.host ?? source.host ?? settings["host"] ?? ""
        settings["host"] = host

        let plan = try bootstrapper.plan(
            name: options.target, backend: source.backend, host: host,
            tofuDir: options.tofuDir, environment: options.environment, settings: settings,
            into: manifest, manifestPath: manifestPath)
        let created = try await bootstrapper.create(plan)
        try saveManifest(created.manifest, created.manifestPath)
        onProgress("created \(options.target) in \(options.tofuDir), tofu init ok")

        // What the source's declarations actually say each app uses — port, network, gating —
        // keyed by app name. The clone keeps service names, so the lookup is direct.
        let shapes = source.tofu.map { readShapes($0.directory) } ?? [:]

        var current = created.manifest
        var written: [String] = []
        var outcomes: [ServiceOutcome] = []
        // One database, one set of credentials: services sharing a source database share the
        // cloned one, and re-minting on the second service would lock the first one out.
        var credentials: [String: DatabaseCredentials] = [:]

        for service in planned.plan.services {
            guard let stack = current.stack(named: options.target) else {
                throw HalfWritten(
                    target: options.target, written: written, manifestPath: created.manifestPath)
            }

            // Siblings are the services already added to *this* clone, so shared keys are
            // shared within the new stack rather than carried from the source.
            var siblings: [String: [String: String]] = [:]
            for existing in stack.services {
                let url = ConfigSync.configURL(
                    for: existing, in: stack, manifestPath: created.manifestPath)
                if let config = try? readConfig(url) { siblings[existing.name] = config }
            }

            let spec = ServiceSpec(
                name: service.name, kind: service.kind, image: service.image,
                domains: service.domains, configFile: "\(service.name).config.json",
                baseURL: service.baseURL, healthPath: service.healthPath)

            // Source-side facts stay keyed by the source's name; the clone's own name is new.
            let shape = shapes[service.sourceName]
            let result = try await scaffolder.plan(
                service: spec, into: options.target, manifest: current,
                containerPort: options.port ?? shape?.containerPort ?? 8080,
                network: options.network ?? shape?.network,
                gated: options.gated ?? shape?.gated ?? false,
                siblings: siblings)
            try scaffolder.write(result, in: stack)
            current = result.manifest
            try saveManifest(current, created.manifestPath)

            // The carried and rewritten values, plus whatever the database provisioning
            // resolved, layered over what the scaffolder wrote.
            onProgress("scaffolded \(service.name)")
            var values = service.values
            var databaseReport: [String] = []
            var unresolved = service.unresolved
            if let databasePlan = service.database {
                onProgress(
                    "database \(databasePlan.database) on \(databasePlan.serverApp): "
                        + databasePlan.mode.rawValue + "…")
                do {
                    let minted: DatabaseCredentials
                    if let cached = credentials[databasePlan.identity] {
                        minted = cached
                        databaseReport.append(
                            "database \(databasePlan.database) shared with an earlier service; "
                                + "credentials reused")
                    } else {
                        let provisioned = try await provisioner.provision(
                            databasePlan, host: host, admin: settings["db_admin"])
                        minted = provisioned.credentials
                        databaseReport = provisioned.report
                        credentials[databasePlan.identity] = minted
                    }
                    values.merge(databasePlan.values(minted)) { _, new in new }
                } catch {
                    // A database that could not be provisioned is the old world, not a dead
                    // clone: the keys go back on the person's checklist with the reason.
                    databaseReport.append("provisioning failed: \(error)")
                    unresolved += service.keys.filter {
                        if case .provisioned = $0.disposition { return $0.required }
                        return false
                    }
                }
            }

            if let target = current.stack(named: options.target),
                let landed = target.service(named: service.name) {
                let url = ConfigSync.configURL(
                    for: landed, in: target, manifestPath: created.manifestPath)
                let existing = (try? readConfig(url)) ?? [:]
                try writeConfig(url, ConfigSync.applying(values, to: existing))
            }

            for line in databaseReport { onProgress("  " + line) }
            onProgress(
                "\(service.name): \(values.count) value(s) resolved, "
                    + "\(unresolved.count) still needed")
            written.append(service.name)
            outcomes.append(
                ServiceOutcome(
                    name: service.name, resolved: values.count,
                    databaseReport: databaseReport, unresolved: unresolved,
                    optionalSkipped: service.keys.filter {
                        $0.disposition.needsPerson && !$0.required
                    }))
        }

        let sealed = await sealState(created.manifestPath)
        if let sealed { onProgress(sealed) }

        // The clone exists on disk; now ask tofu whether it deploys. Stopping at written files
        // was the old behaviour, and it meant nothing was ever created on the box.
        var planOutcome: PlanOutcome?
        var applied: String?
        var applySkipped: String?
        let stillNeeded = outcomes.reduce(0) { $0 + $1.unresolved.count }
        if let targetStack = current.stack(named: options.target) {
            planOutcome = try? await deployer.tofuPlan(in: targetStack)
            if options.apply {
                if stillNeeded > 0 {
                    applySkipped =
                        "\(stillNeeded) key(s) still need a person; run `hatchery apply` once they are set"
                } else if planOutcome == nil || planOutcome?.verdict == .failed {
                    applySkipped = "tofu plan did not evaluate; nothing applied"
                } else {
                    applied = try await deployer.tofuApply(in: targetStack)
                    // The front door opens only after the apply succeeds: the app must
                    // exist before its name routes anywhere. Failures narrate — the stack
                    // is live either way, and the transcript names the missing grant.
                    if let acting = Exposure.provider(for: targetStack) as? ActingExposureProvider {
                        onProgress("opening the front door…")
                        await acting.expose(
                            domains: targetStack.services.flatMap(\.domains),
                            stack: targetStack, onProgress: onProgress)
                    }
                }
            }
        }

        return Outcome(
            manifest: current, manifestPath: created.manifestPath, services: outcomes,
            sealed: sealed, plan: planOutcome, applied: applied, applySkipped: applySkipped)
    }
}

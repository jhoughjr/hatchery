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
    /// A job carries a credential in its plist or its unit, where every account on the machine can read it.
    public static let secretInPlist = "secret-in-plist"
    /// A job writes its log where nothing reads it back: under `/tmp`, or nowhere at all.
    public static let noLog = "no-log"
    /// A key the contract marks secret declares no rotation, so only a person can replace it.
    public static let secretNoRotation = "secret-no-rotation"
    /// How many of a service's secrets declare a rotation, and how many do not.
    public static let rotationCoverage = "rotation-coverage"
    /// The box holds a different proxy map than the kind file declares, so the app answers somewhere else.
    public static let portMapDrift = "port-map-drift"
    /// A resolver answers nothing at the box's LAN address, so every host that points at it is blind.
    public static let resolverSilent = "resolver-silent"
    /// A resolver answers, and answers a name with something the declaration does not name.
    public static let resolverWrongAnswer = "resolver-wrong-answer"
    /// The conf the box mounts is not the conf the declaration renders, so somebody edited it by hand.
    public static let resolverConfDrift = "resolver-conf-drift"
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
        // The rotation findings read the kind file alone, so they hold for a job as much as for an app.
        // They are added before the job arm below, which returns.
        if let kind = try? registry.kindFile(for: service.kind) {
            findings += Self.rotationFindings(in: kind)
            findings += await self.portMapFindings(for: service, in: stack, kind: kind)
            findings += await self.resolverFindings(for: service, in: stack, kind: kind)
            findings += await self.resolverConfFindings(for: service, in: stack, kind: kind)
        }
        // A job's findings are its own, plus its sidecar's. Its environment lives in no container, so the live read
        // below would ask the daemon about a name it has never heard of, once per job, and learn nothing.
        if service.job != nil {
            findings += Self.jobFindings(for: service, platform: stack.platform)
            let jobSidecarURL = ConfigSync.configURL(for: service, in: stack, manifestPath: manifestPath)
            if let jobSidecar = try? ConfigSync.readDeclared(at: jobSidecarURL) {
                let contract = EnvContract.contract(
                    for: service.kind, backend: stack.backend, registry: registry)
                findings += Self.secretInSidecar(jobSidecar, under: contract)
            }
            return findings
        }

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

    /// Whether the conf the box mounts is the one the declaration renders.
    ///
    /// The names a resolver answers used to live in the declaration and in a file a person edited on the box, which is two
    /// copies of one fact with nothing holding them equal. The declaration is the record now and the file is rendered from
    /// it, so a difference is an edit somebody made by hand.
    ///
    /// Comments and order are thrown away before comparing. A reworded comment is not a fault, and reporting it as one
    /// teaches a reader to skip the finding.
    func resolverConfFindings(
        for service: ServiceSpec, in stack: StackSpec, kind: KindFile
    ) async -> [Declaration.Finding] {
        guard kind.resolves != nil || kind.forwards != nil else { return [] }
        guard let host = stack.host, !host.isEmpty else { return [] }
        // The conf the container actually mounts, rather than a path typed here that could name a file nothing reads.
        guard let mount = service.container?.mounts.first(where: { $0.target == "/etc/dnsmasq.conf" }) else { return [] }
        guard let conf = try? await self.reader.file(at: mount.source, on: host) else { return [] }

        let (extra, missing) = DnsConf.drift(declared: kind, onBox: conf)
        guard !extra.isEmpty || !missing.isEmpty else { return [] }
        var parts: [String] = []
        if !missing.isEmpty { parts.append("the conf is missing \(missing.joined(separator: " "))") }
        if !extra.isEmpty { parts.append("it carries \(extra.joined(separator: " ")) that the declaration does not") }
        return [
            Declaration.Finding(
                code: FindingCode.resolverConfDrift,
                text: "\(mount.source) is not what the declaration renders: " + parts.joined(separator: ", "))
        ]
    }

    /// Whether the box's resolver still answers the names its kind declares.
    ///
    /// A container that runs is not a resolver that resolves. On 2026-09-10 dnsmasq read `Up` for two hours while answering
    /// nobody, because it bound loopback alone, and the one machine that pointed at it could resolve nothing at all.
    /// The question is therefore asked at the LAN address of the box the service runs on. A loopback answer proves only that
    /// the process is alive, which was never the thing in doubt.
    ///
    /// The first silent name ends the pass. A resolver that answers nothing answers nothing for every name, and four findings
    /// saying so is four ways of reading the same fault.
    func resolverFindings(
        for service: ServiceSpec, in stack: StackSpec, kind: KindFile
    ) async -> [Declaration.Finding] {
        guard let declared = kind.resolves, !declared.isEmpty else { return [] }
        guard let host = stack.host, !host.isEmpty else { return [] }
        let address = host.split(separator: "@").last.map(String.init) ?? host

        var findings: [Declaration.Finding] = []
        for resolution in declared {
            guard let answers = try? await self.reader.resolve(resolution.name, at: address, on: host) else { return findings }
            guard !answers.isEmpty else {
                findings.append(
                    Declaration.Finding(
                        code: FindingCode.resolverSilent,
                        text: "\(resolution.name) gets no answer at \(address); every host that points here resolves nothing"))
                return findings
            }
            if let expected = resolution.answer, !answers.contains(expected) {
                findings.append(
                    Declaration.Finding(
                        code: FindingCode.resolverWrongAnswer,
                        text: "\(resolution.name) answers \(answers.joined(separator: " ")) and the declaration says \(expected)"))
            }
        }
        return findings
    }

    /// Whether the box still holds the proxy map the kind file declares.
    ///
    /// A deploy from an image re-detects the map from the image's `EXPOSE` and overwrites it. The app stays healthy and stops answering at its own name, and dokku reports both maps without saying that one of them is wrong.
    /// Only a service that declares a map is asked, so this costs one call for the services that made a claim and none for the rest.
    func portMapFindings(
        for service: ServiceSpec, in stack: StackSpec, kind: KindFile
    ) async -> [Declaration.Finding] {
        guard stack.backend == .dokku, let declared = kind.portMap, !declared.isEmpty else { return [] }
        guard let live = try? await self.reader.portMap(for: service, in: stack) else { return [] }
        guard Set(live) != Set(declared) else { return [] }
        let held = live.isEmpty ? "nothing" : live.joined(separator: " ")
        return [
            Declaration.Finding(
                code: FindingCode.portMapDrift,
                text: "the box maps \(held) and the declaration says \(declared.joined(separator: " ")); a deploy re-detected the map from the image")
        ]
    }

    /// What a service's own kind file says about replacing its secrets.
    ///
    /// This reads no box. A rotation is a declaration, so the whole answer is in the kind file, which is what
    /// lets a published document carry it beside the gap.
    ///
    /// Only key names appear in the text, the same rule the other findings keep. The coverage line is a
    /// finding rather than a new field, because the document already has one shape for a fact about a service.
    static func rotationFindings(in kind: KindFile) -> [Declaration.Finding] {
        let rotations = kind.secretRotations()
        guard !rotations.isEmpty else { return [] }

        let missing = rotations.filter { $0.rotation == nil }
        var findings = missing.map { entry in
            Declaration.Finding(
                code: FindingCode.secretNoRotation,
                text: "\(entry.key) is a secret with no declared rotation, so only a person can replace it; "
                    + "declare its issuer and its holders in the kind file")
        }
        findings.append(
            Declaration.Finding(
                code: FindingCode.rotationCoverage,
                text: "\(rotations.count - missing.count) of \(rotations.count) secret(s) declare a rotation, "
                    + "and \(missing.count) do not"))
        return findings
    }

    /// The flags that carry a credential on a command line.
    ///
    /// A plist and a unit both hold the whole command line, and `ps` shows it to every account on the machine.
    /// A value behind one of these flags is therefore already read by anything that cares to look.
    static let credentialFlags = [
        "--token", "--password", "--secret", "--api-key", "--apikey", "--auth", "--key",
    ]

    /// What a job's own declaration says that is wrong with the saying of it.
    ///
    /// This reads no box. Both findings are true of the manifest alone, which is what lets a manifest write publish
    /// them and what makes them the two a person can fix without ssh.
    static func jobFindings(for service: ServiceSpec, platform: HostPlatform = .linux) -> [Declaration.Finding] {
        guard let job = service.job else { return [] }
        var findings: [Declaration.Finding] = []

        if let flag = Self.credentialFlag(in: job.program) {
            findings.append(
                Declaration.Finding(
                    code: FindingCode.secretInPlist,
                    text: "the job passes \(flag) on its command line, where ps shows it to every account "
                        + "on the machine; set environmentFromVault and read it from vault at start"))
        }
        let path = job.log ?? ""
        // A log under /tmp is always a finding. An absent log (empty path) is a finding on darwin
        // but not on linux, where the journal is the default.
        if path.hasPrefix("/tmp/") || (path.isEmpty && platform == .darwin) {
            findings.append(
                Declaration.Finding(
                    code: FindingCode.noLog,
                    text: path.isEmpty
                        ? "the job names no log, so nothing off the box can read what it did"
                        : "the job logs to \(path), which is cleared on reboot"))
        }
        return findings
    }

    /// The keys in a job's sidecar that hold a credential, one finding each.
    ///
    /// This follows the rule the adopt split follows. A contract that knows the key answers for it in both
    /// directions, and every other key falls to the name rule, so a credential nobody declared is still reported.
    /// A job usually declares no kind file, and then the name rule is the whole answer.
    /// Only key names appear in the text, the same rule the other findings keep.
    static func secretInSidecar(
        _ sidecar: [String: String], under contract: EnvContract?
    ) -> [Declaration.Finding] {
        sidecar.keys
            .filter { key in
                guard let contract, contract.recognizes(key) else {
                    return EnvContract.isSecretEnvironmentName(key)
                }
                return contract.secret.contains(key)
            }
            .sorted()
            .map {
                Declaration.Finding(
                    code: FindingCode.secretInSidecar,
                    text: "\($0) is a secret still in the sidecar; hatchery config split moves it out")
            }
    }

    /// The first credential flag that carries a non-redacted value, or `nil` when the command line names none.
    ///
    /// A flag at the very end of the arguments carries nothing, so it is a flag rather than a credential.
    /// A value that is already redacted as `${...}` is not reported.
    static func credentialFlag(in program: [String]) -> String? {
        for (index, argument) in program.enumerated() {
            let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            guard Self.credentialFlags.contains(name.lowercased()) else { continue }
            if argument.contains("=") {
                let parts = argument.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let value = String(parts[1])
                    if !value.hasPrefix("${") || !value.hasSuffix("}") {
                        return name
                    }
                }
            } else if index + 1 < program.count {
                let value = program[index + 1]
                if !value.hasPrefix("${") || !value.hasSuffix("}") {
                    return name
                }
            }
        }
        return nil
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

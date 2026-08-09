import Foundation
import HatcheryKit

/// One HTTP request, reduced to what the API needs.
///
/// A value rather than a connection, so every route is testable without a socket.
public struct WebRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased, because HTTP header names are case-insensitive.
    public var headers: [String: String]
    public var body: Data

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct WebResponse: Sendable, Equatable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int, contentType: String, body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public var text: String {
        String(decoding: body, as: UTF8.self)
    }

    static func html(_ markup: String, status: Int = 200) -> WebResponse {
        WebResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(markup.utf8))
    }

    static func json(_ value: some Encodable, status: Int = 200) -> WebResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return WebResponse(status: status, contentType: "application/json", body: body)
    }

    static func failure(_ status: Int, _ message: String) -> WebResponse {
        json(["error": message], status: status)
    }
}

/// The shapes the page exchanges with the API.
enum Wire {
    struct ServiceView: Encodable {
        let name: String
        let kind: String
        let image: String
        let domains: [String]
        let state: String?
        let reasons: [String]
        let latencyMs: Int?
        let gitRev: String?
        /// Whether the declared config would let it boot, and what is missing if not.
        let config: ConfigStatus?
    }

    struct StackView: Encodable {
        let name: String
        let backend: String
        let environment: String
        let isProduction: Bool
        let state: String?
        let services: [ServiceView]
    }

    struct LifecycleBody: Decodable {
        let stack: String
        let service: String?
        let action: String
        let confirm: String
    }

    struct DeployBody: Decodable {
        let stack: String
        let service: String
        let image: String?
        let apply: Bool?
        let confirm: String
    }

    struct ActionResult: Encodable {
        let ok: Bool
        let message: String
        let detail: String?
    }

    /// One health transition, ready to render: the timestamp is already a string and the
    /// sentence already composed, so the page never re-derives either.
    struct EventView: Encodable {
        let at: String
        let stack: String
        let service: String
        let from: String
        let to: String
        let worsened: Bool
        let improved: Bool
        let line: String
    }

    struct NewStackBody: Decodable {
        let name: String
        let host: String
        let tofuDir: String
        let backend: String?
        let environment: String?
        let sshKey: String?
        let settings: [String: String]?
        let confirm: String
    }

    struct NewServiceBody: Decodable {
        let stack: String
        let name: String
        let kind: String
        let domains: [String]
        let image: String
        let network: String?
        let port: Int?
        let gated: Bool?
        let mintKeypair: Bool?
        let confirm: String
    }

    struct SetConfigBody: Decodable {
        let stack: String
        let service: String
        let values: [String: String]
        let confirm: String
    }

    struct ClonePlanBody: Decodable {
        let source: String
        let target: String
        let environment: String?
        /// When given, the plan also checks the directory would be accepted — so a full
        /// directory is a line on the plan screen, not a refusal after the create click.
        let tofuDir: String?
    }

    struct CloneBody: Decodable {
        let source: String
        let target: String
        let environment: String?
        let tofuDir: String
        let host: String?
        let port: Int?
        let network: String?
        let gated: Bool?
        let confirm: String
        /// Run `tofu apply` after a clean plan, so the clone ends running rather than written.
        let apply: Bool?
    }

    /// One key's fate in a clone plan. `action` is the CLI's vocabulary — carry, rewrite,
    /// mint, needs, skip — so the two surfaces describe a clone in the same words.
    struct CloneKeyView: Encodable {
        let key: String
        let action: String
        /// Why it was refused, or how it is minted.
        let detail: String?
        /// The rewrite, shown only for keys that are not secret.
        let from: String?
        let to: String?
        /// The carried value, withheld for secret keys — the browser gets names, not values.
        let value: String?
        let required: Bool
        let secret: Bool
    }

    struct CloneServiceView: Encodable {
        let name: String
        let kind: String
        /// Where this service's config was read from: the box, or the declared file.
        let origin: String
        let domains: [String]
        let keys: [CloneKeyView]
    }

    struct ClonePlanView: Encodable {
        let source: String
        let target: String
        let environment: String
        let carried: Int
        let unresolved: Int
        let services: [CloneServiceView]
        /// Why the create would be refused as things stand — an occupied tofu directory,
        /// mostly. The plan is still shown; this line is what to fix before creating.
        let warning: String?
    }

    struct CloneCreated: Encodable {
        let ok: Bool
        let message: String
        let services: [ClonedSummary]
        /// The seal line, when the state directory seals.
        let detail: String?
        /// What `tofu plan` said about the finished clone, and whether an apply ran.
        let plan: String?
        let applied: Bool?
        let applySkipped: String?

        struct ClonedSummary: Encodable {
            let name: String
            let carried: Int
            let missing: [MissingKey]
            /// What database provisioning did for this service, one line per assertion.
            let database: [String]
        }
    }

    struct ApplyBody: Decodable {
        let stack: String
        let confirm: String
    }

    /// A key that still needs a person, and why hatchery could not supply it.
    struct MissingKey: Encodable {
        let key: String
        let reason: String
        let secret: Bool
    }

    struct ServiceCreated: Encodable {
        let ok: Bool
        let message: String
        let files: [String]
        let origins: [Origin]
        let missing: [MissingKey]

        struct Origin: Encodable {
            let key: String
            let origin: String
        }
    }

    struct LogsView: Encodable {
        let service: String
        let lines: [LogLine]
    }

    struct ConfigView: Encodable {
        let service: String
        let kind: String
        let image: String
        let domains: [String]
        /// Declared values, with secrets replaced by a fingerprint. Never the value.
        let declared: [String: String]
        let secretKeys: [String]
        /// Required keys with no value, so the editor can offer a field for each.
        let missingKeys: [String]
        let issues: [ValidationIssue]
        let source: String
        /// Why `source` is "declared" when it is — "not implemented for this backend" is a
        /// different situation from "the box did not answer", and the page should say which.
        let note: String?
    }

    struct PlanView: Encodable {
        let ok: Bool
        let message: String
        let summary: PlanSummary
    }

    /// A provider as the dashboard lists it, before any readiness check has run.
    struct BackendView: Encodable {
        let name: String
        let label: String
        let authorable: Bool
        let settings: [BackendSetting]
        /// How many declared stacks use it.
        let stackCount: Int
        /// A host from an existing stack, so readiness can be checked against something real
        /// rather than reported as "no host given" for a backend that plainly has one.
        let knownHost: String?
        let note: String?
    }

    struct Kinds: Encodable {
        /// Backends, each saying whether hatchery can author into it today.
        struct BackendOption: Encodable {
            let name: String
            let label: String
            let authorable: Bool
            /// Whether creating one needs an SSH target. AWS does not; dokku cannot do without.
            let settings: [BackendSetting]
            let note: String?
        }

        let kinds: [String]
        let backends: [BackendOption]
        let environments: [String]
    }
}

/// Serves the dashboard and the small API behind it.
///
/// Every mutation is confirmed *here* rather than in the browser. A dialog is a convenience for
/// the person clicking; it is not a control, because anything can post to this endpoint. So the
/// request carries the name of what it is about to change, and a mismatch is refused.
public struct HatcheryAPI: Sendable {
    private let loadManifest: @Sendable () throws -> StackManifest
    private let saveManifest: @Sendable (StackManifest, String) throws -> Void
    private let manifestPath: @Sendable () -> String
    private let reporter: StatusReporter
    private let lifecycle: LifecycleRunner
    private let deployer: Deployer
    private let scaffolder: Scaffolder
    private let bootstrapper: StackBootstrapper
    private let logReader: LogReader
    private let liveConfig: LiveConfigReader
    private let clonePlanner: StackClonePlanner
    private let provisioner: DatabaseProvisioner
    private let readConfig: @Sendable (URL) throws -> [String: String]
    private let writeConfig: @Sendable (URL, [String: String]) throws -> Void
    private let sealState: @Sendable (String) async -> String?
    private let verifyState: @Sendable (String) async -> SealVerification
    private let history: @Sendable (Int) -> [HealthTransition]
    private let token: String?

    public init(
        loadManifest: @escaping @Sendable () throws -> StackManifest,
        saveManifest: @escaping @Sendable (StackManifest, String) throws -> Void = { manifest, path in
            try manifest.encoded().write(to: URL(fileURLWithPath: path))
        },
        manifestPath: @escaping @Sendable () -> String = { ManifestLocator.defaultName },
        reporter: StatusReporter = StatusReporter(),
        lifecycle: LifecycleRunner = LifecycleRunner(),
        deployer: Deployer = Deployer(),
        scaffolder: Scaffolder = Scaffolder(),
        bootstrapper: StackBootstrapper = StackBootstrapper(),
        logReader: LogReader = LogReader(),
        liveConfig: LiveConfigReader = LiveConfigReader(),
        clonePlanner: StackClonePlanner = StackClonePlanner(),
        provisioner: DatabaseProvisioner = DatabaseProvisioner(),
        readConfig: @escaping @Sendable (URL) throws -> [String: String] = {
            (try? ConfigSync.readDeclared(at: $0)) ?? [:]
        },
        writeConfig: @escaping @Sendable (URL, [String: String]) throws -> Void = { url, config in
            try ConfigSync.encoded(config).write(to: url)
        },
        // Injected so a test never shells out. A directory with no `.age-recipient` returns
        // without running anything, which is why the live default is safe here. Both defaults
        // must stay named references: a closure literal in this position crashes the task
        // allocator at the first await through it (issue #36).
        sealState: @escaping @Sendable (String) async -> String? = StateMaintenance.liveSeal,
        verifyState: @escaping @Sendable (String) async -> SealVerification
            = SealVerifier.liveVerify,
        // The default serves an empty history rather than failing, so an API built without
        // a watcher (tests, one-shot tools) still answers the route.
        history: @escaping @Sendable (Int) -> [HealthTransition] = { _ in [] },
        token: String? = nil
    ) {
        self.loadManifest = loadManifest
        self.saveManifest = saveManifest
        self.manifestPath = manifestPath
        self.reporter = reporter
        self.lifecycle = lifecycle
        self.deployer = deployer
        self.scaffolder = scaffolder
        self.bootstrapper = bootstrapper
        self.logReader = logReader
        self.liveConfig = liveConfig
        self.clonePlanner = clonePlanner
        self.provisioner = provisioner
        self.readConfig = readConfig
        self.writeConfig = writeConfig
        self.sealState = sealState
        self.verifyState = verifyState
        self.history = history
        self.token = token
    }

    public func handle(_ request: WebRequest) async -> WebResponse {
        if request.path.hasPrefix("/api/"), let response = authorize(request) {
            return response
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return .html(Page.markup)
        case ("GET", "/api/stacks"):
            return stacks()
        case ("GET", "/api/status"):
            return await status()
        case ("POST", "/api/lifecycle"):
            return await runLifecycle(request)
        case ("POST", "/api/deploy"):
            return await runDeploy(request)
        case ("GET", "/api/hosts"):
            let manifest = (try? loadManifest()) ?? StackManifest()
            return .json(
                HostRegistry.known(saved: manifest.savedHosts, stacks: manifest.stacks)
                    .map { ["name": $0.name ?? "", "target": $0.target] })
        case ("GET", "/api/backends"):
            return backends()
        case ("GET", "/api/kinds"):
            return .json(
                Wire.Kinds(
                    kinds: ServiceKind.known.map(\.rawValue),
                    // Whether a backend can be authored is asked of the provider registry rather
                    // than hardcoded here, so a new provider shows up in the menu by existing.
                    backends: Backend.allCases.map { backend in
                        let authorable = (try? Providers.provider(for: backend)) != nil
                        let support = Providers.support(for: backend)
                        return Wire.Kinds.BackendOption(
                            name: backend.rawValue,
                            label: support.displayName,
                            authorable: authorable,
                            settings: support.settings,
                            note: authorable ? nil : "\(support.displayName) stacks cannot be created by hatchery yet")
                    },
                    environments: [
                        Environment.dev.rawValue, Environment.staging.rawValue,
                        Environment.prod.rawValue,
                    ]))
        case ("POST", "/api/stacks/new"):
            return await createStack(request)
        case ("POST", "/api/services/new"):
            return await createService(request)
        case ("POST", "/api/stack/clone/plan"):
            return await clonePlan(request)
        case ("POST", "/api/stack/clone"):
            return await cloneStack(request)
        case ("POST", "/api/config/set"):
            return await setConfig(request)
        case ("GET", "/api/state"):
            return stateStatus()
        case ("POST", "/api/state/seal"):
            return await sealNow()
        case ("POST", "/api/state/verify"):
            return await verifyNow()
        case ("POST", "/api/apply"):
            return await runApply(request)
        case ("GET", "/api/logs"):
            return await logs(request)
        case ("GET", "/api/config"):
            return await config(request)
        case ("GET", "/api/setup"):
            let backend = Backend(rawValue: request.query["backend"] ?? "") ?? .dokku
            return .json(Providers.support(for: backend).setupSteps)
        case ("GET", "/api/preflight"):
            let backend = Backend(rawValue: request.query["backend"] ?? "") ?? .dokku
            return .json(await Preflight().run(backend: backend, host: request.query["host"]))
        case ("GET", "/api/history"):
            return recentEvents(request)
        default:
            return .failure(404, "no route for \(request.method) \(request.path)")
        }
    }

    /// `nil` when the request may proceed.
    func authorize(_ request: WebRequest) -> WebResponse? {
        guard let token else { return nil }
        let offered = request.headers["x-hatchery-token"] ?? request.query["token"] ?? ""
        guard Self.constantTimeEquals(offered, token) else {
            return .failure(401, "a token is required; pass it as X-Hatchery-Token")
        }
        return nil
    }

    /// Compared without an early exit, so the time taken says nothing about how much matched.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    // MARK: - Looking at one service

    /// Either the pair a request names, or the response explaining why it could not be found.
    enum Target {
        case found(StackSpec, ServiceSpec)
        case problem(WebResponse)
    }

    /// Resolves `?stack=&service=`.
    private func target(_ request: WebRequest) -> Target {
        guard let stackName = request.query["stack"], let serviceName = request.query["service"] else {
            return .problem(.failure(400, "expected ?stack=&service="))
        }
        let manifest: StackManifest
        do {
            manifest = try loadManifest()
        } catch {
            return .problem(.failure(500, "\(error)"))
        }
        guard let stack = manifest.stack(named: stackName) else {
            return .problem(.failure(404, "no stack named '\(stackName)'"))
        }
        guard let service = stack.service(named: serviceName) else {
            return .problem(.failure(404, "stack '\(stackName)' declares no service '\(serviceName)'"))
        }
        return .found(stack, service)
    }

    private func logs(_ request: WebRequest) async -> WebResponse {
        let stack: StackSpec
        let service: ServiceSpec
        switch target(request) {
        case .problem(let response): return response
        case .found(let s, let v): stack = s; service = v
        }
        let lines = request.query["lines"].flatMap { Int($0) } ?? 200
        do {
            return .json(
                Wire.LogsView(service: service.name, lines: try await logReader.logs(
                    for: service, in: stack, lines: lines)))
        } catch {
            return .failure(502, "\(error)")
        }
    }

    private func config(_ request: WebRequest) async -> WebResponse {
        let stack: StackSpec
        let service: ServiceSpec
        switch target(request) {
        case .problem(let response): return response
        case .found(let s, let v): stack = s; service = v
        }
        guard let contract = EnvContract.contract(for: service.kind, backend: stack.backend) else {
            return .failure(400, "no contract for \(service.kind.rawValue)")
        }

        // Prefer what the service is actually running with. The declared file answers a
        // different question, and `config audit` exists because the two drift apart.
        var source = "live"
        var note: String?
        var values: [String: String]
        do {
            values = try await liveConfig.config(for: service, in: stack)
        } catch {
            source = "declared"
            note = "\(error)"
            let url = ConfigSync.configURL(for: service, in: stack, manifestPath: manifestPath())
            values = (try? readConfig(url)) ?? [:]
        }

        return .json(
            Wire.ConfigView(
                service: service.name,
                kind: service.kind.rawValue,
                image: service.image,
                domains: service.domains,
                // Redacted before it leaves the process, not in the browser.
                declared: ConfigValidator.redact(values, contract: contract),
                secretKeys: contract.secret.sorted(),
                // Required keys with no value. The editor needs these by name: a key that is
                // absent has nothing to render a field from, so without this the only way to
                // supply one is to type its name from memory, one at a time.
                missingKeys: contract.required.filter { (values[$0] ?? "").isEmpty }.sorted(),
                issues: ConfigValidator.validate(values, against: contract),
                source: source,
                note: note))
    }

    // MARK: - From nothing to something

    private func createStack(_ request: WebRequest) async -> WebResponse {
        guard let body = try? JSONDecoder().decode(Wire.NewStackBody.self, from: request.body) else {
            return .failure(400, "expected {name, host, tofuDir, confirm}")
        }
        guard body.confirm == body.name else {
            return .failure(400, "confirmation did not match; expected '\(body.name)'")
        }
        guard let backend = Backend(rawValue: body.backend ?? Backend.dokku.rawValue) else {
            return .failure(400, "unknown backend '\(body.backend ?? "")'")
        }

        // A manifest that does not exist yet is not an error here: that is the whole point.
        // Where it lives does not constrain anything, because a service's config resolves
        // against its own stack's tofu directory rather than against the manifest.
        let existing = try? loadManifest()
        let path = manifestPath()

        do {
            let planned = try bootstrapper.plan(
                name: body.name, backend: backend, host: body.host, tofuDir: body.tofuDir,
                environment: body.environment.map { Environment(rawValue: $0) },
                settings: body.settings ?? [:],
                into: existing, manifestPath: path)
            let created = try await bootstrapper.create(planned)
            try saveManifest(created.manifest, created.manifestPath)

            return .json(
                Wire.ActionResult(
                    ok: true,
                    message: "created '\(body.name)' in \(body.tofuDir), tofu init ok",
                    detail: created.manifestPath))
        } catch {
            return .failure(400, "\(error)")
        }
    }

    private func createService(_ request: WebRequest) async -> WebResponse {
        guard let body = try? JSONDecoder().decode(Wire.NewServiceBody.self, from: request.body) else {
            return .failure(400, "expected {stack, name, kind, domains, image, confirm}")
        }
        guard body.confirm == body.name else {
            return .failure(400, "confirmation did not match; expected '\(body.name)'")
        }
        guard !body.domains.filter({ !$0.isEmpty }).isEmpty else {
            return .failure(400, "at least one domain is required")
        }

        let manifest: StackManifest
        do {
            manifest = try loadManifest()
        } catch {
            return .failure(500, "\(error)")
        }
        guard let stack = manifest.stack(named: body.stack) else {
            return .failure(404, "no stack named '\(body.stack)'")
        }

        // Siblings are read from the running services, because sharing a signing key means
        // sharing the value the other service actually has.
        var siblings: [String: [String: String]] = [:]
        let reader = LiveConfigReader()
        for existing in stack.services {
            if let config = try? await reader.config(for: existing, in: stack) {
                siblings[existing.name] = config
            }
        }

        let service = ServiceSpec(
            name: body.name,
            kind: ServiceKind(rawValue: body.kind),
            image: body.image,
            domains: body.domains.filter { !$0.isEmpty },
            configFile: "\(body.name).config.json")

        do {
            let result = try await scaffolder.plan(
                service: service, into: body.stack, manifest: manifest,
                containerPort: body.port ?? 8080, network: body.network,
                gated: body.gated ?? false, siblings: siblings,
                mintKeypair: body.mintKeypair ?? false)
            try scaffolder.write(result, in: stack)
            try saveManifest(result.manifest, manifestPath())

            let secret = EnvContract.contract(for: service.kind, backend: stack.backend)?.secret ?? []
            return .json(
                Wire.ServiceCreated(
                    ok: true,
                    message: "created '\(body.name)'",
                    files: result.files.map(\.path),
                    // Names and where each value came from. Never the values.
                    origins: result.secrets.map {
                        Wire.ServiceCreated.Origin(key: $0.key, origin: $0.origin.label)
                    },
                    missing: result.unresolved.map {
                        if case .supplied(let reason) = $0.origin {
                            return Wire.MissingKey(
                                key: $0.key, reason: reason, secret: secret.contains($0.key))
                        }
                        return Wire.MissingKey(key: $0.key, reason: "", secret: secret.contains($0.key))
                    }))
        } catch {
            return .failure(400, "\(error)")
        }
    }

    // MARK: - Cloning a stack

    /// Loads the manifest and checks a clone's source and target make sense, shared by the
    /// plan and create routes so the two cannot disagree about what is cloneable.
    private enum CloneContext {
        case ok(StackManifest, StackSpec)
        case refused(WebResponse)
    }

    private func cloneContext(source: String, target: String) -> CloneContext {
        let manifest: StackManifest
        do {
            manifest = try loadManifest()
        } catch {
            return .refused(.failure(500, "\(error)"))
        }
        guard let stack = manifest.stack(named: source) else {
            return .refused(.failure(404, "no stack named '\(source)'"))
        }
        guard manifest.stack(named: target) == nil else {
            return .refused(
                .failure(400, "'\(target)' already exists; clone to a name that does not"))
        }
        return .ok(manifest, stack)
    }

    private func clonePlan(_ request: WebRequest) async -> WebResponse {
        guard let body = try? JSONDecoder().decode(Wire.ClonePlanBody.self, from: request.body)
        else {
            return .failure(400, "expected {source, target, environment}")
        }
        let manifest: StackManifest
        let stack: StackSpec
        switch cloneContext(source: body.source, target: body.target) {
        case .refused(let response): return response
        case .ok(let loaded, let found):
            manifest = loaded
            stack = found
        }

        let environment = Environment(rawValue: body.environment ?? "staging")
        do {
            let planned = try await clonePlanner.plan(
                stack: stack, into: body.target, environment: environment,
                manifestPath: manifestPath())

            // The same check the create would make, made now. Failing it after the create
            // click cost a whole trip through the wizard; a full directory belongs on the
            // plan screen, where the person still has the form in front of them.
            var warning: String?
            if let dir = body.tofuDir, !dir.isEmpty {
                var settings = stack.settings ?? [:]
                let host = stack.host ?? settings["host"] ?? ""
                settings["host"] = host
                do {
                    _ = try bootstrapper.plan(
                        name: body.target, backend: stack.backend, host: host,
                        tofuDir: dir, environment: environment, settings: settings,
                        into: manifest, manifestPath: manifestPath())
                } catch {
                    warning = "\(error)"
                }
            }
            return .json(view(of: planned, environment: environment, warning: warning))
        } catch {
            return .failure(400, "\(error)")
        }
    }

    private func view(
        of planned: PlannedClone, environment: Environment, warning: String? = nil
    ) -> Wire.ClonePlanView {
        Wire.ClonePlanView(
            source: planned.plan.source,
            target: planned.plan.target,
            environment: environment.rawValue,
            carried: planned.plan.carriedCount,
            unresolved: planned.plan.unresolvedCount,
            services: planned.plan.services.map { service in
                Wire.CloneServiceView(
                    name: service.name,
                    kind: service.kind.rawValue,
                    origin: planned.origins[service.name] ?? "declared file",
                    domains: service.domains,
                    keys: service.keys.sorted(by: { $0.key < $1.key }).map { key in
                        // Values are why the config file is gitignored: a secret key's value
                        // never reaches the browser, in any of the actions.
                        switch key.disposition {
                        case .carried:
                            return Wire.CloneKeyView(
                                key: key.key, action: "carry", detail: nil, from: nil, to: nil,
                                value: key.secret ? nil : key.value,
                                required: key.required, secret: key.secret)
                        case .rewritten(let from, let to):
                            return Wire.CloneKeyView(
                                key: key.key, action: "rewrite", detail: nil,
                                from: key.secret ? nil : from, to: key.secret ? nil : to,
                                value: nil, required: key.required, secret: key.secret)
                        case .minted(let how):
                            return Wire.CloneKeyView(
                                key: key.key, action: "mint",
                                detail: "\(how); the source's would grant its authority",
                                from: nil, to: nil, value: nil,
                                required: key.required, secret: key.secret)
                        case .provisioned(let how):
                            return Wire.CloneKeyView(
                                key: key.key, action: "db", detail: how,
                                from: nil, to: nil, value: nil,
                                required: key.required, secret: key.secret)
                        case .refused(let why):
                            return Wire.CloneKeyView(
                                key: key.key, action: key.required ? "needs" : "skip",
                                detail: why, from: nil, to: nil, value: nil,
                                required: key.required, secret: key.secret)
                        }
                    })
            },
            warning: warning)
    }

    /// The browser's `--create`: bootstraps the stack, scaffolds each service, and layers the
    /// carried values on — the same order the CLI does it, through the same components.
    private func cloneStack(_ request: WebRequest) async -> WebResponse {
        guard let body = try? JSONDecoder().decode(Wire.CloneBody.self, from: request.body) else {
            return .failure(400, "expected {source, target, tofuDir, confirm}")
        }
        guard body.confirm == body.target else {
            return .failure(400, "confirmation did not match; expected '\(body.target)'")
        }
        guard !body.tofuDir.isEmpty else {
            return .failure(400, "a clone needs a tofu directory for its declarations")
        }
        let manifest: StackManifest
        let sourceStack: StackSpec
        switch cloneContext(source: body.source, target: body.target) {
        case .refused(let response): return response
        case .ok(let loaded, let found):
            manifest = loaded
            sourceStack = found
        }

        // Planned server-side rather than accepted from the client: the plan the browser
        // showed is advice, and the one acted on is computed from the same inputs here.
        let environment = Environment(rawValue: body.environment ?? "staging")
        // The same line the deploy and apply routes draw: production stays on the CLI.
        if environment.isProduction {
            return .failure(
                403, "'\(body.target)' would be \(environment.rawValue); create it from the CLI")
        }
        let planned: PlannedClone
        do {
            planned = try await clonePlanner.plan(
                stack: sourceStack, into: body.target, environment: environment,
                manifestPath: manifestPath())
        } catch {
            return .failure(400, "\(error)")
        }

        do {
            // The same builder the CLI runs, with the web's own file seams, so the two
            // surfaces cannot drift apart again.
            let builder = StackCloneBuilder(
                bootstrapper: bootstrapper, scaffolder: scaffolder, deployer: deployer,
                provisioner: provisioner, readConfig: readConfig, writeConfig: writeConfig,
                saveManifest: saveManifest, sealState: sealState)
            let outcome = try await builder.build(
                planned: planned, source: sourceStack, manifest: manifest,
                manifestPath: manifestPath(),
                options: StackCloneBuilder.Options(
                    target: body.target, tofuDir: body.tofuDir, host: body.host,
                    environment: environment, port: body.port, network: body.network,
                    gated: body.gated, apply: body.apply ?? false))

            let summaries = outcome.services.map { service in
                Wire.CloneCreated.ClonedSummary(
                    name: service.name,
                    carried: service.resolved,
                    missing: service.unresolved.map {
                        let reason: String
                        if case .refused(let why) = $0.disposition {
                            reason = why
                        } else {
                            reason = "database provisioning did not finish; supply it by hand"
                        }
                        return Wire.MissingKey(key: $0.key, reason: reason, secret: $0.secret)
                    },
                    database: service.databaseReport)
            }

            let planLine: String?
            switch outcome.plan?.verdict {
            case .clean: planLine = "nothing to change"
            case .changes: planLine = "changes ready to apply"
            case .failed: planLine = "tofu plan failed; the clone is written but will not deploy as is"
            case nil: planLine = nil
            }

            return .json(
                Wire.CloneCreated(
                    ok: outcome.unresolvedCount == 0 && outcome.plan?.verdict != .failed,
                    message: "cloned '\(body.source)' → '\(body.target)' in \(body.tofuDir), "
                        + "tofu init ok",
                    services: summaries,
                    detail: outcome.sealed,
                    plan: planLine,
                    applied: outcome.applied != nil ? true : nil,
                    applySkipped: outcome.applySkipped))
        } catch let half as StackCloneBuilder.HalfWritten {
            // Half a stack with no explanation is the worst outcome this route has.
            return .failure(500, "\(half)")
        } catch {
            return .failure(400, "\(error)")
        }
    }

    private func setConfig(_ request: WebRequest) async -> WebResponse {
        guard let body = try? JSONDecoder().decode(Wire.SetConfigBody.self, from: request.body) else {
            return .failure(400, "expected {stack, service, values, confirm}")
        }
        guard body.confirm == body.service else {
            return .failure(400, "confirmation did not match; expected '\(body.service)'")
        }

        let manifest: StackManifest
        do {
            manifest = try loadManifest()
        } catch {
            return .failure(500, "\(error)")
        }
        guard let stack = manifest.stack(named: body.stack),
            let service = stack.service(named: body.service)
        else {
            return .failure(404, "no service '\(body.service)' in stack '\(body.stack)'")
        }

        // The editor renders its fields from the contract, but the API takes whatever the
        // request carries — so the same refusal-by-name the CLI applies happens here too.
        if let contract = EnvContract.contract(for: service.kind, backend: stack.backend) {
            let unknown = contract.unknownKeys(in: body.values)
            if !unknown.isEmpty {
                let hints = unknown.map { key -> String in
                    let near = contract.nearest(to: key)
                    return near.isEmpty ? key : "\(key) (nearest: \(near.joined(separator: ", ")))"
                }
                return .failure(
                    400,
                    "\(service.kind.rawValue) recognises no key named "
                        + hints.joined(separator: ", ") + "; nothing written")
            }
        }

        do {
            let url = ConfigSync.configURL(for: service, in: stack, manifestPath: manifestPath())
            let merged = ConfigSync.applying(body.values, to: try readConfig(url))
            try writeConfig(url, merged)
            // The browser writes the same gitignored file the CLI does, so it re-seals the same
            // way. A seal problem is appended rather than thrown: the config write succeeded,
            // and reporting it as a failure would invite someone to write it again.
            let sealed = await sealState(url.path)

            let contract = EnvContract.contract(for: service.kind, backend: stack.backend)
            let missing = (contract?.required ?? []).filter { (merged[$0] ?? "").isEmpty }.sorted()
            let detail = "set \(body.values.keys.sorted().joined(separator: ", "))"
            return .json(
                Wire.ActionResult(
                    ok: missing.isEmpty,
                    // Key names only; the values are why this file is gitignored.
                    message: missing.isEmpty
                        ? "every required key now has a value"
                        : "still needs: \(missing.joined(separator: ", "))",
                    detail: sealed.map { "\(detail) · \($0)" } ?? detail))
        } catch {
            return .failure(500, "\(error)")
        }
    }

    /// Where the manifest's state directory is, if it is one that seals.
    ///
    /// The manifest is commonly symlinked in from `~/.config/hatchery`, so the link is resolved
    /// before walking up — otherwise the walk climbs out of `~/.config` and finds nothing.
    private func sealedRoot() -> String? {
        let real = URL(fileURLWithPath: Paths.expanded(manifestPath()))
            .resolvingSymlinksInPath().deletingLastPathComponent().path
        return SealedState.root(containing: real)
    }

    private func stateStatus() -> WebResponse {
        guard let root = sealedRoot() else {
            // Not a sealed directory. Reported as a fact rather than an error: plenty of
            // directories are not, and the page offers setup instead of a warning.
            return .json(["sealed": false, "configured": false])
        }
        guard let status = try? SealAudit().status(root: root) else {
            return .failure(500, "could not read \(root)")
        }
        return .json(status)
    }

    private func sealNow() async -> WebResponse {
        guard let root = sealedRoot() else {
            return .failure(400, "no sealed state directory for \(manifestPath())")
        }
        let message = await sealState(root) ?? "nothing to seal"
        let after = try? SealAudit().status(root: root)
        return .json(
            Wire.ActionResult(
                ok: after?.sealed ?? false,
                message: message,
                detail: after?.summary))
    }

    /// Opens the archive rather than trusting it would open. `stateStatus` deliberately does
    /// not: it must stay cheap enough to run on every page load, and this decrypts.
    private func verifyNow() async -> WebResponse {
        guard let root = sealedRoot() else {
            return .failure(400, "no sealed state directory for \(manifestPath())")
        }
        let result = await verifyState(root)
        return .json(
            Wire.ActionResult(ok: !result.isProblem, message: result.summary, detail: root))
    }

    private func runApply(_ request: WebRequest) async -> WebResponse {
        guard let body = try? JSONDecoder().decode(Wire.ApplyBody.self, from: request.body) else {
            return .failure(400, "expected {stack, confirm}")
        }
        guard body.confirm == body.stack else {
            return .failure(400, "confirmation did not match; expected '\(body.stack)'")
        }

        let manifest: StackManifest
        do {
            manifest = try loadManifest()
        } catch {
            return .failure(500, "\(error)")
        }
        guard let stack = manifest.stack(named: body.stack) else {
            return .failure(404, "no stack named '\(body.stack)'")
        }
        // The same line the deploy route draws: production applies stay on the CLI.
        if stack.resolvedEnvironment.isProduction {
            return .failure(
                403, "'\(stack.name)' is \(stack.resolvedEnvironment.rawValue); apply it from the CLI")
        }

        do {
            let output = try await deployer.tofuApply(in: stack)
            return .json(Wire.ActionResult(ok: true, message: "applied \(stack.name)", detail: output))
        } catch {
            return .json(
                Wire.ActionResult(ok: false, message: "apply failed", detail: "\(error)"), status: 500)
        }
    }

    private func backends() -> WebResponse {
        let manifest = (try? loadManifest()) ?? StackManifest()
        let views = Backend.allCases.map { backend -> Wire.BackendView in
            let support = Providers.support(for: backend)
            let using = manifest.stacks.filter { $0.backend == backend }
            return Wire.BackendView(
                name: backend.rawValue,
                label: support.displayName,
                authorable: support.authorable,
                settings: support.settings,
                stackCount: using.count,
                knownHost: using.compactMap(\.host).first { !$0.isEmpty },
                note: support.authorable
                    ? nil : "\(support.displayName) stacks cannot be created by hatchery yet")
        }
        return .json(views)
    }

    private func stacks() -> WebResponse {
        do {
            let manifest = try loadManifest()
            let views = manifest.stacks.map { stack in
                Wire.StackView(
                    name: stack.name,
                    backend: stack.backend.rawValue,
                    environment: stack.resolvedEnvironment.rawValue,
                    isProduction: stack.resolvedEnvironment.isProduction,
                    state: nil,
                    services: stack.services.map {
                        Wire.ServiceView(
                            name: $0.name, kind: $0.kind.rawValue, image: $0.image,
                            domains: $0.domains, state: nil, reasons: [], latencyMs: nil,
                            gitRev: nil,
                            config: ConfigCompleteness.check(
                                service: $0, in: stack, manifestPath: manifestPath()))
                    })
            }
            return .json(views)
        } catch {
            return .failure(500, "\(error)")
        }
    }

    private func status() async -> WebResponse {
        do {
            let manifest = try loadManifest()
            let reports = await reporter.status(of: manifest)
            var byStack: [String: StackStatus] = [:]
            for report in reports {
                byStack[report.stack] = report
            }

            let views = manifest.stacks.map { stack -> Wire.StackView in
                let report = byStack[stack.name]
                var health: [String: ServiceHealth] = [:]
                for entry in report?.services ?? [] {
                    health[entry.service] = entry
                }
                return Wire.StackView(
                    name: stack.name,
                    backend: stack.backend.rawValue,
                    environment: stack.resolvedEnvironment.rawValue,
                    isProduction: stack.resolvedEnvironment.isProduction,
                    state: report?.state.rawValue,
                    services: stack.services.map { service in
                        let entry = health[service.name]
                        return Wire.ServiceView(
                            name: service.name, kind: service.kind.rawValue, image: service.image,
                            domains: service.domains, state: entry?.state.rawValue,
                            reasons: entry?.reasons ?? [], latencyMs: entry?.latencyMs,
                            gitRev: entry?.gitRev,
                            // A local file read, so this costs nothing on a ten-second poll.
                            config: ConfigCompleteness.check(
                                service: service, in: stack, manifestPath: manifestPath()))
                    })
            }
            return .json(views)
        } catch {
            return .failure(500, "\(error)")
        }
    }

    private func recentEvents(_ request: WebRequest) -> WebResponse {
        // Capped because the page shows a sidebar's worth; the file itself is the archive.
        let limit = min(max(request.query["limit"].flatMap { Int($0) } ?? 100, 1), 500)
        let formatter = ISO8601DateFormatter()
        return .json(
            history(limit).map { transition in
                Wire.EventView(
                    at: formatter.string(from: transition.at),
                    stack: transition.stack,
                    service: transition.service,
                    from: transition.from.rawValue,
                    to: transition.to.rawValue,
                    worsened: transition.worsened,
                    improved: transition.improved,
                    line: transition.line)
            })
    }

    private func runLifecycle(_ request: WebRequest) async -> WebResponse {
        guard let body = try? JSONDecoder().decode(Wire.LifecycleBody.self, from: request.body) else {
            return .failure(400, "expected {stack, service, action, confirm}")
        }
        guard let action = LifecycleRunner.Action(rawValue: body.action)
            ?? LifecycleRunner.Action.allCases.first(where: { $0.label == body.action })
        else {
            return .failure(400, "unknown action '\(body.action)'")
        }

        let manifest: StackManifest
        do {
            manifest = try loadManifest()
        } catch {
            return .failure(500, "\(error)")
        }
        guard let stack = manifest.stack(named: body.stack) else {
            return .failure(404, "no stack named '\(body.stack)'")
        }

        let target = body.service ?? stack.name
        guard body.confirm == target else {
            return .failure(
                400, "confirmation did not match; expected '\(target)' to change it")
        }

        if let name = body.service {
            guard let service = stack.service(named: name) else {
                return .failure(404, "stack '\(stack.name)' declares no service named '\(name)'")
            }
            let result = await lifecycle.perform(action, on: service, in: stack)
            return .json(
                Wire.ActionResult(
                    ok: result.succeeded,
                    message: "\(result.service): \(result.action) \(result.succeeded ? "ok" : "failed")",
                    detail: result.reason),
                status: result.succeeded ? 200 : 500)
        }

        let results = await lifecycle.perform(action, on: stack)
        let failed = results.filter { !$0.succeeded }
        return .json(
            Wire.ActionResult(
                ok: failed.isEmpty,
                message: "\(action.label) \(stack.name): \(results.count - failed.count)/\(results.count) ok",
                detail: failed.map { "\($0.service): \($0.reason ?? "unknown")" }
                    .joined(separator: "\n").isEmpty ? nil
                    : failed.map { "\($0.service): \($0.reason ?? "unknown")" }.joined(separator: "\n")),
            status: failed.isEmpty ? 200 : 500)
    }

    private func runDeploy(_ request: WebRequest) async -> WebResponse {
        guard let body = try? JSONDecoder().decode(Wire.DeployBody.self, from: request.body) else {
            return .failure(400, "expected {stack, service, image, apply, confirm}")
        }

        let manifest: StackManifest
        do {
            manifest = try loadManifest()
        } catch {
            return .failure(500, "\(error)")
        }
        guard let stack = manifest.stack(named: body.stack) else {
            return .failure(404, "no stack named '\(body.stack)'")
        }
        guard body.confirm == body.service else {
            return .failure(
                400, "confirmation did not match; expected '\(body.service)' to change it")
        }

        let apply = body.apply ?? false
        // Applying to production stays on the CLI. The browser is the wrong place for the one
        // action with no undo, and refusing here is clearer than a second dialog.
        if apply, stack.resolvedEnvironment.isProduction {
            return .failure(
                403,
                "'\(stack.name)' is \(stack.resolvedEnvironment.rawValue); apply it from the CLI")
        }

        do {
            let result = try await deployer.deploy(
                service: body.service, in: stack, image: body.image, apply: apply)

            if result.reverted {
                return .json(
                    Wire.ActionResult(
                        ok: false,
                        message: "plan failed; variables file put back",
                        detail: result.outcome.output),
                    status: 500)
            }
            let verdict: String
            switch result.outcome.verdict {
            case .clean: verdict = "no changes"
            case .changes: verdict = "changes pending"
            case .failed: verdict = "plan failed"
            }
            // The plan comes back structured so the page can render a diff rather than a wall
            // of text. Anything the parser does not recognise is still carried verbatim.
            let summary = PlanSummary.parse(result.applied ?? result.outcome.output)
            return .json(
                Wire.PlanView(
                    ok: result.outcome.verdict != .failed,
                    message: "\(body.service): \(result.plan.current) -> \(result.plan.target), tofu plan: \(verdict)",
                    summary: summary),
                status: result.outcome.verdict == .failed ? 500 : 200)
        } catch {
            return .failure(500, "\(error)")
        }
    }
}

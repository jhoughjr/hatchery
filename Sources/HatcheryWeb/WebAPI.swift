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
        let issues: [ValidationIssue]
        let source: String
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
    private let readConfig: @Sendable (URL) throws -> [String: String]
    private let writeConfig: @Sendable (URL, [String: String]) throws -> Void
    private let sealState: @Sendable (String) async -> String?
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
        readConfig: @escaping @Sendable (URL) throws -> [String: String] = {
            (try? ConfigSync.readDeclared(at: $0)) ?? [:]
        },
        writeConfig: @escaping @Sendable (URL, [String: String]) throws -> Void = { url, config in
            try ConfigSync.encoded(config).write(to: url)
        },
        // Injected so a test never shells out. A directory with no `.age-recipient` returns
        // without running anything, which is why the live default is safe here.
        sealState: @escaping @Sendable (String) async -> String? = { path in
            await StateMaintenance.seal(after: path)
        },
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
        self.readConfig = readConfig
        self.writeConfig = writeConfig
        self.sealState = sealState
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
        case ("POST", "/api/config/set"):
            return await setConfig(request)
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
        var values: [String: String]
        do {
            values = try await liveConfig.config(for: service, in: stack)
        } catch {
            source = "declared"
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
                issues: ConfigValidator.validate(values, against: contract),
                source: source))
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

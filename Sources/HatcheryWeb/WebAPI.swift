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
}

/// Serves the dashboard and the small API behind it.
///
/// Every mutation is confirmed *here* rather than in the browser. A dialog is a convenience for
/// the person clicking; it is not a control, because anything can post to this endpoint. So the
/// request carries the name of what it is about to change, and a mismatch is refused.
public struct HatcheryAPI: Sendable {
    private let loadManifest: @Sendable () throws -> StackManifest
    private let reporter: StatusReporter
    private let lifecycle: LifecycleRunner
    private let deployer: Deployer
    private let token: String?

    public init(
        loadManifest: @escaping @Sendable () throws -> StackManifest,
        reporter: StatusReporter = StatusReporter(),
        lifecycle: LifecycleRunner = LifecycleRunner(),
        deployer: Deployer = Deployer(),
        token: String? = nil
    ) {
        self.loadManifest = loadManifest
        self.reporter = reporter
        self.lifecycle = lifecycle
        self.deployer = deployer
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
                            gitRev: nil)
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
                            gitRev: entry?.gitRev)
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
            return .json(
                Wire.ActionResult(
                    ok: result.outcome.verdict != .failed,
                    message: "\(body.service): \(result.plan.current) -> \(result.plan.target), tofu plan: \(verdict)",
                    detail: result.applied ?? result.outcome.output),
                status: result.outcome.verdict == .failed ? 500 : 200)
        } catch {
            return .failure(500, "\(error)")
        }
    }
}

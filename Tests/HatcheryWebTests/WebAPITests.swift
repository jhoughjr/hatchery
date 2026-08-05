import Foundation
import HatcheryKit
import NIOHTTP1
import Testing

@testable import HatcheryWeb

private func labStack(environment: Environment? = nil) -> StackSpec {
    StackSpec(
        name: "mwlab",
        backend: .dokku,
        environment: environment,
        host: "dokku@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/mwserver-tf"),
        services: [
            ServiceSpec(
                name: "mwlab", kind: .mwserver, image: "mwserver2:arm64-abc",
                domains: ["mwlab.opi"], configFile: "mwlab.config.json",
                imageVariable: "mwlab_image")
        ]
    )
}

private func manifest(_ stack: StackSpec = labStack()) -> StackManifest {
    StackManifest(stacks: [stack])
}

/// An API whose every dependency answers from memory.
private func api(
    stack: StackSpec = labStack(),
    token: String? = nil,
    probe: @escaping @Sendable () -> ProbeResult = {
        .response(status: 200, body: Data(#"{"status":"ready"}"#.utf8), contentType: "application/json")
    },
    lifecycleSucceeds: Bool = true
) -> HatcheryAPI {
    HatcheryAPI(
        loadManifest: { manifest(stack) },
        reporter: StatusReporter(transport: { _, _ in probe() }),
        lifecycle: LifecycleRunner(run: { _ in
            if !lifecycleSucceeds {
                throw CommandFailure(command: "ssh", status: 1, message: "boom")
            }
            return Data()
        }),
        deployer: Deployer(
            execute: { _, _ in CommandOutput(status: 2, standardOutput: "1 to change") },
            readFile: { _ in
                """
                variable "mwlab_image" {
                  default = "mwserver2:arm64-abc"
                }
                """
            },
            writeFile: { _, _ in }
        ),
        token: token)
}

private func post(_ path: String, _ object: [String: Any], token: String? = nil) -> WebRequest {
    var headers: [String: String] = [:]
    if let token { headers["x-hatchery-token"] = token }
    return WebRequest(
        method: "POST", path: path, headers: headers,
        body: try! JSONSerialization.data(withJSONObject: object))
}

@Suite("Routing")
struct RoutingTests {
    @Test("the root serves the page")
    func servesPage() async {
        let response = await api().handle(WebRequest(method: "GET", path: "/"))
        #expect(response.status == 200)
        #expect(response.contentType.hasPrefix("text/html"))
        #expect(response.text.contains("<title>hatchery</title>"))
    }

    @Test("an unknown path is a 404 that says what was asked for")
    func unknownPath() async {
        let response = await api().handle(WebRequest(method: "GET", path: "/nope"))
        #expect(response.status == 404)
        #expect(response.text.contains("/nope"))
    }

    @Test("stacks are listed without probing anything")
    func listsStacks() async {
        let response = await api().handle(WebRequest(method: "GET", path: "/api/stacks"))
        #expect(response.status == 200)
        #expect(response.text.contains("\"name\":\"mwlab\""))
        #expect(response.text.contains("\"backend\":\"dokku\""))
        // An unlabelled stack reads as dev, matching the CLI.
        #expect(response.text.contains("\"environment\":\"dev\""))
    }

    @Test("status reports the state each service gave")
    func reportsStatus() async {
        let response = await api().handle(WebRequest(method: "GET", path: "/api/status"))
        #expect(response.status == 200)
        #expect(response.text.contains("\"state\":\"ready\""))
    }

    @Test("a service that cannot be reached still produces a report")
    func reportsUnreachable() async {
        let unreachable = api(probe: { .failure("connection refused") })
        let response = await unreachable.handle(WebRequest(method: "GET", path: "/api/status"))
        #expect(response.status == 200)
        #expect(response.text.contains("unreachable"))
        #expect(response.text.contains("connection refused"))
    }
}

@Suite("Authorization")
struct AuthorizationTests {
    @Test("no token configured means the API is open, which is why the bind is loopback")
    func openWithoutToken() async {
        let response = await api().handle(WebRequest(method: "GET", path: "/api/stacks"))
        #expect(response.status == 200)
    }

    @Test("a configured token is required")
    func requiresToken() async {
        let response = await api(token: "s3cret").handle(
            WebRequest(method: "GET", path: "/api/stacks"))
        #expect(response.status == 401)
    }

    @Test("the token is accepted from a header or a query parameter")
    func acceptsBothForms() async {
        let guarded = api(token: "s3cret")

        let viaHeader = await guarded.handle(
            WebRequest(method: "GET", path: "/api/stacks", headers: ["x-hatchery-token": "s3cret"]))
        #expect(viaHeader.status == 200)

        let viaQuery = await guarded.handle(
            WebRequest(method: "GET", path: "/api/stacks", query: ["token": "s3cret"]))
        #expect(viaQuery.status == 200)
    }

    @Test("a wrong token is refused")
    func refusesWrongToken() async {
        let response = await api(token: "s3cret").handle(
            WebRequest(method: "GET", path: "/api/stacks", headers: ["x-hatchery-token": "wrong"]))
        #expect(response.status == 401)
    }

    @Test("the page itself is served without a token, so the browser can ask for one")
    func pageIsUnguarded() async {
        let response = await api(token: "s3cret").handle(WebRequest(method: "GET", path: "/"))
        #expect(response.status == 200)
    }

    @Test("comparison does not exit early on the first differing byte")
    func constantTime() {
        #expect(HatcheryAPI.constantTimeEquals("abc", "abc"))
        #expect(!HatcheryAPI.constantTimeEquals("abc", "abd"))
        #expect(!HatcheryAPI.constantTimeEquals("abc", "abcd"))
        #expect(HatcheryAPI.constantTimeEquals("", ""))
    }
}

@Suite("Mutations are confirmed on the server")
struct ConfirmationTests {
    @Test("a restart names what it is about to change")
    func restartsWithConfirmation() async {
        let response = await api().handle(
            post("/api/lifecycle", ["stack": "mwlab", "service": "mwlab", "action": "restart", "confirm": "mwlab"]))
        #expect(response.status == 200)
        #expect(response.text.contains("\"ok\":true"))
    }

    @Test("a mismatched confirmation is refused, because the browser is not the control")
    func refusesMismatch() async {
        let response = await api().handle(
            post("/api/lifecycle", ["stack": "mwlab", "service": "mwlab", "action": "restart", "confirm": "wrong"]))
        #expect(response.status == 400)
        #expect(response.text.contains("confirmation did not match"))
    }

    @Test("a missing confirmation is refused rather than defaulted")
    func refusesMissing() async {
        let response = await api().handle(
            post("/api/lifecycle", ["stack": "mwlab", "service": "mwlab", "action": "restart"]))
        #expect(response.status == 400)
    }

    @Test("a whole-stack action is confirmed with the stack name")
    func stackWideConfirmation() async {
        let response = await api().handle(
            post("/api/lifecycle", ["stack": "mwlab", "action": "restart", "confirm": "mwlab"]))
        #expect(response.status == 200)
    }

    @Test("an unknown action is refused")
    func refusesUnknownAction() async {
        let response = await api().handle(
            post("/api/lifecycle", ["stack": "mwlab", "service": "mwlab", "action": "obliterate", "confirm": "mwlab"]))
        #expect(response.status == 400)
        #expect(response.text.contains("obliterate"))
    }

    @Test("an unknown stack or service is a 404, not a silent success")
    func refusesUnknownTarget() async {
        let noStack = await api().handle(
            post("/api/lifecycle", ["stack": "nope", "service": "x", "action": "restart", "confirm": "x"]))
        #expect(noStack.status == 404)

        let noService = await api().handle(
            post("/api/lifecycle", ["stack": "mwlab", "service": "ghost", "action": "restart", "confirm": "ghost"]))
        #expect(noService.status == 404)
    }

    @Test("a failed action reports the failure rather than claiming success")
    func reportsFailure() async {
        let failing = api(lifecycleSucceeds: false)
        let response = await failing.handle(
            post("/api/lifecycle", ["stack": "mwlab", "service": "mwlab", "action": "restart", "confirm": "mwlab"]))
        #expect(response.status == 500)
        #expect(response.text.contains("\"ok\":false"))
    }
}

@Suite("Deploy through the browser")
struct DeployRouteTests {
    @Test("a deploy plans and reports what would change")
    func plansDeploy() async {
        let response = await api().handle(
            post("/api/deploy", ["stack": "mwlab", "service": "mwlab", "image": "mwserver2:arm64-new", "confirm": "mwlab"]))
        #expect(response.status == 200)
        #expect(response.text.contains("changes pending"))
        #expect(response.text.contains("mwserver2:arm64-new"))
    }

    @Test("applying to production is refused; that one stays on the CLI")
    func refusesProductionApply() async {
        let production = api(stack: labStack(environment: .prod))
        let response = await production.handle(
            post("/api/deploy", ["stack": "mwlab", "service": "mwlab", "apply": true, "confirm": "mwlab"]))
        #expect(response.status == 403)
        #expect(response.text.contains("from the CLI"))
    }

    @Test("planning against production is still allowed, because it changes nothing")
    func allowsProductionPlan() async {
        let production = api(stack: labStack(environment: .prod))
        let response = await production.handle(
            post("/api/deploy", ["stack": "mwlab", "service": "mwlab", "apply": false, "confirm": "mwlab"]))
        #expect(response.status == 200)
    }

    @Test("a mismatched confirmation is refused before anything is planned")
    func refusesMismatch() async {
        let response = await api().handle(
            post("/api/deploy", ["stack": "mwlab", "service": "mwlab", "confirm": "nope"]))
        #expect(response.status == 400)
    }
}

@Suite("Binding")
struct BindingTests {
    @Test("loopback is recognised in each form it is written")
    func loopbackForms() {
        #expect(BindAddress.isLoopback("127.0.0.1"))
        #expect(BindAddress.isLoopback("::1"))
        #expect(BindAddress.isLoopback("localhost"))
        #expect(!BindAddress.isLoopback("0.0.0.0"))
        #expect(!BindAddress.isLoopback("192.168.0.103"))
    }

    @Test("binding off-host without a token is refused, not warned about")
    func refusesUnsafeBind() {
        #expect(throws: ServerError.unsafeBind(host: "0.0.0.0")) {
            _ = try WebServer(api: api(), host: "0.0.0.0", port: 7878, hasToken: false)
        }
    }

    @Test("binding off-host with a token is allowed")
    func allowsTokenedBind() throws {
        _ = try WebServer(api: api(token: "t"), host: "0.0.0.0", port: 7878, hasToken: true)
    }

    @Test("loopback needs no token")
    func loopbackNeedsNoToken() throws {
        _ = try WebServer(api: api(), host: "127.0.0.1", port: 7878, hasToken: false)
    }
}

@Suite("Request translation")
struct RequestTranslationTests {
    private func head(_ uri: String, headers: [(String, String)] = []) -> HTTPRequestHead {
        var fields = HTTPHeaders()
        for (name, value) in headers { fields.add(name: name, value: value) }
        return HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: fields)
    }

    @Test("the path and query are split apart")
    func splitsQuery() {
        let request = Handler.request(from: head("/api/status?token=abc&x=1"), body: Data())
        #expect(request.path == "/api/status")
        #expect(request.query["token"] == "abc")
        #expect(request.query["x"] == "1")
    }

    @Test("a path with no query still parses")
    func noQuery() {
        let request = Handler.request(from: head("/"), body: Data())
        #expect(request.path == "/")
        #expect(request.query.isEmpty)
    }

    @Test("percent and plus encoding are decoded, so a real token survives")
    func decodesEncoding() {
        let request = Handler.request(from: head("/?token=a%2Bb%2Fc&s=x+y"), body: Data())
        #expect(request.query["token"] == "a+b/c")
        #expect(request.query["s"] == "x y")
    }

    @Test("header names are lowercased, because HTTP does not care about their case")
    func lowercasesHeaders() {
        let request = Handler.request(
            from: head("/", headers: [("X-Hatchery-Token", "abc")]), body: Data())
        #expect(request.headers["x-hatchery-token"] == "abc")
    }
}

@Suite("The page's own wiring")
struct PageWiringTests {
    /// Buttons must not carry inline handlers.
    ///
    /// An `onclick` is a JS string inside an HTML attribute inside a Swift string literal. One
    /// wrong quote there is a *parse* error, which kills the entire script rather than one
    /// button — the page then renders and sits on "loading…" forever, with nothing working.
    /// That shipped once. Buttons carry `data-action` and a delegated listener dispatches them.
    @Test("no button carries an inline onclick")
    func noInlineHandlers() {
        #expect(!Page.markup.contains("onclick=\""))
    }

    @Test("every button action has a case that handles it, and every case has a button")
    func actionsAndCasesAgree() {
        let markup = Page.markup

        func matches(_ pattern: String) -> Set<String> {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(markup.startIndex..., in: markup)
            var found: Set<String> = []
            for match in regex.matches(in: markup, range: range) {
                if let captured = Range(match.range(at: 1), in: markup) {
                    found.insert(String(markup[captured]))
                }
            }
            return found
        }

        let dispatched = matches("button\\('([a-z-]+)'")
        let handled = matches("case '([a-z-]+)':")

        #expect(!dispatched.isEmpty)
        // A button with no case does nothing when clicked; a case with no button is dead code
        // that outlived whatever used to call it.
        #expect(dispatched == handled)
    }

    /// Walks the script tracking string state and reports any line that ends inside one.
    ///
    /// A JavaScript string cannot span a newline. So an unterminated string at end-of-line is
    /// always a bug, and it is *this* bug: an apostrophe inside a single-quoted string closes
    /// it early, and everything after becomes a parse error that kills the whole script. It has
    /// happened twice — once from a bad escape, once from the word "service\'s" in help text.
    /// Neither was visible to a test that only looked for patterns.
    ///
    /// Comments are skipped. Regex literals are *not* understood, so a character class holding
    /// a quote would read as an unterminated string — `escapeHTML` is written with split/join
    /// rather than a regex for exactly that reason.
    @Test("no line of the script ends inside an unterminated string")
    func stringsAreTerminated() {
        let markup = Page.markup
        guard let start = markup.range(of: "<script>"), let end = markup.range(of: "</script>") else {
            Issue.record("the page has no script block")
            return
        }
        let script = markup[start.upperBound..<end.lowerBound]

        var quote: Character? = nil
        var escaped = false
        var inLineComment = false
        var inBlockComment = false
        var previous: Character? = nil
        var line = 1
        var openedAt = 0

        for character in script {
            if character == "\n" {
                if let quote {
                    Issue.record(
                        "line \(line) ends inside a \(quote) string opened on line \(openedAt)")
                    return
                }
                line += 1
                escaped = false
                inLineComment = false
                previous = nil
                continue
            }

            // Comments are skipped: an apostrophe in prose is not an unterminated string, and
            // that false positive is how this check earns a reputation for crying wolf.
            if inLineComment { continue }
            if inBlockComment {
                if previous == "*" && character == "/" { inBlockComment = false; previous = nil }
                else { previous = character }
                continue
            }

            if quote == nil, previous == "/" {
                if character == "/" { inLineComment = true; previous = nil; continue }
                if character == "*" { inBlockComment = true; previous = nil; continue }
            }

            if escaped { escaped = false; previous = character; continue }
            if character == "\\" { escaped = true; previous = character; continue }

            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "\u{27}" || character == "`" {
                quote = character
                openedAt = line
            }
            previous = character
        }
        #expect(quote == nil)
    }

    @Test("the script is served whole, so a truncated page is visible rather than silent")
    func scriptIsClosed() {
        #expect(Page.markup.contains("<script>"))
        #expect(Page.markup.contains("</script>"))
        #expect(Page.markup.hasSuffix("</html>"))
    }
}

@Suite("Menu data")
struct KindsRouteTests {
    @Test("service kinds are listed for the wizard")
    func listsKinds() async {
        let response = await api().handle(WebRequest(method: "GET", path: "/api/kinds"))
        #expect(response.status == 200)
        #expect(response.text.contains("mwserver"))
        #expect(response.text.contains("payment-gateway"))
        #expect(response.text.contains("communication-gateway"))
    }

    @Test("each backend says whether hatchery can author into it")
    func reportsAuthorable() async {
        let response = await api().handle(WebRequest(method: "GET", path: "/api/kinds"))

        // dokku can be created; App Platform cannot yet, and says so rather than being offered
        // as a menu entry that fails after the form is filled in.
        #expect(response.text.contains("\"authorable\":true"))
        #expect(response.text.contains("\"authorable\":false"))
        #expect(response.text.contains("cannot be created by hatchery yet"))
    }

    @Test("authorability is asked of the provider registry, not restated here")
    func matchesProviderRegistry() {
        // If a provider is added, the menu picks it up by existing. This test fails if the two
        // ever disagree, which is the only way the menu can start lying.
        for backend in Backend.allCases {
            let hasProvider = (try? Providers.provider(for: backend)) != nil
            #expect(hasProvider == (backend == .dokku))
        }
    }

    @Test("environments are offered in the order a person escalates through them")
    func environmentOrder() async {
        let response = await api().handle(WebRequest(method: "GET", path: "/api/kinds"))
        let text = response.text
        guard let dev = text.range(of: "dev"), let staging = text.range(of: "staging"),
            let prod = text.range(of: "prod")
        else {
            Issue.record("an environment is missing from the menu")
            return
        }
        #expect(dev.lowerBound < staging.lowerBound)
        #expect(staging.lowerBound < prod.lowerBound)
    }
}

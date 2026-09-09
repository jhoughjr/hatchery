import Foundation
import HatcheryKit
import NIOCore
import NIOHTTP1
import NIOPosix

/// What vault's browser sign-in redirected back with.
///
/// Exactly one of the two is set. Vault answers a token when the signed-in person is an admin, and an error when
/// they are not.
public struct VaultLoginCallback: Sendable, Equatable {
    public var token: String?
    public var error: String?

    public init(token: String? = nil, error: String? = nil) {
        self.token = token
        self.error = error
    }
}

/// The way a browser sign-in refuses or fails.
///
/// - `refused`: vault redirected back with an error, so no token was issued.
/// - `timedOut`: nothing reached the loopback listener before the wait ran out.
/// - `emptyCallback`: the redirect carried neither a token nor an error.
/// - `badVault`: the vault address is not one a sign-in URL can be built from.
public enum VaultLoginError: Error, CustomStringConvertible, Equatable {
    case refused(String)
    case timedOut(seconds: Int)
    case emptyCallback
    case badVault(String)

    public var description: String {
        switch self {
        case .refused(let message):
            return "vault refused the sign-in: \(message)"

        case .timedOut(let seconds):
            return "no sign-in reached this machine within \(seconds) seconds"

        case .emptyCallback:
            return "vault redirected back with neither a token nor an error"

        case .badVault(let address):
            return "\(address) is not an address a sign-in can be started at"
        }
    }
}

/// A loopback listener that waits for the one redirect vault's CLI sign-in sends back.
///
/// It binds 127.0.0.1 on a free port and answers one request, because the port exists only for the length of one
/// sign-in and nothing off this machine may reach it. It uses the same NIO layer `hatchery serve` binds with, so the
/// package gains no second HTTP stack.
public final class VaultLoginListener: @unchecked Sendable {
    /// The path vault redirects to, which is the only path this listener answers.
    public static let path = "/vault-login"

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let promise: EventLoopPromise<VaultLoginCallback>

    /// The port the kernel gave, which goes into the sign-in URL.
    public var port: Int { self.channel.localAddress?.port ?? 0 }

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, promise: EventLoopPromise<VaultLoginCallback>) {
        self.group = group
        self.channel = channel
        self.promise = promise
    }

    /// Binds a free loopback port and starts listening.
    public static func bind() async throws -> VaultLoginListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let promise = group.next().makePromise(of: VaultLoginCallback.self)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 1)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CallbackHandler(promise: promise))
                }
            }

        do {
            // Port zero asks the kernel for a free one, so two sign-ins at once never collide.
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            return VaultLoginListener(group: group, channel: channel, promise: promise)
        } catch {
            promise.fail(error)
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// The one callback, or a refusal when the wait runs out.
    public func callback(waiting seconds: Int) async throws -> VaultLoginCallback {
        let promise = self.promise
        self.group.next().scheduleTask(in: .seconds(Int64(seconds))) {
            promise.fail(VaultLoginError.timedOut(seconds: seconds))
        }
        return try await promise.futureResult.get()
    }

    /// Closes the socket and shuts the loop down.
    public func close() async {
        try? await self.channel.close()
        self.promise.fail(VaultLoginError.emptyCallback)
        try? await self.group.shutdownGracefully()
    }
}

/// Reads the redirect and answers the browser one line.
///
/// It fulfils the promise on the first request to the callback path and ignores every other path, so a browser
/// asking for a favicon does not end the wait.
private final class CallbackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let promise: EventLoopPromise<VaultLoginCallback>
    private var head: HTTPRequestHead?

    init(promise: EventLoopPromise<VaultLoginCallback>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head):
            self.head = head

        case .body:
            break

        case .end:
            guard let head = self.head else { return }
            self.head = nil
            let request = Handler.request(from: head, body: Data())
            guard request.path == VaultLoginListener.path else {
                Handler.write(Self.page("nothing is served here"), to: context.channel, keepAlive: false)
                return
            }

            let callback = VaultLoginCallback(
                token: Self.value(request.query["token"]), error: Self.value(request.query["error"]))
            let line =
                callback.token == nil
                ? "vault refused this sign-in. Read the terminal, then close this tab."
                : "Signed in. You can close this tab."
            Handler.write(Self.page(line), to: context.channel, keepAlive: false)
            self.promise.succeed(callback)
        }
    }

    /// A query value with the whitespace off, or `nil` when it is absent or empty.
    private static func value(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The one-line page the browser gets. No token reaches it.
    private static func page(_ line: String) -> WebResponse {
        WebResponse(
            status: 200,
            contentType: "text/html; charset=utf-8",
            body: Data("<!doctype html><meta charset=\"utf-8\"><title>hatchery</title><p>\(line)</p>".utf8))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

// MARK: - The sign-in

/// Signs this machine in to vault through the browser, and stores the operator token vault answers.
///
/// No person copies a session cookie again. Vault runs the browser sign-in it already has and redirects the token to a
/// loopback port this process owns for the length of the sign-in, so the value never passes through an argument or the
/// shell history.
public enum VaultLogin {
    /// A finished sign-in: the token that was stored, and who vault says it belongs to.
    public struct Outcome: Sendable, Equatable {
        public var identity: VaultIdentity
        public var path: String

        public init(identity: VaultIdentity, path: String) {
            self.identity = identity
            self.path = path
        }
    }

    /// The address that starts the browser sign-in for this listener.
    public static func signInURL(vault: String, port: Int, name: String) -> URL? {
        guard var components = URLComponents(string: vault), components.host != nil else { return nil }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/auth/cli"
        components.queryItems = [
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "name", value: name),
        ]
        return components.url
    }

    /// Runs one sign-in end to end: bind, show the URL, wait, check, store.
    ///
    /// The token is checked before it is stored, so a file on this machine is always a credential vault answered for.
    /// `show` prints the address and opens it, and `confirm` is the `whoami` call, both passed in so a test drives the
    /// whole flow without a browser and without a socket to vault.
    public static func run(
        vault: String,
        name: String,
        store: VaultTokenStore = VaultTokenStore(),
        waiting seconds: Int = 180,
        show: @Sendable (URL) -> Void,
        confirm: @Sendable (VaultAdminCredential) async throws -> VaultIdentity
    ) async throws -> Outcome {
        let listener = try await VaultLoginListener.bind()
        let callback: VaultLoginCallback
        do {
            guard let url = Self.signInURL(vault: vault, port: listener.port, name: name) else {
                throw VaultLoginError.badVault(vault)
            }
            show(url)
            callback = try await listener.callback(waiting: seconds)
        } catch {
            await listener.close()
            throw error
        }
        await listener.close()

        if let refusal = callback.error { throw VaultLoginError.refused(refusal) }
        guard let token = callback.token else { throw VaultLoginError.emptyCallback }

        let identity = try await confirm(.bearer(token, from: .tokenFile))
        try store.write(token, vault: vault)
        guard let path = store.path(forVault: vault) else {
            throw VaultTokenStoreError.noHost(vault)
        }
        return Outcome(identity: identity, path: path)
    }
}

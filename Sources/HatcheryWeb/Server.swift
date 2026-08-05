import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

public enum ServerError: Error, CustomStringConvertible, Equatable {
    case unsafeBind(host: String)

    public var description: String {
        switch self {
        case .unsafeBind(let host):
            return """
                refusing to listen on \(host) without a token: this serves actions that restart \
                and deploy real services, and anything that can reach the port could run them. \
                Pass --token, or bind 127.0.0.1.
                """
        }
    }
}

/// Whether an address is reachable from outside this machine.
public enum BindAddress {
    public static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host.lowercased() == "localhost"
    }
}

/// Serves ``HatcheryAPI`` over HTTP.
///
/// The NIO layer here does one job: turn a request into a ``WebRequest`` and a ``WebResponse``
/// back into bytes. Everything that decides anything lives in the API, which is why none of the
/// tests need a socket.
public final class WebServer: Sendable {
    private let api: HatcheryAPI
    private let host: String
    private let port: Int

    public init(api: HatcheryAPI, host: String, port: Int, hasToken: Bool) throws {
        // A non-loopback bind without a token is refused rather than warned about. This process
        // holds SSH access to every stack it manages.
        if !BindAddress.isLoopback(host), !hasToken {
            throw ServerError.unsafeBind(host: host)
        }
        self.api = api
        self.host = host
        self.port = port
    }

    public func run() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let api = self.api
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(Handler(api: api))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)

        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            try await channel.closeFuture.get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try? await group.shutdownGracefully()
    }
}

/// Accumulates one request, hands it to the API, and writes what comes back.
///
/// Internal rather than private so the translation between HTTP and ``WebRequest`` is reachable
/// by tests — query splitting and percent decoding are exactly the parts that quietly go wrong.
final class Handler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let api: HatcheryAPI
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(api: HatcheryAPI) {
        self.api = api
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.clear()

        case .body(var chunk):
            body.writeBuffer(&chunk)

        case .end:
            guard let head else { return }
            let request = Self.request(from: head, body: Data(body.readableBytesView))
            self.head = nil
            body.clear()

            let loop = context.eventLoop
            let channel = context.channel
            let keepAlive = head.isKeepAlive
            Task {
                let response = await api.handle(request)
                loop.execute {
                    Self.write(response, to: channel, keepAlive: keepAlive)
                }
            }
        }
    }

    static func request(from head: HTTPRequestHead, body: Data) -> WebRequest {
        let parts = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? "/")

        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let name = kv.first else { continue }
                let value = kv.count > 1 ? String(kv[1]) : ""
                query[String(name).removingPercentEncoding ?? String(name)] =
                    value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
            }
        }

        var headers: [String: String] = [:]
        for header in head.headers {
            headers[header.name.lowercased()] = header.value
        }

        return WebRequest(
            method: head.method.rawValue, path: path, query: query, headers: headers, body: body)
    }

    static func write(_ response: WebResponse, to channel: Channel, keepAlive: Bool) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.contentType)
        headers.add(name: "Content-Length", value: String(response.body.count))
        // The page is served from this process to this browser and never embedded anywhere.
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "X-Frame-Options", value: "DENY")
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers)

        var buffer = channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)

        _ = channel.write(HTTPServerResponsePart.head(head))
        _ = channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

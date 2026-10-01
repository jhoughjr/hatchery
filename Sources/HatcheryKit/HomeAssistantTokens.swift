import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Signs in to Home Assistant's websocket with a token, sends the commands in order, and answers each command's result.
/// A command that Home Assistant answers with `success: false` throws, and the later commands are not sent.
public typealias HomeAssistantCall = @Sendable (_ url: String, _ token: String, _ commands: [[String: JSONValue]]) async throws -> [JSONValue]

/// Home Assistant's long-lived access tokens, made and deleted over its websocket for the `homeAssistantToken` issuer.
///
/// Home Assistant makes a long-lived token only for a session that is already signed in, so the run signs in with the token the service holds now.
/// Every token travels inside a websocket message from this process, so no value is ever on a command line.
/// The old token is found by its refresh-token id, which the sign-in marks as current, and its name is checked before the delete.
/// A position in the list is never the selector, the same rule the house keeps for Home Assistant's config flows.
public enum HomeAssistantTokens {
    /// How long a new token lives, in days. Ten years is what the profile page offers, and the rotation is what ends a token.
    public static let lifespanDays = 3650

    /// The old token the revoke deletes: its refresh-token id and the name it was made with.
    public struct Retiring: Sendable, Equatable {
        public var id: String
        public var clientName: String

        public init(id: String, clientName: String) {
            self.id = id
            self.clientName = clientName
        }
    }

    /// What a mint answers: the new token, and the old token that the revoke deletes after every holder has the new one.
    public struct Minted: Sendable, Equatable {
        public var token: String
        public var retiring: Retiring
    }

    /// The new token's name: the declared name and the minute it was made.
    /// Home Assistant refuses a second long-lived token of one name, so the time makes each rotation's name new.
    static func clientName(_ name: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(name) \(formatter.string(from: date)) UTC"
    }

    /// Finds the old token, then makes the new one. The old token must be a long-lived token, or nothing is made.
    static func mint(url: String, current: String, name: String, at date: Date, call: HomeAssistantCall) async throws -> Minted {
        let listed = try await call(url, current, [["type": .string("auth/refresh_tokens")]])
        let retiring = try Self.currentToken(in: listed.first ?? .null)

        let made = try await call(
            url, current,
            [
                [
                    "type": .string("auth/long_lived_access_token"),
                    "client_name": .string(Self.clientName(name, at: date)),
                    "lifespan": .number(Double(Self.lifespanDays)),
                ]
            ])
        guard case .string(let token)? = made.first, !token.isEmpty else { throw HomeAssistantTokenError.noTokenAnswered }
        return Minted(token: token, retiring: retiring)
    }

    /// Signs in with the new token, which is the check that it works.
    static func check(url: String, token: String, call: HomeAssistantCall) async throws {
        _ = try await call(url, token, [["type": .string("auth/current_user")]])
    }

    /// Deletes the old token, signed in with the new one.
    /// The id must still be listed with the name the mint read, and must not be the session's own token, or nothing is deleted.
    static func revoke(url: String, token: String, retiring: Retiring, call: HomeAssistantCall) async throws {
        let listed = try await call(url, token, [["type": .string("auth/refresh_tokens")]])
        guard case .array(let rows)? = listed.first else { throw HomeAssistantTokenError.unreadableList }
        let match = rows.first { row in
            guard case .object(let fields) = row else { return false }
            return fields["id"] == .string(retiring.id)
        }
        guard case .object(let fields)? = match else { throw HomeAssistantTokenError.oldTokenGone(retiring.clientName) }
        guard fields["client_name"] == .string(retiring.clientName), fields["is_current"] != .bool(true) else {
            throw HomeAssistantTokenError.oldTokenChanged(retiring.clientName)
        }
        _ = try await call(url, token, [["type": .string("auth/delete_refresh_token"), "refresh_token_id": .string(retiring.id)]])
    }

    /// The signed-in token in an `auth/refresh_tokens` answer: the one row Home Assistant marks `is_current`.
    static func currentToken(in answer: JSONValue) throws -> Retiring {
        guard case .array(let rows) = answer else { throw HomeAssistantTokenError.unreadableList }
        let current = rows.compactMap { row -> [String: JSONValue]? in
            guard case .object(let fields) = row, fields["is_current"] == .bool(true) else { return nil }
            return fields
        }
        guard current.count == 1, let fields = current.first, case .string(let id)? = fields["id"] else {
            throw HomeAssistantTokenError.noCurrentToken
        }
        guard fields["token_type"] == .string("long_lived_access_token"), case .string(let name)? = fields["client_name"] else {
            throw HomeAssistantTokenError.notLongLived
        }
        return Retiring(id: id, clientName: name)
    }
}

// MARK: - The live websocket

extension HomeAssistantTokens {
    /// Home Assistant's websocket at `<url>/api/websocket`, through Foundation's websocket task.
    /// Each call is one connection: the sign-in, then each command with its own id, then the close.
    public static let live: HomeAssistantCall = { url, token, commands in
        guard let base = URL(string: url), var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw HomeAssistantTokenError.badURL(url)
        }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.path = "/api/websocket"
        guard let socketURL = parts.url else { throw HomeAssistantTokenError.badURL(url) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: socketURL)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        func receive() async throws -> [String: JSONValue] {
            let data: Data
            switch try await task.receive() {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: throw HomeAssistantTokenError.unreadableList
            }
            guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
                throw HomeAssistantTokenError.unreadableList
            }
            return fields
        }

        func send(_ fields: [String: JSONValue]) async throws {
            let data = try JSONSerialization.data(withJSONObject: Self.foundation(.object(fields)))
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        }

        // Phase: the sign-in. Home Assistant opens with auth_required and answers auth_ok or auth_invalid.
        _ = try await receive()
        try await send(["type": .string("auth"), "access_token": .string(token)])
        guard try await receive()["type"] == .string("auth_ok") else { throw HomeAssistantTokenError.signInRefused }

        // Phase: the commands, each answered by a result with its own id. Any other message is an event and is skipped.
        var answers: [JSONValue] = []
        for (index, command) in commands.enumerated() {
            let id = Double(index + 1)
            var message = command
            message["id"] = .number(id)
            try await send(message)
            while true {
                let reply = try await receive()
                guard reply["id"] == .number(id), reply["type"] == .string("result") else { continue }
                guard reply["success"] == .bool(true) else {
                    var reason = "no reason given"
                    if case .object(let error)? = reply["error"], case .string(let text)? = error["message"] { reason = text }
                    var name = "a command"
                    if case .string(let type)? = command["type"] { name = type }
                    throw HomeAssistantTokenError.refused(command: name, reason: reason)
                }
                answers.append(reply["result"] ?? .null)
                break
            }
        }
        return answers
    }

    /// A JSON value as a Foundation object, with a whole number as an integer, because Home Assistant takes a message id only as an integer.
    static func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .string(let text): return text
        case .number(let number): return number.rounded() == number ? Int(number) as Any : number
        case .bool(let flag): return flag
        case .object(let fields): return fields.mapValues(Self.foundation)
        case .array(let items): return items.map(Self.foundation)
        case .null: return NSNull()
        }
    }
}

/// The way the `homeAssistantToken` issuer fails.
///
/// - `badURL`: the declared URL is not one a websocket can open.
/// - `signInRefused`: Home Assistant did not take the token for the sign-in.
/// - `refused`: Home Assistant answered a command with a failure.
/// - `unreadableList`: an answer was not the shape Home Assistant documents.
/// - `noCurrentToken`: no listed token is marked as the session's own, so the old token cannot be named.
/// - `notLongLived`: the signed-in token is not a long-lived token, so nothing is made and nothing is deleted.
/// - `noTokenAnswered`: the make answered no token.
/// - `oldTokenGone`: the old token is no longer listed, so there is nothing to delete.
/// - `oldTokenChanged`: the id is listed with another name, or is the new session's own, so nothing is deleted.
public enum HomeAssistantTokenError: Error, Equatable, CustomStringConvertible {
    case badURL(String)
    case signInRefused
    case refused(command: String, reason: String)
    case unreadableList
    case noCurrentToken
    case notLongLived
    case noTokenAnswered
    case oldTokenGone(String)
    case oldTokenChanged(String)

    public var description: String {
        switch self {
        case .badURL(let url):
            return "'\(url)' is not a Home Assistant URL a websocket can open"

        case .signInRefused:
            return "Home Assistant refused the sign-in with the token"

        case .refused(let command, let reason):
            return "Home Assistant refused \(command): \(reason)"

        case .unreadableList:
            return "Home Assistant answered in a shape hatchery does not read"

        case .noCurrentToken:
            return "Home Assistant marked no listed token as the signed-in one, so the old token cannot be named"

        case .notLongLived:
            return "the token the service holds is not a long-lived token, so nothing was made"

        case .noTokenAnswered:
            return "Home Assistant answered no token for the make"

        case .oldTokenGone(let name):
            return "the old token '\(name)' is no longer listed, so nothing was deleted"

        case .oldTokenChanged(let name):
            return "the old token's id no longer carries the name '\(name)', so nothing was deleted; delete it on the profile page"
        }
    }
}

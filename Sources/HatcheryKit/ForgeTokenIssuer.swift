import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The forge's own CLI on the opi, which mints and retires jimmy's access tokens for the `forgeToken` issuer.
///
/// The forge mints a token for a password or for its own CLI, never for another access token, and the credential a Mac holds is a token.
/// So the mint runs the CLI inside the forge's container over ssh, the same calls the house skill's `forge-token` makes since 2026-09-29.
/// The new token arrives on the CLI's standard output and goes into the run's memory, never onto a command line or a screen.
public enum ForgeTokenIssuer {
    /// The ssh target that runs the forge's container, the default of `forge-token`.
    public static let box = "jimmy@opi.jimmyhoughjr.net"
    /// The forge's dokku container on the box.
    public static let container = "forgejo.web.1"
    /// The forge account every estate token belongs to.
    public static let user = "jimmy"

    /// Whether a name or a scope list is safe in the remote command line: letters, digits, `:`, `,`, `-` and `_`.
    /// ssh joins its arguments into one line that the box's shell reads, so a space or a quote would change the command.
    public static func isPlainWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ":,-_".unicodeScalars.contains($0) }
    }

    /// One `forgejo admin user` call inside the container, on the box or on this machine when the box is this one.
    static func cli(_ words: [String], on box: String = ForgeTokenIssuer.box) -> ShellCommand {
        let forge = [
            "docker", "exec", "-u", "git", Self.container,
            "forgejo", "--config", "/data/gitea/conf/app.ini", "admin", "user",
        ]
        let hop = AdminChannel.isLocal(box) ? [] : ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", box]
        return ShellCommand(hop + forge + words)
    }

    /// Retires jimmy's token of this name. The forge answers an error when no token has the name, and the run reads that as nothing to retire.
    static func retireCommand(name: String, on box: String = ForgeTokenIssuer.box) -> ShellCommand {
        Self.cli(["delete-access-token", "--username", Self.user, "--token-name", name], on: box)
    }

    /// Mints jimmy's token of this name with these scopes. `--raw` makes the CLI print the token alone on standard output.
    static func mintCommand(name: String, scopes: String, on box: String = ForgeTokenIssuer.box) -> ShellCommand {
        Self.cli(["generate-access-token", "--username", Self.user, "--token-name", name, "--scopes", scopes, "--raw"], on: box)
    }

    /// The token in the CLI's standard output, or `nil` when the last line is not a forge token: forty lower-case hex digits.
    /// A `nil` names no part of the output, because a malformed answer can still hold the value.
    static func token(in output: Data) -> String? {
        let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), last.count == 40,
            last.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        return last
    }

    /// Whether the forge takes a token as a token, the same test `ForgeSecrets.seed` makes.
    /// Only a 401 refuses: a 403 is a real token scoped away from the route, and a token scoped to issues alone is asked at a repository's issues.
    public static func accepts(
        _ token: String,
        forgeBaseURL: String = ForgeSecrets.forgeBaseURL,
        exchange: HTTPExchange = VaultAdmin.live
    ) async throws -> Bool {
        for route in ["/api/v1/user", "/api/v1/repos/\(ForgeSecrets.scopeProbeRepo)/issues?limit=1&state=all"] {
            var request = URLRequest(url: URL(string: forgeBaseURL + route)!)
            request.setValue("token " + token, forHTTPHeaderField: "Authorization")
            // The edge refuses a client that names no agent.
            request.setValue("hatchery-forge-token/1", forHTTPHeaderField: "User-Agent")
            let (_, response) = try await exchange(request)
            if response.statusCode != 401 { return true }
        }
        return false
    }
}

/// The way the `forgeToken` issuer fails.
///
/// - `notMinted`: the CLI did not answer a token. The reason quotes the CLI's standard error and never its standard output,
///   because the output can hold the value.
/// - `refused`: the forge answers 401 to the token it minted and the holders took.
public enum ForgeTokenError: Error, Equatable, CustomStringConvertible {
    case notMinted(name: String, reason: String)
    case refused(name: String)

    public var description: String {
        switch self {
        case .notMinted(let name, let reason):
            return "the forge's CLI did not mint '\(name)': \(reason)"

        case .refused(let name):
            return "the forge refuses the token '\(name)' it minted; every holder has it, so mint again or seed one by hand"
        }
    }
}

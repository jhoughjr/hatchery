import Foundation

/// The credential an admin call carries, and the header it travels in.
///
/// Vault takes two: an operator token as a bearer, and a signed-in admin's browser session as a cookie. The token is the
/// first door and the session is the last, so a machine that ran `hatchery vault login` never asks a person for a
/// cookie again, and a person who already has a session in the environment is still let through.
public struct VaultAdminCredential: Sendable, Equatable {
    /// Where a resolved credential came from.
    ///
    /// - `operatorVariable`: `VAULT_OPERATOR_TOKEN` in the environment.
    /// - `tokenFile`: the token file this machine wrote for the vault host.
    /// - `sessionVariable`: `VAULT_SESSION` in the environment.
    public enum Source: String, Sendable, Equatable {
        case operatorVariable
        case tokenFile
        case sessionVariable
    }

    /// The variable that carries an operator token, which is the first place resolution looks.
    public static let operatorVariable = "VAULT_OPERATOR_TOKEN"

    /// What to tell a person whose machine holds no credential at all.
    public static let recipe = "run: hatchery vault login"

    public var headerName: String
    public var headerValue: String
    public var source: Source

    /// An operator token, which travels as a bearer.
    public static func bearer(_ token: String, from source: Source = .operatorVariable) -> Self {
        VaultAdminCredential(
            headerName: "Authorization", headerValue: "Bearer \(token)", source: source)
    }

    /// A signed-in admin's browser session, which travels as a cookie.
    public static func session(_ session: String) -> Self {
        VaultAdminCredential(
            headerName: "Cookie",
            headerValue: "\(VaultAdmin.sessionCookie)=\(session)",
            source: .sessionVariable)
    }

    /// The credential to send to this vault, or `nil` when the machine holds none.
    ///
    /// The order is the ruling: the operator variable, then the token file for the vault's host, then the session
    /// variable. The variable comes before the file so a one-off run against another identity needs no sign-out first.
    public static func resolve(
        vault: String = VaultAdmin.defaultBaseURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: VaultTokenStore = VaultTokenStore()
    ) -> VaultAdminCredential? {
        if let token = Self.value(of: Self.operatorVariable, in: environment) {
            return .bearer(token)
        }
        if let token = store.read(vault: vault) {
            return .bearer(token, from: .tokenFile)
        }
        if let session = VaultSession.read(from: environment) {
            return .session(session)
        }
        return nil
    }

    /// A variable's value with the whitespace off, or `nil` when it is absent or empty.
    private static func value(of name: String, in environment: [String: String]) -> String? {
        guard let raw = environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

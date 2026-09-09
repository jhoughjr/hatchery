import Foundation

/// Everything registering one service with vault produced: what the run did, and the keys the service's own
/// config must carry from now on.
///
/// The lines this prints hold names and never values. Vault shows an app key once, so the key is in `keys`,
/// which goes straight to the service's secrets file, and it is in no line a terminal keeps in its scrollback.
public struct VaultRegistration: Sendable, Equatable {
    public var app: String
    /// False when vault already held the app, which registration leaves exactly as it is.
    public var registered: Bool
    public var mintedKey: Bool
    /// The names the app's document holds after the run, in the order vault answered them.
    public var secretNames: [String]
    /// `VAULT_URL` and `VAULT_APP` always, and `VAULT_APP_KEY` when a key was minted.
    public var keys: [String: String]

    public init(
        app: String,
        registered: Bool,
        mintedKey: Bool,
        secretNames: [String] = [],
        keys: [String: String] = [:]
    ) {
        self.app = app
        self.registered = registered
        self.mintedKey = mintedKey
        self.secretNames = secretNames
        self.keys = keys
    }

    /// What to print. No line carries a value.
    public func lines() -> [String] {
        var lines = [
            self.registered
                ? "    vault    registered \(self.app)"
                : "    vault    \(self.app) is already registered, left as it is"
        ]
        if self.mintedKey {
            lines.append("    vault    minted an app key into \(VaultRegistrar.appKeyKey)")
        } else {
            lines.append("    vault    the config already holds an app key, so none was minted")
        }
        if self.secretNames.isEmpty {
            lines.append("    vault    no secret-marked key to set")
        } else {
            lines.append("    vault    set \(self.secretNames.joined(separator: " + "))")
        }
        return lines
    }
}

/// Registers a declared service with vault, so no app reaches vault by hand.
///
/// The order is the custody order the rotation executor keeps. Vault answers a minted key once, so the key
/// comes back to the caller before any secret is set, and the caller writes it to the secrets file. A run that
/// stops after the mint leaves a key that is live and written down, which a person can finish from.
public struct VaultRegistrar: Sendable {
    public static let urlKey = "VAULT_URL"
    public static let appNameKey = "VAULT_APP"
    public static let appKeyKey = "VAULT_APP_KEY"

    /// The three keys a registered service carries, which no other key of its contract may collide with.
    public static let keys: Set<String> = [Self.urlKey, Self.appNameKey, Self.appKeyKey]

    private let vault: VaultAdmin
    private let baseURL: String

    public init(vault: VaultAdmin, baseURL: String = VaultAdmin.defaultBaseURL) {
        self.vault = vault
        self.baseURL = baseURL
    }

    /// Registers the app, mints a key when the config holds none, and sets the named secrets on the document.
    ///
    /// `holding` is the app key the service's config already carries. A key that is already deployed is kept,
    /// because minting a second one stops the first at the same moment and the running app would then hold a
    /// key vault no longer accepts.
    public func register(
        app: String,
        name: String? = nil,
        secrets: [String: String] = [:],
        holding appKey: String? = nil
    ) async throws -> VaultRegistration {
        let minted = try await self.vault.registerApp(slug: app, name: name)
        var keys = [Self.urlKey: self.baseURL, Self.appNameKey: app]

        let held = (appKey ?? "").isEmpty ? nil : appKey
        var mintedKey = false
        if held == nil {
            let fresh: String
            if let minted {
                fresh = minted
            } else {
                // Vault already held the app, so registration showed no key and the one route that shows one
                // is the replacement route. The app is not running yet, which is what makes that safe here.
                fresh = try await self.vault.rotateAppKey(app: app)
            }
            keys[Self.appKeyKey] = fresh
            mintedKey = true
        }

        var names: [String] = []
        if !secrets.isEmpty {
            names = try await self.vault.setSecrets(app: app, values: secrets)
        }
        return VaultRegistration(
            app: app, registered: minted != nil, mintedKey: mintedKey, secretNames: names, keys: keys)
    }

    /// The keys of a config that belong in the app's vault document.
    ///
    /// Every secret-marked key the contract names, less the three vault keys themselves and less any empty
    /// value. The app key never goes into the document it opens, and `VAULT_URL` is how the app finds vault
    /// before it has read anything, so neither can live there.
    public static func documentSecrets(
        in config: [String: String], contract: EnvContract
    ) -> [String: String] {
        config.filter { key, value in
            contract.secret.contains(key) && !Self.keys.contains(key) && !value.isEmpty
        }
    }
}

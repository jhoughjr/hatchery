import Foundation

/// The way the token store refuses to read or write a file.
///
/// - `noHost`: the vault address names no host, so no file can be named for it.
/// - `notWritten`: the file system refused the file, and the token was not stored.
public enum VaultTokenStoreError: Error, CustomStringConvertible, Equatable {
    case noHost(String)
    case notWritten(String)

    public var description: String {
        switch self {
        case .noHost(let address):
            return "\(address) names no host, so there is no file to hold its token"

        case .notWritten(let path):
            return "the operator token could not be written to \(path)"
        }
    }
}

/// The operator tokens this machine holds, one file per vault host.
///
/// A file is mode 600 in a directory of mode 700, written through `FileManager` and never through a shell, because a
/// shell puts the value in the process table where every account on the machine reads it. One file per host, so a lab
/// vault signs in beside the estate's and neither takes the other's place.
public struct VaultTokenStore: Sendable {
    /// Where the tokens live: `~/.config/hatchery/vault`.
    public static let defaultDirectory = Paths.join(NSHomeDirectory(), ".config/hatchery/vault")

    public let directory: String

    public init(directory: String = VaultTokenStore.defaultDirectory) {
        self.directory = directory
    }

    /// The host a token file is named for, or `nil` when the address names none.
    public static func host(of vault: String) -> String? {
        guard let host = URL(string: vault)?.host, !host.isEmpty else { return nil }
        return host
    }

    /// The file that holds this vault's token, or `nil` when the address names no host.
    public func path(forVault vault: String) -> String? {
        guard let host = Self.host(of: vault) else { return nil }
        return Paths.join(self.directory, "\(host).token")
    }

    /// The token this machine holds for the vault, or `nil` when it holds none.
    ///
    /// An unreadable file reads as no token, because a file the account cannot open is a machine that has not signed in.
    public func read(vault: String) -> String? {
        guard let path = self.path(forVault: vault),
            let data = FileManager.default.contents(atPath: path)
        else { return nil }
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Stores the token, making the directory at mode 700 and the file at mode 600.
    ///
    /// The modes are set after the create as well as during it, because neither call changes the mode of something that
    /// is already there, and a directory left over from an earlier version would keep whatever mode it had.
    public func write(_ token: String, vault: String) throws {
        guard let path = self.path(forVault: vault) else {
            throw VaultTokenStoreError.noHost(vault)
        }
        let manager = FileManager.default
        try manager.createDirectory(
            atPath: self.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory)

        guard
            manager.createFile(
                atPath: path,
                contents: Data(token.utf8),
                attributes: [.posixPermissions: 0o600])
        else { throw VaultTokenStoreError.notWritten(path) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Removes the token file, and answers whether one was there to remove.
    @discardableResult
    public func delete(vault: String) throws -> Bool {
        guard let path = self.path(forVault: vault) else {
            throw VaultTokenStoreError.noHost(vault)
        }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        try FileManager.default.removeItem(atPath: path)
        return true
    }
}

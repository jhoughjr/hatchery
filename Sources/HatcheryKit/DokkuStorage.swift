import Foundation

/// One storage mount of a dokku app, keyed the way the dokku provider keys it in state.
///
/// The provider unmounts every mount that a declaration leaves out, and restarts the app. A declaration
/// that is silent about storage is therefore not neutral: an apply takes the app's data directory away.
public struct DokkuStorage: Sendable, Equatable, Codable {
    /// The dokku storage name, for a directory under dokku's storage root, such as `rookery-work`.
    /// For a bind to a host path outside that root, the host path itself, such as `/mnt/nvme`.
    public let name: String
    /// The path inside the container.
    public let mountPath: String

    public init(name: String, mountPath: String) {
        self.name = name
        self.mountPath = mountPath
    }

    /// The directory dokku keeps named storage in.
    public static let storageRoot = "/var/lib/dokku/data/storage/"

    /// Reads the output of `storage:report <app> --storage-run-mounts`, which is one `-v host:container`
    /// pair per mount on a single line. An app with no mounts answers an empty line.
    public static func parse(runMounts: String) -> [DokkuStorage] {
        let tokens = runMounts.split(whereSeparator: \.isWhitespace).map(String.init)
        var mounts: [DokkuStorage] = []
        for (index, token) in tokens.enumerated() where token == "-v" && index + 1 < tokens.count {
            let pair = tokens[index + 1]
            guard let colon = pair.firstIndex(of: ":") else { continue }
            let host = String(pair[..<colon])
            let container = String(pair[pair.index(after: colon)...])
            guard !host.isEmpty, !container.isEmpty else { continue }
            let name = host.hasPrefix(storageRoot) ? String(host.dropFirst(storageRoot.count)) : host
            mounts.append(DokkuStorage(name: name, mountPath: container))
        }
        return mounts
    }
}

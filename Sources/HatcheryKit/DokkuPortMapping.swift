import Foundation

/// One entry of a dokku app's port map, `scheme:host:container`, such as `https:443:80`.
public struct DokkuPortMapping: Sendable, Equatable, Codable {
    public let scheme: String
    public let hostPort: String
    public let containerPort: Int

    public init(scheme: String, hostPort: String, containerPort: Int) {
        self.scheme = scheme
        self.hostPort = hostPort
        self.containerPort = containerPort
    }

    /// Reads a port map as `ports:report` prints it, one mapping per space-separated entry.
    public static func parse(portMap: String) -> [DokkuPortMapping] {
        portMap.split(whereSeparator: \.isWhitespace).compactMap { entry in
            let parts = entry.split(separator: ":")
            guard parts.count == 3, let container = Int(parts[2]) else { return nil }
            return DokkuPortMapping(scheme: String(parts[0]), hostPort: String(parts[1]), containerPort: container)
        }
    }
}

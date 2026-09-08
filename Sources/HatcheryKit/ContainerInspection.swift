import Foundation

/// What one `docker inspect` answer says about a container.
///
/// This is the one reader of that document. Adopt turns it into a ``ContainerSpec`` and a sidecar, and
/// `StatusReporter` grades a container from the same bytes, so the two never read the daemon differently.
/// Only the fields hatchery declares or grades are decoded, because the rest of the answer moves between
/// docker versions and nothing here depends on it.
public struct ContainerInspection: Sendable, Equatable {
    public let id: String
    /// The name without docker's leading slash.
    public let name: String
    /// The image reference the container was made from, not the digest the daemon resolved it to.
    public let image: String
    /// `running`, `exited`, `created`, `restarting`, `paused` or `dead`, as the daemon reports it.
    public let state: String
    public let running: Bool
    /// `healthy`, `unhealthy` or `starting`, when the container declares a HEALTHCHECK.
    public let health: String?
    /// Whether the image or the run declares a HEALTHCHECK at all.
    public let hasHealthcheck: Bool
    public let environment: [String: String]
    public let spec: ContainerSpec

    public init(
        id: String, name: String, image: String, state: String, running: Bool,
        health: String? = nil, hasHealthcheck: Bool = false,
        environment: [String: String] = [:], spec: ContainerSpec
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.running = running
        self.health = health
        self.hasHealthcheck = hasHealthcheck
        self.environment = environment
        self.spec = spec
    }
}

/// Why a `docker inspect` answer could not be read.
///
/// - `notAContainer`: the answer is not the array of one object `docker inspect <name>` returns.
/// - `noSuchContainer`: the box answered, and it holds no container of that name.
public enum ContainerInspectionError: Error, CustomStringConvertible, Equatable {
    case notAContainer(String)
    case noSuchContainer(String)

    public var description: String {
        switch self {
        case .notAContainer(let detail):
            return "docker inspect did not answer with a container (\(detail))"
        case .noSuchContainer(let name):
            return "the box holds no container named '\(name)'"
        }
    }
}

extension ContainerInspection {
    /// The first container in a `docker inspect` answer.
    ///
    /// `docker inspect` always answers with an array, even for one name, and an empty array is how the
    /// daemon says the name is not there.
    public static func decode(_ json: Data) throws -> ContainerInspection {
        guard let array = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else {
            throw ContainerInspectionError.notAContainer("the answer is not a JSON array of objects")
        }
        guard let first = array.first else {
            throw ContainerInspectionError.notAContainer("the answer holds no container")
        }
        return try Self.read(first)
    }

    /// Every container in a `docker inspect` answer, in the order the daemon listed them.
    ///
    /// One inspect of many names is how a scan reads a whole box in one round trip.
    public static func decodeAll(_ json: Data) throws -> [ContainerInspection] {
        guard let array = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else {
            throw ContainerInspectionError.notAContainer("the answer is not a JSON array of objects")
        }
        return array.compactMap { try? Self.read($0) }
    }

    static func read(_ object: [String: Any]) throws -> ContainerInspection {
        let config = object["Config"] as? [String: Any] ?? [:]
        let hostConfig = object["HostConfig"] as? [String: Any] ?? [:]
        let state = object["State"] as? [String: Any] ?? [:]
        guard let image = config["Image"] as? String else {
            throw ContainerInspectionError.notAContainer("no Config.Image")
        }

        let health = (state["Health"] as? [String: Any])?["Status"] as? String
        let restart = (hostConfig["RestartPolicy"] as? [String: Any])?["Name"] as? String

        let spec = ContainerSpec(
            image: image,
            network: Self.network(hostConfig["NetworkMode"] as? String),
            mounts: Self.mounts(object["Mounts"] as? [[String: Any]] ?? []),
            ports: Self.ports(hostConfig["PortBindings"] as? [String: Any] ?? [:]),
            restart: (restart?.isEmpty == false ? restart : nil) ?? "no",
            command: config["Cmd"] as? [String],
            privileged: hostConfig["Privileged"] as? Bool ?? false,
            extraHosts: hostConfig["ExtraHosts"] as? [String] ?? [])

        return ContainerInspection(
            id: object["Id"] as? String ?? "",
            // docker names a container `/lan-dns`; every other surface calls it `lan-dns`.
            name: String((object["Name"] as? String ?? "").drop(while: { $0 == "/" })),
            image: image,
            state: state["Status"] as? String ?? "unknown",
            running: state["Running"] as? Bool ?? false,
            health: health,
            hasHealthcheck: config["Healthcheck"] != nil && !(config["Healthcheck"] is NSNull),
            environment: Self.environment(config["Env"] as? [String] ?? []),
            spec: spec)
    }

    /// `default` is docker's word for the daemon's own bridge, and naming it in a declaration would claim a
    /// network that does not exist under that name.
    static func network(_ mode: String?) -> String? {
        guard let mode, !mode.isEmpty, mode != "default" else { return nil }
        return mode
    }

    /// A volume mount carries a name and a bind mount carries a path, and the declaration takes them through
    /// different attributes, so the type decides which field is the source.
    static func mounts(_ entries: [[String: Any]]) -> [ContainerSpec.Mount] {
        entries.compactMap { entry in
            guard let target = entry["Destination"] as? String else { return nil }
            let isVolume = (entry["Type"] as? String) == "volume"
            let source = isVolume
                ? entry["Name"] as? String
                : entry["Source"] as? String
            guard let source, !source.isEmpty else { return nil }
            return ContainerSpec.Mount(
                source: source, target: target, readOnly: !(entry["RW"] as? Bool ?? true))
        }
    }

    /// `{"5432/tcp": [{"HostPort": "5433"}]}` becomes one port map per published binding, in port order.
    static func ports(_ bindings: [String: Any]) -> [ContainerSpec.PortMap] {
        var mapped: [ContainerSpec.PortMap] = []
        for (key, value) in bindings {
            let parts = key.split(separator: "/", maxSplits: 1)
            guard let container = Int(parts[0]) else { continue }
            let proto = parts.count == 2 ? String(parts[1]) : "tcp"
            for binding in value as? [[String: Any]] ?? [] {
                guard let host = Int(binding["HostPort"] as? String ?? "") else { continue }
                mapped.append(
                    ContainerSpec.PortMap(host: host, container: container, protocol: proto))
            }
        }
        return mapped.sorted { ($0.container, $0.host) < ($1.container, $1.host) }
    }

    /// `KEY=value` becomes one entry. A value may hold `=`, so only the first one splits.
    static func environment(_ entries: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard let key = parts.first, !key.isEmpty else { continue }
            result[String(key)] = parts.count == 2 ? String(parts[1]) : ""
        }
        return result
    }
}

/// The names on a box that answer to somebody else's declaration.
public enum ContainerNames {
    /// Whether dokku made this container.
    ///
    /// dokku names every container `<app>.<process>.<number>`, so a name in that shape belongs to the dokku
    /// provider and this backend must not declare it a second time.
    public static func isDokku(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, let last = parts.last, Int(last) != nil else { return false }
        return parts[parts.count - 2].allSatisfy { $0.isLowercase && $0.isLetter }
    }

    /// Whether buildx made this container. A builder is scratch space for a build and is undeclared by ruling.
    public static func isBuildkitBuilder(_ name: String) -> Bool {
        name.hasPrefix("buildx_buildkit_")
    }

    /// Whether hatchery should offer this container as one to declare.
    public static func isDeclarable(_ name: String) -> Bool {
        !isDokku(name) && !isBuildkitBuilder(name)
    }
}

import Foundation

/// Whether applying would change the code an App Platform service is running.
///
/// Better placed than dokku's question: the platform reports the digest each deployment
/// was built from, and the registry reports the digest its tag points at now, so the two
/// compare directly with no wrappers and no root. DOCR answers through the DigitalOcean
/// API with the same token. Docker Hub answers through its public tag API. A registry
/// this does not know, or a deployment that reports no digest, is said to be not
/// checkable rather than silently fine.
public struct AppPlatformDrift: Sendable {
    private let run: CommandRunner
    private let environment: [String: String]

    public init(
        run: @escaping CommandRunner = ShellRunner.live,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.run = run
        self.environment = environment
    }

    /// One sentence per service whose next apply would, or might, change its code.
    public func check(stack: StackSpec) async -> [String] {
        guard stack.backend == .appPlatform else { return [] }
        guard let token = environment["DIGITALOCEAN_TOKEN"], !token.isEmpty else {
            return stack.services.map {
                "\($0.name): drift not checkable — DIGITALOCEAN_TOKEN is not set"
            }
        }
        let deployed = await deployedDigests(token: token)
        var lines: [String] = []
        for service in stack.services {
            guard let running = deployed[service.name] else {
                lines.append(
                    "\(service.name): drift not checkable — the platform reports no deployed "
                        + "digest for an app by that name")
                continue
            }
            let reference = ImageReference(service.image)
            guard let registry = await registryDigest(of: reference, token: token) else {
                lines.append(
                    "\(service.name): registry drift not checkable — \(reference.registryName) "
                        + "did not answer for \(reference.tagLabel)")
                continue
            }
            if Self.hash(running) != Self.hash(registry) {
                lines.append(
                    "\(service.name): the registry's \(reference.tagLabel) has moved past what "
                        + "the platform deployed — applying pulls and runs new code")
            }
        }
        return lines
    }

    // MARK: the platform

    /// By app name: the digest its active deployment was built from.
    func deployedDigests(token: String) async -> [String: String] {
        guard let body = await json(
            ["curl", "-sfS", "--max-time", "20", "-H", "Authorization: Bearer \(token)",
             "https://api.digitalocean.com/v2/apps?per_page=200"]),
            let root = body as? [String: Any], let apps = root["apps"] as? [[String: Any]]
        else { return [:] }
        var out: [String: String] = [:]
        for app in apps {
            guard let spec = app["spec"] as? [String: Any], let name = spec["name"] as? String,
                let deployment = app["active_deployment"] as? [String: Any],
                let services = deployment["services"] as? [[String: Any]]
            else { continue }
            // One service per app is what hatchery authors. The first with a digest wins.
            for entry in services {
                if let digest = entry["source_image_digest"] as? String, !digest.isEmpty {
                    out[name] = digest
                    break
                }
            }
        }
        return out
    }

    // MARK: the registry

    func registryDigest(of reference: ImageReference, token: String) async -> String? {
        switch reference.registry {
        case .docr(let registry, let repository):
            let path = "registry/\(registry)/repositories/\(Self.escaped(repository))/tags/\(reference.tag)"
            guard let body = await json(
                ["curl", "-sfS", "--max-time", "20", "-H", "Authorization: Bearer \(token)",
                 "https://api.digitalocean.com/v2/\(path)"]),
                let root = body as? [String: Any], let tag = root["tag"] as? [String: Any]
            else { return nil }
            return tag["manifest_digest"] as? String
        case .dockerHub(let repository):
            guard let body = await json(
                ["curl", "-sfS", "--max-time", "20",
                 "https://hub.docker.com/v2/repositories/\(repository)/tags/\(reference.tag)"]),
                let root = body as? [String: Any]
            else { return nil }
            if let digest = root["digest"] as? String, !digest.isEmpty { return digest }
            // Older answers carry the digest per architecture image only.
            let images = root["images"] as? [[String: Any]] ?? []
            return images.compactMap { $0["digest"] as? String }.first
        case .unknown:
            return nil
        }
    }

    private func json(_ argv: [String]) async -> Any? {
        guard let data = try? await run(argv) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func hash(_ digest: String) -> String {
        digest.split(separator: "@").last.map(String.init) ?? digest
    }

    static func escaped(_ repository: String) -> String {
        repository.replacingOccurrences(of: "/", with: "%2F")
    }
}

/// The parts of an image reference drift needs: which registry, which repository, which tag.
public struct ImageReference: Equatable, Sendable {
    public enum Registry: Equatable, Sendable {
        case docr(registry: String, repository: String)
        case dockerHub(repository: String)
        case unknown(host: String)
    }

    public let registry: Registry
    public let tag: String

    public init(_ image: String) {
        let (name, tag) = Self.split(image)
        self.tag = tag
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "registry.digitalocean.com", parts.count >= 3 {
            self.registry = .docr(
                registry: parts[1], repository: parts.dropFirst(2).joined(separator: "/"))
        } else if parts.count == 1 {
            self.registry = .dockerHub(repository: "library/\(parts[0])")
        } else if parts.count == 2, !parts[0].contains(".") {
            self.registry = .dockerHub(repository: name)
        } else if parts.first == "docker.io" {
            let rest = parts.dropFirst().joined(separator: "/")
            self.registry = .dockerHub(repository: rest.contains("/") ? rest : "library/\(rest)")
        } else {
            self.registry = .unknown(host: parts[0])
        }
    }

    public var registryName: String {
        switch registry {
        case .docr: return "DOCR"
        case .dockerHub: return "Docker Hub"
        case .unknown(let host): return host
        }
    }

    public var tagLabel: String { "tag \(tag)" }

    /// `repo:tag` → (repo, tag). A digest reference or a bare name gets `latest`.
    static func split(_ image: String) -> (String, String) {
        guard !image.contains("@") else { return (image, "latest") }
        let lastSlash = image.lastIndex(of: "/") ?? image.startIndex
        if let colon = image[lastSlash...].lastIndex(of: ":") {
            return (String(image[..<colon]), String(image[image.index(after: colon)...]))
        }
        return (image, "latest")
    }
}

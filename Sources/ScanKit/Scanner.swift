import Foundation
import HatcheryKit

/// One thing that runs on a target, read from the target rather than from a manifest.
///
/// The shape is provider-neutral on purpose. A dokku app and an App Platform app answer
/// the same four questions, and the verbs that follow a scan, adopting a find into the
/// manifest and cloning it to another provider, want one shape to work from.
public struct FoundApp: Sendable, Equatable {
    public let name: String
    /// The image the provider reports, when it reports one.
    public let image: String?
    public let running: Bool
    /// Database services the provider says are attached.
    public let databases: [String]
    /// The docker network the app joins, for self-hosted providers. `nil` elsewhere.
    public let network: String?

    public init(
        name: String, image: String? = nil, running: Bool, databases: [String] = [],
        network: String? = nil
    ) {
        self.name = name
        self.image = image
        self.running = running
        self.databases = databases
        self.network = network
    }
}

/// Whose an app is, as far as the manifest can tell.
public enum Claim: Sendable, Equatable {
    /// A manifest stack on this target declares a service with this name.
    case declared(stack: String)
    /// No stack declares it, but it has hatchery's shape: it joins the shared network a
    /// hatchery box init creates, or the network a declared app on this target joins.
    /// A candidate to adopt.
    case hatcheryShaped
    /// Nothing ties it to hatchery.
    case foreign
}

/// What a scan found on one target.
public struct Inventory: Sendable, Equatable {
    public let provider: Backend
    /// The address the scan used: the box for dokku, the API for a platform.
    public let target: String
    public let apps: [FoundApp]
    /// Database services that exist on the target, attached or not. `nil` when the
    /// target cannot answer: a dokku box without the postgres plugin keeps its databases
    /// as plain containers, which the dokku user cannot list.
    public let databases: [String]?

    public init(provider: Backend, target: String, apps: [FoundApp], databases: [String]?) {
        self.provider = provider
        self.target = target
        self.apps = apps
        self.databases = databases
    }
}

public enum ScanError: Error, Equatable {
    /// Nothing answered as a provider hatchery knows.
    case noProviderAnswered(target: String, tried: [String])
    case providerRefused(String)
}

/// Reads a target and says what runs there.
///
/// `identify` probes the provider first, because the person pointing hatchery at a
/// machine should not have to know which backend lives on it. A box that answers
/// `apps:list` as the dokku user is dokku. `appPlatform` as a target, or no target at all
/// with `DIGITALOCEAN_TOKEN` set, is App Platform.
public struct Scanner: Sendable {
    public static let sharedNetwork = "hatchery-net"

    private let execute: CommandExecutor
    private let environment: [String: String]

    public init(
        execute: @escaping CommandExecutor = ShellRunner.liveExecutor,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.execute = execute
        self.environment = environment
    }

    /// Which provider a target is, by asking it.
    public func identify(_ target: String?) async throws -> (Backend, String) {
        if target == nil || target == Backend.appPlatform.rawValue {
            guard let token = self.environment["DIGITALOCEAN_TOKEN"], !token.isEmpty else {
                throw ScanError.noProviderAnswered(
                    target: target ?? "", tried: ["App Platform: DIGITALOCEAN_TOKEN is not set"])
            }
            return (.appPlatform, "api.digitalocean.com")
        }
        let box = DokkuProvider.sshTarget(target!)
        let probe = await self.dokku("apps:list", on: box)
        if probe.status == 0 {
            return (.dokku, box)
        }
        throw ScanError.noProviderAnswered(
            target: target!,
            tried: ["dokku: \(box) did not answer apps:list (\(probe.combined))"])
    }

    /// Everything that runs on the target.
    public func scan(_ target: String?) async throws -> Inventory {
        let (provider, address) = try await self.identify(target)
        switch provider {
        case .dokku: return try await self.scanDokku(box: address)
        case .appPlatform: return try await self.scanAppPlatform()
        case .aws, .cloudRun:
            throw ScanError.providerRefused("scan has no reader for \(provider.rawValue) yet")
        }
    }

    /// Sorts each find against the manifest: declared by a stack on this target,
    /// hatchery-shaped, or foreign.
    public static func classify(
        _ inventory: Inventory, against manifest: StackManifest?
    ) -> [(app: FoundApp, claim: Claim)] {
        let stacks = (manifest?.stacks ?? []).filter { $0.backend == inventory.provider }
        func declaring(_ app: FoundApp) -> StackSpec? {
            stacks.first { stack in
                guard stack.services.contains(where: { $0.name == app.name }) else { return false }
                // On dokku the box must match too. A platform has one address.
                if inventory.provider == .dokku, let host = stack.hostAddress {
                    return inventory.target.hasSuffix(host)
                }
                return true
            }
        }
        // The networks hatchery's own apps live on, on this target.
        var ours: Set<String> = [Self.sharedNetwork]
        for app in inventory.apps where declaring(app) != nil {
            if let network = app.network { ours.insert(network) }
        }
        return inventory.apps.map { app in
            if let stack = declaring(app) {
                return (app, .declared(stack: stack.name))
            }
            if let network = app.network, ours.contains(network) {
                return (app, .hatcheryShaped)
            }
            return (app, .foreign)
        }
    }

    // MARK: dokku

    private func scanDokku(box: String) async throws -> Inventory {
        let list = await self.dokku("apps:list", on: box)
        guard list.status == 0 else { throw ScanError.providerRefused(list.combined) }
        let names = Self.bareLines(list.standardOutput)

        var apps: [FoundApp] = []
        for name in names {
            let running = await self.dokku("ps:report \(name) --running", on: box)
            let network = await self.dokku(
                "network:report \(name) --network-attach-post-create", on: box)
            let links = await self.dokku("postgres:app-links \(name)", on: box)
            let joined = network.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            apps.append(
                FoundApp(
                    name: name,
                    running: running.standardOutput.trimmingCharacters(
                        in: .whitespacesAndNewlines) == "true",
                    databases: links.status == 0 ? Self.bareLines(links.standardOutput) : [],
                    network: joined.isEmpty ? nil : joined))
        }

        let databases = await self.dokku("postgres:list", on: box)
        let services: [String]? = databases.status == 0
            ? Self.bareLines(databases.standardOutput).compactMap {
                $0.split(separator: " ").first.map(String.init)
            }
            : nil
        return Inventory(provider: .dokku, target: box, apps: apps, databases: services)
    }

    private func dokku(_ command: String, on box: String) async -> CommandOutput {
        let argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", box]
            + command.split(separator: " ").map(String.init)
        do {
            return try await self.execute(argv, nil)
        } catch {
            return CommandOutput(status: 255, standardOutput: "", standardError: "\(error)")
        }
    }

    /// dokku's lists carry a `=====>` banner and some a column header. Drop both.
    static func bareLines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("=====>") && !$0.hasPrefix("NAME") }
    }

    // MARK: App Platform

    private struct AppsResponse: Decodable {
        struct App: Decodable {
            struct Spec: Decodable {
                struct Service: Decodable {
                    struct Image: Decodable {
                        let registry: String?
                        let repository: String
                        let tag: String?
                    }
                    let name: String
                    let image: Image?
                }
                struct Database: Decodable { let name: String }
                let name: String
                let services: [Service]?
                let databases: [Database]?
            }
            struct Deployment: Decodable { let phase: String }
            let spec: Spec
            let activeDeployment: Deployment?
            enum CodingKeys: String, CodingKey {
                case spec
                case activeDeployment = "active_deployment"
            }
        }
        let apps: [App]?
    }

    private func scanAppPlatform() async throws -> Inventory {
        let output: CommandOutput
        do {
            output = try await self.execute(
                [
                    "curl", "-fsS", "--max-time", "15",
                    "-H", "Authorization: Bearer \(self.environment["DIGITALOCEAN_TOKEN"] ?? "")",
                    "https://api.digitalocean.com/v2/apps?per_page=200",
                ], nil)
        } catch {
            throw ScanError.providerRefused("\(error)")
        }
        guard output.status == 0 else { throw ScanError.providerRefused(output.combined) }
        return try Self.appPlatformInventory(from: Data(output.standardOutput.utf8))
    }

    /// The inventory an App Platform `/v2/apps` body describes. Split out so a test can
    /// hand it a body without a token.
    static func appPlatformInventory(from body: Data) throws -> Inventory {
        let response = try JSONDecoder().decode(AppsResponse.self, from: body)
        var databases: Set<String> = []
        let apps = (response.apps ?? []).map { app -> FoundApp in
            let first = app.spec.services?.first?.image
            let image = first.map { image -> String in
                var ref = image.repository
                if let registry = image.registry, !registry.isEmpty { ref = "\(registry)/\(ref)" }
                if let tag = image.tag, !tag.isEmpty { ref += ":\(tag)" }
                return ref
            }
            let attached = (app.spec.databases ?? []).map(\.name)
            attached.forEach { databases.insert($0) }
            return FoundApp(
                name: app.spec.name, image: image,
                running: app.activeDeployment?.phase == "ACTIVE",
                databases: attached)
        }
        return Inventory(
            provider: .appPlatform, target: "api.digitalocean.com", apps: apps,
            databases: databases.sorted())
    }
}

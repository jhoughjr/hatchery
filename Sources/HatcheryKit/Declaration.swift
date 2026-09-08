import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The declaration as a reading: every stack the manifests hold, flattened to what a reader off this machine needs.
/// Config values never join it, because the document is published.
public struct Declaration: Codable, Sendable, Equatable {
    public struct Service: Codable, Sendable, Equatable {
        public var name: String
        public var kind: String
        public var image: String
        public var domains: [String]
        public var healthPath: String?
    }

    public struct Stack: Codable, Sendable, Equatable {
        public var name: String
        public var backend: String
        public var environment: String
        public var host: String?
        public var manifest: String
        public var services: [Service]
    }

    /// Milliseconds since the epoch, on the machine that read the manifests.
    public var at: Int
    public var manifests: [String]
    public var stacks: [Stack]

    public init(manifests: [(manifest: StackManifest, path: String)], now: Date = Date()) {
        self.at = Int(now.timeIntervalSince1970 * 1000)
        self.manifests = manifests.map(\.path)
        self.stacks = manifests.flatMap { loaded in
            loaded.manifest.stacks.map { stack in
                Stack(
                    name: stack.name,
                    backend: stack.backend.rawValue,
                    environment: stack.resolvedEnvironment.rawValue,
                    host: stack.host,
                    manifest: loaded.path,
                    services: stack.services.map { service in
                        Service(
                            name: service.name,
                            kind: service.kind.rawValue,
                            image: service.image,
                            domains: service.domains,
                            healthPath: service.healthPath
                        )
                    }
                )
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - Publishing

extension Declaration {
    /// The pulse node key, read from the file roost keeps it in.
    /// The key never joins a command line, so this is the only way it travels.
    public static func nodeKey(at path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { throw DeclarationError.noKey(expanded) }
        let key = try String(contentsOfFile: expanded, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DeclarationError.emptyKey(expanded) }
        return key
    }

    /// POST the document to pulse. The answer is nil on success and a short reason otherwise.
    public static func publish(_ document: Data, to pulse: String, key: String) async -> String? {
        guard let url = URL(string: pulse + "/api/declared") else { return "bad pulse url" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-roost-node-key")
        request.httpBody = document
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "no HTTP response" }
            guard (200..<300).contains(http.statusCode) else { return "http \(http.statusCode)" }
            return nil
        } catch {
            return URLSessionTransport.reason(for: error)
        }
    }
}

extension Declaration {
    /// The publish for a synchronous command: encode, read the key, post, and answer nil on success or a short reason.
    /// A missing key is a reason and not a throw, because a write must finish whatever the publish does.
    public static func publishSync(_ document: Declaration, to pulse: String, keyFile: String = "~/.roost_node_key") -> String? {
        let data: Data
        let key: String
        do {
            data = try document.encoded()
            key = try Self.nodeKey(at: keyFile)
        } catch {
            return "\(error)"
        }
        let done = DispatchSemaphore(value: 0)
        let box = ReasonBox()
        Task {
            box.reason = await Self.publish(data, to: pulse, key: key)
            done.signal()
        }
        done.wait()
        return box.reason
    }
}

/// Carries the answer across the semaphore.
private final class ReasonBox: @unchecked Sendable {
    var reason: String?
}

public enum DeclarationError: Error, CustomStringConvertible {
    /// - `emptyKey`: the key file exists and holds nothing.
    /// - `noKey`: there is no key file at the path.
    case emptyKey(String)
    case noKey(String)

    public var description: String {
        switch self {
        case .emptyKey(let path):
            return "the key file at \(path) is empty"
        case .noKey(let path):
            return "no pulse node key at \(path)"
        }
    }
}

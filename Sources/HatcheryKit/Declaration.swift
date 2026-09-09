import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The declaration as a reading: every stack the manifests hold, flattened to what a reader off this machine needs.
/// Config values never join it, because the document is published.
public struct Declaration: Codable, Sendable, Equatable {
    /// Something true about a service that its declaration alone does not say.
    ///
    /// The declaration says what should be; a finding says what is wrong with the saying of it. The coop
    /// draws these in its why column beside the gap, so the text is one sentence a reader can act on.
    ///
    /// - `code`: the machine's word for the kind of finding, from ``FindingCode``.
    /// - `text`: the same thing for a person.
    public struct Finding: Codable, Sendable, Equatable {
        public var code: String
        public var text: String

        public init(code: String, text: String) {
            self.code = code
            self.text = text
        }
    }

    public struct Service: Codable, Sendable, Equatable {
        public var name: String
        public var kind: String
        public var image: String
        public var domains: [String]
        public var healthPath: String?
        /// What the box does with this container when it stops, for a service on the `host` backend.
        /// Absent for every other backend, where the platform owns the answer.
        public var restart: String?
        /// What this service holds inside it, for a service that is a postgres cluster.
        /// Absent for every other service, so a document of dokku apps gains no empty field.
        public var databases: [Database]?
        /// When the supervisor starts this job again, in the words a reader can act on.
        /// Absent for a job the supervisor keeps alive, and for every service that is not a job.
        public var schedule: String?
        /// Whether the supervisor restarts this job when it exits. Absent for every service that is not a job.
        public var keepAlive: Bool?
        /// Where this job writes stdout and stderr. Absent for a job that names no path, which is the `no-log` finding.
        public var log: String?
        /// The operating system of the box this job runs on, which says which supervisor holds it.
        /// Absent for every service that is not a job.
        public var platform: String?
        /// Empty when the service is clean. Filled by ``DeclarationAudit``, never by a manifest write.
        public var findings: [Finding] = []
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

    /// `findings` is keyed `<stack>/<service>`, and a service with no entry reads as clean.
    ///
    /// It is a parameter rather than something this type works out, because a manifest write publishes a
    /// declaration and a write must never reach the box to do it. ``DeclarationAudit`` is what fills it, and
    /// only `hatchery declared` runs that.
    public init(
        manifests: [(manifest: StackManifest, path: String)],
        findings: [String: [Finding]] = [:],
        now: Date = Date()
    ) {
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
                            healthPath: service.healthPath,
                            restart: service.container?.restart,
                            databases: service.databases.map { $0.map(Database.init) },
                            schedule: service.job?.schedule.map(Declaration.words(for:)),
                            keepAlive: service.job?.keepAlive,
                            log: service.job?.log,
                            platform: service.job.map { _ in stack.platform.rawValue },
                            findings: findings["\(stack.name)/\(service.name)"] ?? []
                        )
                    }
                )
            }
        }
    }

    /// A schedule as one short phrase, for the coop's column and for a person reading the document.
    ///
    /// The manifest is what a machine reads. This is the same fact said once, in the form a calendar expression
    /// already has and a bare second count does not.
    public static func words(for schedule: Schedule) -> String {
        switch schedule {
        case .interval(let seconds): return "every \(seconds)s"
        case .calendar: return HostProvider.onCalendar(schedule)
        case .at(let expression): return expression
        }
    }

    /// One line per service, across every stack: the name, the kind, and the backend that runs it.
    ///
    /// This is the list roost's reconcile should expect to find answering on the box. It is generated from
    /// the declaration rather than typed into the reconcile script, so a container declared here starts
    /// being asked about without anyone editing bash.
    public var answers: [String] {
        stacks.flatMap { stack in
            stack.services.map { "\($0.name) \($0.kind) \(stack.backend)" }
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

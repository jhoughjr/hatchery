import Foundation

/// What makes a service a build box: the forge runner it is, and the jobs that runner offers to take.
///
/// The forge sends a job to any runner whose labels match the job's `runs-on`, so the labels are where a build lands.
/// Both runners were registered by hand and later adopted as a plain container and a plain job, so until this the
/// estate declared that they run and not what they take. `hatchery box runner` reads this off the box.
public struct RunnerSpec: Codable, Sendable, Equatable {
    /// The name the runner is registered under on the forge, for example `mini-forge`.
    public var registration: String
    /// The labels the runner declares, as its config writes them, for example `macos:host` or `linux:docker://roost-ci:arm64`.
    public var labels: [String]
    /// How many jobs the runner takes at once.
    public var capacity: Int
    /// The runner's config file on the box, or inside the container for a runner that is one.
    public var config: String

    public init(registration: String, labels: [String], capacity: Int, config: String) {
        self.registration = registration
        self.labels = labels
        self.capacity = capacity
        self.config = config
    }

    /// Where the runner puts a job: `host` when every label runs on the box itself, `container` when every label names an image.
    public var mode: String {
        let schemes = Set(self.labels.map(BuildBox.scheme(of:)))
        return schemes.count == 1 ? schemes.first ?? "none" : "mixed"
    }

    /// The label names alone, which are what a workflow's `runs-on` asks for, for example `macos`.
    public var names: [String] {
        self.labels.map { label in label.split(separator: ":", maxSplits: 1).first.map(String.init) ?? label }
    }
}

/// Reads a forge runner off the box it runs on.
///
/// The runner's config holds the cache server's secret and its `.runner` file holds the runner's token, so the
/// filtering is done on the box: `sed` prints only the `runner:` block and only the registered name, and neither
/// secret leaves the box. `sed` is the tool because the runner's image carries no `grep`.
public enum BuildBox {
    public enum Trouble: Error, CustomStringConvertible, Equatable {
        case notARunner(service: String)
        case noHost(stack: String)
        case unreadable(service: String, what: String)

        public var description: String {
            switch self {
            case .notARunner(let service):
                return "\(service) runs no `forgejo-runner daemon --config`, so it is not a build box"
            case .noHost(let stack):
                return "stack '\(stack)' declares no host, so there is no box to read the runner from"
            case .unreadable(let service, let what):
                return "\(service): \(what)"
            }
        }
    }

    /// The part of a label that says where a job runs: `host`, `container` for a `docker://` image, or the label's own scheme.
    static func scheme(of label: String) -> String {
        guard let colon = label.firstIndex(of: ":") else { return "container" }
        let target = label[label.index(after: colon)...]
        if target == "host" { return "host" }
        if target.hasPrefix("docker://") { return "container" }
        return String(target)
    }

    /// The config path a runner daemon is started with, from the command a container runs or the program a job runs.
    static func configPath(of service: ServiceSpec) -> String? {
        let argv = service.container?.command ?? service.job?.program ?? []
        guard argv.contains(where: { $0.hasSuffix("forgejo-runner") || $0.hasSuffix("act_runner") }),
              argv.contains("daemon"),
              let at = argv.firstIndex(of: "--config"), at + 1 < argv.count
        else { return nil }
        return argv[at + 1]
    }

    /// The capacity, the `.runner` file and the labels from a runner config's `runner:` block.
    ///
    /// Only this block is read, and only these three keys, so a narrow reader does the job.
    /// A comment line is skipped, so a label that a comment explains is still read.
    static func parse(block text: String) -> (capacity: Int?, file: String?, labels: [String]) {
        var capacity: Int?
        var file: String?
        var labels: [String] = []
        var inLabels = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- ") {
                if inLabels { labels.append(self.unquoted(String(trimmed.dropFirst(2)))) }
                continue
            }
            inLabels = false
            if trimmed.hasPrefix("capacity:") {
                capacity = Int(self.unquoted(String(trimmed.dropFirst("capacity:".count))))
            } else if trimmed.hasPrefix("file:") {
                file = self.unquoted(String(trimmed.dropFirst("file:".count)))
            } else if trimmed == "labels:" {
                inLabels = true
            }
        }
        return (capacity, file, labels)
    }

    private static func unquoted(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// The commands that read a runner, run on the box itself or inside the runner's container.
    static func commands(for service: ServiceSpec, config: String, runnerFile: String) -> (block: String, name: String) {
        let block = "sed -n '/^runner:/,/^[a-z]/p' '\(config)'"
        let name = #"sed -n 's/^ *"name": *"\([^"]*\)".*/\1/p' '"# + runnerFile + "'"
        guard service.container != nil else { return (block, name) }
        return ("docker exec '\(service.name)' " + block, "docker exec '\(service.name)' " + name)
    }

    /// Reads the runner a service runs, on the host its stack names.
    public static func read(
        _ service: ServiceSpec, in stack: StackSpec, using run: CommandRunner = ShellRunner.live
    ) async throws -> RunnerSpec {
        guard let config = self.configPath(of: service), !config.contains("'") else {
            throw Trouble.notARunner(service: service.name)
        }
        guard let host = stack.host, !host.isEmpty else { throw Trouble.noHost(stack: stack.name) }
        func remote(_ command: String) async throws -> String {
            let argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command]
            return String(decoding: try await run(argv), as: UTF8.self)
        }

        let folder = (config as NSString).deletingLastPathComponent
        let first = self.commands(for: service, config: config, runnerFile: folder + "/.runner")
        let parsed = self.parse(block: try await remote(first.block))
        guard let capacity = parsed.capacity, !parsed.labels.isEmpty else {
            throw Trouble.unreadable(service: service.name, what: "\(config) has no runner capacity or no labels")
        }

        // The `.runner` file sits where the config's `file:` says, relative to the daemon's working directory.
        let named = parsed.file ?? ".runner"
        let base = service.job?.workingDirectory ?? folder
        let runnerFile = named.hasPrefix("/") ? named : base + "/" + named
        guard !runnerFile.contains("'") else {
            throw Trouble.unreadable(service: service.name, what: "the .runner path has a quote in it")
        }
        let registration = try await remote(self.commands(for: service, config: config, runnerFile: runnerFile).name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !registration.isEmpty, !registration.contains("\n") else {
            throw Trouble.unreadable(service: service.name, what: "\(runnerFile) names no registration")
        }
        return RunnerSpec(registration: registration, labels: parsed.labels, capacity: capacity, config: config)
    }
}

extension StackManifest {
    /// The same manifest with one service's runner replaced by what the box runs.
    ///
    /// The whole block is replaced, because a label the runner no longer declares must leave the declaration with it.
    public func settingRunner(stack stackName: String, service serviceName: String, to runner: RunnerSpec) -> StackManifest {
        var copy = self
        for stackIndex in copy.stacks.indices where copy.stacks[stackIndex].name == stackName {
            for serviceIndex in copy.stacks[stackIndex].services.indices
            where copy.stacks[stackIndex].services[serviceIndex].name == serviceName {
                copy.stacks[stackIndex].services[serviceIndex].runner = runner
            }
        }
        return copy
    }
}

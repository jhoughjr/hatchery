import Foundation

/// How the box runs one container: the shape `docker inspect` reports and `docker_container` declares.
///
/// This exists because a bare container carries its whole contract in its run arguments, where a dokku app
/// carries it in dokku's own state.
/// Nothing here is a secret: the environment stays in the sidecar and the secrets file, as it does for every other service.
public struct ContainerSpec: Codable, Sendable, Equatable {
    /// One path the container reads or writes, from a bind path or a named volume on the box.
    public struct Mount: Codable, Sendable, Equatable {
        /// A host path, or the name of a docker volume.
        public var source: String
        public var target: String
        public var readOnly: Bool

        public init(source: String, target: String, readOnly: Bool = false) {
            self.source = source
            self.target = target
            self.readOnly = readOnly
        }
    }

    /// One published port. `host` is the port on the box, and `container` the port inside it.
    public struct PortMap: Codable, Sendable, Equatable {
        public var host: Int
        public var container: Int
        public var `protocol`: String

        public init(host: Int, container: Int, protocol proto: String = "tcp") {
            self.host = host
            self.container = container
            self.protocol = proto
        }
    }

    public var image: String
    /// `host`, `bridge`, or the name of a docker network. Absent means the daemon's default.
    public var network: String?
    public var mounts: [Mount]
    public var ports: [PortMap]
    /// `unless-stopped`, `always`, `no`, or `on-failure`.
    public var restart: String
    /// The command, when it overrides the image's own. Absent means the image decides.
    public var command: [String]?
    public var privileged: Bool
    /// Extra `host:address` lines the container resolves, as `--add-host` writes them.
    public var extraHosts: [String]
    /// Whether tofu owns the shape of this container.
    ///
    /// Unmanaged means declared and observed: tofu holds the import and ignores drift.
    /// Managed means tofu owns the container's shape, and a plan may replace it.
    public var managed: Bool

    public init(
        image: String,
        network: String? = nil,
        mounts: [Mount] = [],
        ports: [PortMap] = [],
        restart: String = "unless-stopped",
        command: [String]? = nil,
        privileged: Bool = false,
        extraHosts: [String] = [],
        managed: Bool = false
    ) {
        self.image = image
        self.network = network
        self.mounts = mounts
        self.ports = ports
        self.restart = restart
        self.command = command
        self.privileged = privileged
        self.extraHosts = extraHosts
        self.managed = managed
    }

    enum CodingKeys: String, CodingKey {
        case image, network, mounts, ports, restart, command, privileged, extraHosts, managed
    }

    /// Every manifest written before this field reads as unmanaged, which is what those containers are.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.image = try values.decode(String.self, forKey: .image)
        self.network = try values.decodeIfPresent(String.self, forKey: .network)
        self.mounts = try values.decode([Mount].self, forKey: .mounts)
        self.ports = try values.decode([PortMap].self, forKey: .ports)
        self.restart = try values.decode(String.self, forKey: .restart)
        self.command = try values.decodeIfPresent([String].self, forKey: .command)
        self.privileged = try values.decode(Bool.self, forKey: .privileged)
        self.extraHosts = try values.decode([String].self, forKey: .extraHosts)
        self.managed = try values.decodeIfPresent(Bool.self, forKey: .managed) ?? false
    }

    /// The field is written only when it is true, so adopting a container adds no key to a manifest.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.image, forKey: .image)
        try values.encodeIfPresent(self.network, forKey: .network)
        try values.encode(self.mounts, forKey: .mounts)
        try values.encode(self.ports, forKey: .ports)
        try values.encode(self.restart, forKey: .restart)
        try values.encodeIfPresent(self.command, forKey: .command)
        try values.encode(self.privileged, forKey: .privileged)
        try values.encode(self.extraHosts, forKey: .extraHosts)
        if self.managed {
            try values.encode(true, forKey: .managed)
        }
    }
}

/// When a supervisor starts a job again.
///
/// The three cases are the three shapes launchd and systemd both hold, so a schedule read off one host
/// scaffolds onto the other without a translation table.
///
/// - `interval`: every so many seconds, which is `StartInterval` and `OnUnitActiveSec`.
/// - `calendar`: at a wall-clock time, which is `StartCalendarInterval` and an `OnCalendar` this type builds.
/// - `at`: a supervisor's own calendar expression, kept verbatim because only that supervisor can read it.
public enum Schedule: Sendable, Equatable {
    case interval(seconds: Int)
    case calendar(minute: Int?, hour: Int?, day: Int?, weekday: Int?)
    case at(String)
}

extension Schedule: Codable {
    enum CodingKeys: String, CodingKey {
        case interval, calendar, at
    }

    enum CalendarKeys: String, CodingKey {
        case minute, hour, day, weekday
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let seconds = try values.decodeIfPresent(Int.self, forKey: .interval) {
            self = .interval(seconds: seconds)
            return
        }
        if let expression = try values.decodeIfPresent(String.self, forKey: .at) {
            self = .at(expression)
            return
        }
        let calendar = try values.nestedContainer(keyedBy: CalendarKeys.self, forKey: .calendar)
        self = .calendar(
            minute: try calendar.decodeIfPresent(Int.self, forKey: .minute),
            hour: try calendar.decodeIfPresent(Int.self, forKey: .hour),
            day: try calendar.decodeIfPresent(Int.self, forKey: .day),
            weekday: try calendar.decodeIfPresent(Int.self, forKey: .weekday))
    }

    /// One key per case, so a schedule in a manifest reads as `{"interval": 30}` rather than a wrapper.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let seconds):
            try values.encode(seconds, forKey: .interval)

        case .at(let expression):
            try values.encode(expression, forKey: .at)

        case .calendar(let minute, let hour, let day, let weekday):
            var calendar = values.nestedContainer(keyedBy: CalendarKeys.self, forKey: .calendar)
            try calendar.encodeIfPresent(minute, forKey: .minute)
            try calendar.encodeIfPresent(hour, forKey: .hour)
            try calendar.encodeIfPresent(day, forKey: .day)
            try calendar.encodeIfPresent(weekday, forKey: .weekday)
        }
    }
}

/// How a host runs one program that is not a container: the shape a launchd plist and a systemd user unit share.
///
/// A job is the estate's other half. A container carries its contract in its run arguments, and a job carries its
/// contract in a plist or a unit that nobody reads until it stops working.
/// Nothing here is a secret: the environment stays in the sidecar and the secrets file, as it does for every other service.
public struct JobSpec: Codable, Sendable, Equatable {
    /// The command and its arguments, as the supervisor passes them to `exec`.
    public var program: [String]
    public var workingDirectory: String?
    /// When the supervisor starts it again. Absent means the job is kept alive instead.
    public var schedule: Schedule?
    /// Whether the supervisor restarts the program when it exits. True for a job with no schedule.
    public var keepAlive: Bool
    /// The file the supervisor writes stdout and stderr to. Absent means the journal on Linux, and nothing on a Mac.
    public var log: String?
    /// Whether the supervisor starts the program as it loads the job, rather than waiting for the first schedule.
    public var runAtLoad: Bool
    /// Whether the job reads its secret keys from vault at start.
    ///
    /// When true the scaffold writes no secret-marked key into the plist or the unit, and the program collects them
    /// itself with the app key. A plist value is readable by every account on the machine, and `ps` shows an argument
    /// to all of them, so vault is the only place a job's secret belongs.
    public var environmentFromVault: Bool
    /// The supervisor's own name for the job, when it is not the label this kind would give it.
    /// A Mac names an agent `net.jimmyhoughjr.<service>` unless this says otherwise, and Linux names a unit `<service>`.
    public var label: String?

    public init(
        program: [String],
        workingDirectory: String? = nil,
        schedule: Schedule? = nil,
        keepAlive: Bool? = nil,
        log: String? = nil,
        runAtLoad: Bool = false,
        environmentFromVault: Bool = false,
        label: String? = nil
    ) {
        self.program = program
        self.workingDirectory = workingDirectory
        self.schedule = schedule
        self.keepAlive = keepAlive ?? (schedule == nil)
        self.log = log
        self.runAtLoad = runAtLoad
        self.environmentFromVault = environmentFromVault
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case program, workingDirectory, schedule, keepAlive, log, runAtLoad, environmentFromVault, label
    }

    /// A manifest that names no `keepAlive` reads as kept alive when it declares no schedule, which is the same
    /// answer the initializer gives.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schedule = try values.decodeIfPresent(Schedule.self, forKey: .schedule)
        self.program = try values.decode([String].self, forKey: .program)
        self.workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.schedule = schedule
        self.keepAlive = try values.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? (schedule == nil)
        self.log = try values.decodeIfPresent(String.self, forKey: .log)
        self.runAtLoad = try values.decodeIfPresent(Bool.self, forKey: .runAtLoad) ?? false
        self.environmentFromVault = try values.decodeIfPresent(Bool.self, forKey: .environmentFromVault) ?? false
        self.label = try values.decodeIfPresent(String.self, forKey: .label)
    }

    /// The two flags are written only when they are true, so an adopted job adds no key a reader has to skip.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.program, forKey: .program)
        try values.encodeIfPresent(self.workingDirectory, forKey: .workingDirectory)
        try values.encodeIfPresent(self.schedule, forKey: .schedule)
        try values.encode(self.keepAlive, forKey: .keepAlive)
        try values.encodeIfPresent(self.log, forKey: .log)
        if self.runAtLoad {
            try values.encode(true, forKey: .runAtLoad)
        }
        if self.environmentFromVault {
            try values.encode(true, forKey: .environmentFromVault)
        }
        try values.encodeIfPresent(self.label, forKey: .label)
    }
}

/// One database inside a declared postgres cluster.
///
/// A declared database is a `hatchery db provision` that has already run: the role, the database and the
/// grants exist, and this records what they are so the run can be re-issued and the cluster can be graded.
/// No password lives here. Provisioning mints one and prints it once, and the manifest is committed.
public struct DatabaseSpec: Codable, Sendable, Equatable {
    public var name: String
    /// The role `pg_database.datdba` points at, which is not always named after the database.
    public var owner: String
    /// The reduced-privilege role the service connects as, when one exists.
    public var appRole: String?
    /// Anything a reader needs that the cluster itself does not say.
    public var notes: String?

    public init(name: String, owner: String, appRole: String? = nil, notes: String? = nil) {
        self.name = name
        self.owner = owner
        self.appRole = appRole
        self.notes = notes
    }
}

/// A service instance within a stack.
///
/// `configFile` points at a sidecar holding the resolved environment. The sidecar is
/// never committed — the manifest records *where* config lives, not what it contains.
public struct ServiceSpec: Codable, Sendable, Equatable {
    public var name: String
    public var kind: ServiceKind
    public var image: String
    public var domains: [String]
    public var configFile: String
    /// Where this service's secret keys live, split out from `configFile`.
    ///
    /// Absent from most manifests. When absent, `ConfigSync.secretsURL(...)` derives the name
    /// by replacing `.config.json` with `.secrets.json`.
    public var secretsFile: String?
    /// An explicit base URL, which overrides the address derived from `domains`.
    /// Both this and ``healthPath`` are optional, so a manifest written before them still reads.
    public var baseURL: String?
    /// The readiness path, which defaults to the path for this service kind.
    public var healthPath: String?
    /// The code the proxy gives for this service's root on port 80, when a person has ruled which code is correct.
    ///
    /// Absent means any 2xx or 3xx reads as healthy. It is here rather than in each host's `ROOST_EXPECTED_HTTP`, because
    /// that was the only copy, every host kept its own, and the laptop and the mini disagreed about four apps.
    public var expectedStatus: String?
    /// The registry's identifier for this deployment, once one exists.
    ///
    /// hatchery never mints this. The administration tier is the identity mint, and its
    /// identifiers carry a `dep-` prefix. Carrying the value lets a report name the row the
    /// tier already knows about, rather than inventing a second name for the same thing.
    public var deploymentID: String?
    /// The tofu variable whose default carries this service's image, when tofu owns the deploy.
    ///
    /// A service without one cannot be deployed by hatchery. That is the honest answer rather
    /// than a limitation: if nothing declares which variable moves, there is no way to change
    /// the image without going around the declaration that owns it.
    public var imageVariable: String?
    /// How the box runs this service as a container, for a service on the `host` backend.
    ///
    /// Absent for every other backend, and left out of the encoded manifest when absent.
    /// A manifest written before this therefore still reads, and a dokku manifest gains no empty field.
    public var container: ContainerSpec?
    /// What this service holds inside it, for a service that is a postgres cluster.
    ///
    /// A cluster carries its databases as facts of the cluster, whatever the service's kind is.
    /// Box adopt gives a container its own name as its kind, so the image is what says this is a cluster.
    /// Absent for every other service, and left out of the encoded manifest when absent.
    public var databases: [DatabaseSpec]?
    /// How the host runs this service, for a service that is a job rather than a container.
    ///
    /// A service carries this or `container`, never both: a program under a supervisor is not a container, and the
    /// two scaffolds write different artifacts. Absent for every other service, and left out of the encoded manifest.
    public var job: JobSpec?

    public init(
        name: String,
        kind: ServiceKind,
        image: String,
        domains: [String] = [],
        configFile: String,
        secretsFile: String? = nil,
        baseURL: String? = nil,
        healthPath: String? = nil,
        expectedStatus: String? = nil,
        deploymentID: String? = nil,
        imageVariable: String? = nil,
        container: ContainerSpec? = nil,
        databases: [DatabaseSpec]? = nil,
        job: JobSpec? = nil
    ) {
        self.name = name
        self.kind = kind
        self.image = image
        self.domains = domains
        self.configFile = configFile
        self.secretsFile = secretsFile
        self.baseURL = baseURL
        self.healthPath = healthPath
        self.expectedStatus = expectedStatus

        self.deploymentID = deploymentID
        self.imageVariable = imageVariable
        self.container = container
        self.databases = databases
        self.job = job
    }

    /// Whether this service is a postgres cluster, which is the one service a database is declared on.
    ///
    /// The image is the whole test. A cluster's kind is its own name, because box adopt names a container's
    /// kind after the container, so the kind says nothing about what the container runs.
    public var isPostgresCluster: Bool {
        self.container?.image.hasPrefix("postgres") ?? false
    }

    /// The databases this service declares, and an empty list when it declares none.
    public var declaredDatabases: [DatabaseSpec] {
        self.databases ?? []
    }
}

/// Where the OpenTofu configuration that owns a stack lives.
///
/// hatchery writes into this configuration and asks tofu what the write would do. It does not
/// reach past it to the backend, because the image is a declared attribute: setting it directly
/// would put two owners on one field and leave `tofu plan` permanently dirty.
public struct TofuBinding: Codable, Sendable, Equatable {
    /// The directory holding the configuration; `~` is expanded.
    public var directory: String
    /// The file declaring the image variables. Defaults to `variables.tf`.
    public var variablesFile: String?

    public init(directory: String, variablesFile: String? = nil) {
        self.directory = directory
        self.variablesFile = variablesFile
    }

    public var resolvedVariablesFile: String {
        variablesFile ?? "variables.tf"
    }

    public var variablesPath: String {
        Paths.join(Paths.expanded(directory), resolvedVariablesFile)
    }
}

extension StackSpec {
    /// The address of the box, with any SSH user stripped.
    public var hostAddress: String? {
        guard let host, !host.isEmpty else { return nil }
        return host.split(separator: "@").last.map(String.init)
    }

    /// The operating system this stack's box runs, from the setting preflight recorded.
    ///
    /// A stack that never learned reads as `linux`, which is what every box in the estate was before a Mac joined.
    public var platform: HostPlatform {
        HostPlatform(rawValue: self.settings?[BackendSetting.boxPlatform.key] ?? "") ?? .linux
    }
}

extension ServiceSpec {
    /// Where to probe this service, or `nil` when nothing names an address.
    ///
    /// A dokku service is reached at the box rather than through its name, because a lab
    /// vhost usually has no public DNS record and the proxy routes on the `Host` header.
    /// Passing no stack falls back to the published name.
    public func healthRequest(in stack: StackSpec? = nil) -> HealthRequest? {
        let path = healthPath ?? kind.defaultHealthPath

        if let baseURL,
           let base = URL(string: baseURL),
           let url = URL(string: path, relativeTo: base)?.absoluteURL {
            return HealthRequest(url: url)
        }

        guard let vhost = domains.first, !vhost.isEmpty else { return nil }

        if let stack, stack.backend == .dokku, let address = stack.hostAddress,
           let url = URL(string: "http://\(address)\(path)") {
            return HealthRequest(url: url, hostHeader: vhost)
        }

        guard let url = URL(string: "\(Self.scheme(forHost: vhost))://\(vhost)\(path)") else {
            return nil
        }
        return HealthRequest(url: url)
    }

    /// The published address, ignoring any box-level routing.
    public func healthURL() -> URL? {
        healthRequest()?.url
    }

    /// The secrets sidecar name this service would use by convention.
    ///
    /// `nil` when `configFile` does not end in `.config.json`, the one name the sealing rule
    /// keys on. `ConfigSync.secretsURL(...)` uses this when `secretsFile` is not set explicitly.
    var conventionalSecretsFile: String? {
        guard configFile.hasSuffix(".config.json") else { return nil }
        return String(configFile.dropLast(".config.json".count)) + ".secrets.json"
    }

    /// A public name gets TLS. A single-label or lab-suffixed name is a LAN address that no
    /// tunnel fronts, so it stays plain HTTP and a probe does not fail on a certificate.
    static func scheme(forHost host: String) -> String {
        let lanSuffixes = [".opi", ".local", ".internal", ".lan"]
        guard host.contains(".") else { return "http" }
        return lanSuffixes.contains(where: { host.hasSuffix($0) }) ? "http" : "https"
    }
}

/// Which environment a stack belongs to.
///
/// This is deliberately separate from ``Backend``. The backend says where a service runs;
/// the environment says what it is for. The administration tier's registry treats environments
/// as first-class rows with an `is_prod` flag, so the names here match the ones it seeds.
public struct Environment: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let prod = Environment(rawValue: "prod")
    public static let staging = Environment(rawValue: "staging")
    public static let dev = Environment(rawValue: "dev")

    /// Whether an action against this environment deserves a confirmation.
    public var isProduction: Bool {
        self == .prod
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One deployable stack: a set of services on a single backend.
public struct StackSpec: Codable, Sendable, Equatable {
    public var name: String
    public var backend: Backend
    /// Defaults to `dev`, because an unlabelled stack is not production.
    public var environment: Environment?
    /// SSH target for `dokku`; ignored for App Platform.
    public var host: String?
    /// The OpenTofu configuration that owns this stack, when one does.
    public var tofu: TofuBinding?
    /// What the backend needed to know, as it declared it.
    ///
    /// Only declared, non-secret values live here. A token or a key is read from the environment
    /// at apply time, so a manifest can be committed without redacting anything.
    public var settings: [String: String]?
    public var services: [ServiceSpec]

    public init(
        name: String,
        backend: Backend,
        environment: Environment? = nil,
        host: String? = nil,
        tofu: TofuBinding? = nil,
        settings: [String: String]? = nil,
        services: [ServiceSpec] = []
    ) {
        self.name = name
        self.backend = backend
        self.environment = environment
        self.host = host
        self.tofu = tofu
        self.settings = settings
        self.services = services
    }

    public func service(named name: String) -> ServiceSpec? {
        services.first { $0.name == name }
    }

    /// An unlabelled stack reads as `dev`. Guessing `prod` would arm a confirmation prompt that
    /// nobody asked for; guessing `dev` only ever errs toward doing what was asked.
    public var resolvedEnvironment: Environment {
        environment ?? .dev
    }
}

/// The declaration hatchery owns and commits.
///
/// This is intentionally *not* live state. It records what should exist; what is
/// actually running is queried from the backend on demand. Keeping the two apart
/// avoids the failure mode where a lost local state file orphans running apps.
public struct StackManifest: Codable, Sendable, Equatable {
    public var version: Int
    public var stacks: [StackSpec]
    /// SSH targets saved by name, so a box is written once and referred to afterwards.
    public var hosts: [String: String]?
    /// Where this manifest publishes its declaration when it is written, as a pulse base URL.
    /// Absent means the declaration is read by hand with `hatchery declared`.
    public var publish: String?

    public init(version: Int = 1, stacks: [StackSpec] = [], hosts: [String: String]? = nil) {
        self.version = version
        self.stacks = stacks
        self.hosts = hosts
        self.publish = nil
    }

    public init(version: Int = 1, stacks: [StackSpec] = [], hosts: [String: String]? = nil, publish: String?) {
        self.version = version
        self.stacks = stacks
        self.hosts = hosts
        self.publish = publish
    }

    /// The one door that writes a manifest to disk.
    /// When the manifest names a publish target, the declaration goes there as the write finishes, so the declared reading is true by construction.
    /// A publish that fails prints one line and never fails the write, because the manifest on disk is the record and pulse is the copy.
    public func write(to path: String) throws {
        try self.encoded().write(to: URL(fileURLWithPath: path))
        guard let target = self.publish, !target.isEmpty else { return }
        let document = Declaration(manifests: [(manifest: self, path: path)])
        if let reason = Declaration.publishSync(document, to: target) {
            FileHandle.standardError.write(Data("  publish: pulse did not take the declaration (\(reason))\n".utf8))
        } else {
            FileHandle.standardError.write(Data("  published the declaration to \(target)\n".utf8))
        }
    }

    public func stack(named name: String) -> StackSpec? {
        stacks.first { $0.name == name }
    }

    /// The same manifest without the named stack.
    ///
    /// The tofu directory and the config files are deliberately left on disk: they hold the
    /// state file and real secrets, and a command that removes a declaration should not also
    /// delete the only record of what was there.
    public func removing(stack name: String) -> StackManifest {
        var copy = self
        copy.stacks.removeAll { $0.name == name }
        return copy
    }

    /// The same manifest with one service's declared image changed.
    ///
    /// The manifest is the source of truth for what a service should run. A deploy that moved
    /// only the tofu variable would leave the declaration saying something that is no longer
    /// true, and the next `hatchery status` would report drift hatchery itself created.
    public func settingImage(stack stackName: String, service serviceName: String, to image: String) -> StackManifest {
        var copy = self
        for stackIndex in copy.stacks.indices where copy.stacks[stackIndex].name == stackName {
            for serviceIndex in copy.stacks[stackIndex].services.indices
            where copy.stacks[stackIndex].services[serviceIndex].name == serviceName {
                copy.stacks[stackIndex].services[serviceIndex].image = image
            }
        }
        return copy
    }

    /// The same manifest with one service's declared databases replaced.
    ///
    /// Adopt reads the cluster and writes the whole list, because a database that has left the cluster must
    /// leave the declaration with it. A merge would keep declaring a database that is no longer there.
    public func settingDatabases(
        stack stackName: String, service serviceName: String, to databases: [DatabaseSpec]
    ) -> StackManifest {
        var copy = self
        for stackIndex in copy.stacks.indices where copy.stacks[stackIndex].name == stackName {
            for serviceIndex in copy.stacks[stackIndex].services.indices
            where copy.stacks[stackIndex].services[serviceIndex].name == serviceName {
                copy.stacks[stackIndex].services[serviceIndex].databases = databases
            }
        }
        return copy
    }
}

public enum ManifestError: Error, CustomStringConvertible, Equatable {
    case unsupportedVersion(Int)
    case invalidStackName(String)
    case duplicateStack(String)
    case missingHost(stack: String)
    /// A service declares databases and runs something other than postgres.
    case databasesOffCluster(stack: String, service: String)
    /// A service declares both a container and a job, and it can only be one of the two.
    case jobAndContainer(stack: String, service: String)
    /// A service declares a job on a backend that has no supervisor hatchery can reach.
    case jobOffHost(stack: String, service: String, backend: String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "manifest version \(version) is not supported by this build of hatchery"
        case .invalidStackName(let name):
            return "stack name '\(name)' is invalid; expected ^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$"
        case .duplicateStack(let name):
            return "stack '\(name)' is declared more than once"
        case .missingHost(let stack):
            return "stack '\(stack)' targets dokku but declares no host"
        case .databasesOffCluster(let stack, let service):
            return "service '\(service)' in stack '\(stack)' declares databases, and its image is not postgres"
        case .jobAndContainer(let stack, let service):
            return "service '\(service)' in stack '\(stack)' declares both a container and a job; it is one or the other"
        case .jobOffHost(let stack, let service, let backend):
            return "service '\(service)' in stack '\(stack)' declares a job, and \(backend) runs no supervisor "
                + "hatchery reaches; a job lives on a host stack"
        }
    }
}

extension StackManifest {
    public static let currentVersion = 1

    public static func decode(from data: Data) throws -> StackManifest {
        let manifest = try JSONDecoder().decode(StackManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw ManifestError.unsupportedVersion(version)
        }
        var seen = Set<String>()
        for stack in stacks {
            guard StackName.isValid(stack.name) else {
                throw ManifestError.invalidStackName(stack.name)
            }
            guard seen.insert(stack.name).inserted else {
                throw ManifestError.duplicateStack(stack.name)
            }
            if stack.backend == .dokku, (stack.host ?? "").isEmpty {
                throw ManifestError.missingHost(stack: stack.name)
            }
            for service in stack.services where service.databases != nil && !service.isPostgresCluster {
                throw ManifestError.databasesOffCluster(stack: stack.name, service: service.name)
            }
            for service in stack.services where service.job != nil {
                guard service.container == nil else {
                    throw ManifestError.jobAndContainer(stack: stack.name, service: service.name)
                }
                guard stack.backend == .host else {
                    throw ManifestError.jobOffHost(
                        stack: stack.name, service: service.name, backend: stack.backend.rawValue)
                }
            }
        }
    }
}

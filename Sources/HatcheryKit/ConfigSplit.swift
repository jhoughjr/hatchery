import Foundation

/// What one service's split moved.
public struct ConfigSplitOutcome: Sendable, Equatable {
    public let service: String
    /// The keys moved to the secrets file, sorted. Empty means nothing needed to move.
    public let moved: [String]

    public init(service: String, moved: [String]) {
        self.service = service
        self.moved = moved
    }
}

/// Why a split refused to touch a sidecar.
public enum ConfigSplitError: Error, CustomStringConvertible, Equatable {
    /// The sidecar sits in a sealed directory whose archive does not hold its current bytes.
    case sidecarUnsealed(service: String, path: String)
    /// The config file names nothing a secrets file can be derived from.
    case noConventionalSecretsName(service: String)

    public var description: String {
        switch self {
        case .sidecarUnsealed(let service, let path):
            return "\(service): \(path) is unsealed; seal the directory before splitting"
        case .noConventionalSecretsName(let service):
            return "\(service): its config file does not end .config.json, so no secrets name follows from it"
        }
    }
}

/// Moves a service's secret keys out of its sidecar into a file of their own.
public enum ConfigSplitter {
    /// Splits one service's sidecar by `contract`, refusing when the sidecar sits in a sealed
    /// directory the archive does not yet hold: a split must never leave a secret in a file the
    /// archive does not cover.
    ///
    /// `dryRun` computes and returns what would move without writing anything.
    public static func split(
        service: ServiceSpec,
        in stack: StackSpec,
        manifestPath: String,
        contract: EnvContract,
        dryRun: Bool
    ) throws -> ConfigSplitOutcome {
        let url = ConfigSync.configURL(for: service, in: stack, manifestPath: manifestPath)
        guard let secretsURL = ConfigSync.secretsURL(
            for: service, in: stack, manifestPath: manifestPath
        ) else {
            throw ConfigSplitError.noConventionalSecretsName(service: service.name)
        }

        if let root = SealedState.root(containing: url.deletingLastPathComponent().path),
            let status = try? SealAudit().status(root: root) {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            if status.unsealed.contains(relative) {
                throw ConfigSplitError.sidecarUnsealed(service: service.name, path: relative)
            }
        }

        let declared = try ConfigSync.readDeclared(at: url)
        let split = ConfigSync.split(declared, by: contract)
        let moved = split.secrets.keys.sorted()

        guard !moved.isEmpty, !dryRun else {
            return ConfigSplitOutcome(service: service.name, moved: moved)
        }

        // The secrets file may already hold earlier moves; a later split only adds to it.
        var secrets = try ConfigSync.readDeclared(at: secretsURL)
        for (key, value) in split.secrets {
            secrets[key] = value
        }

        try ConfigSync.encoded(split.config).write(to: url)
        try ConfigSync.encoded(secrets).write(to: secretsURL)

        return ConfigSplitOutcome(service: service.name, moved: moved)
    }
}

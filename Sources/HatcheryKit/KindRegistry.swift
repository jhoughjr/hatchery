import Foundation

/// The kind files declared beside a manifest, one per kind, in `<manifest dir>/kinds/`.
///
/// Adopt and `config audit` read a service's own word here before falling back to the
/// built-in table, so a kind hatchery does not know built in still gets a real contract.
public struct KindRegistry: Sendable {
    private let directory: String

    public init(manifestPath: String) {
        self.directory = Paths.join(
            URL(fileURLWithPath: manifestPath).deletingLastPathComponent().path, "kinds")
    }

    private func path(for kind: String) -> String {
        Paths.join(directory, "\(kind).json")
    }

    /// The declared file for a kind, or `nil` when the registry holds none.
    public func kindFile(for kind: ServiceKind) throws -> KindFile? {
        let path = path(for: kind.rawValue)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try KindFile.load(atPath: path)
    }

    /// Every kind file the registry holds, in the order their files sort.
    public func all() throws -> [KindFile] {
        guard FileManager.default.fileExists(atPath: directory) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return try names.map { try KindFile.load(atPath: Paths.join(directory, $0)) }
    }

    /// Reads the file at `path` and copies it into the registry under its own kind.
    ///
    /// A file already at that kind's slot but declaring a different kind is left alone and
    /// reported, because the slot no longer means what its name says. The same kind's own
    /// file is replaced, so re-running this after an edit is safe.
    @discardableResult
    public func add(from path: String) throws -> KindFile {
        let file = try KindFile.load(atPath: path)
        let destination = self.path(for: file.kind)
        if FileManager.default.fileExists(atPath: destination) {
            let existing = try KindFile.load(atPath: destination)
            guard existing.kind == file.kind else {
                throw KindRegistryError.kindMismatch(
                    path: destination, existing: existing.kind, incoming: file.kind)
            }
            try FileManager.default.removeItem(atPath: destination)
        } else {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(atPath: path, toPath: destination)
        return file
    }
}

/// The way adding a kind file to the registry is refused.
///
/// - `kindMismatch`: the slot a kind owns already holds a file declaring a different kind.
public enum KindRegistryError: Error, CustomStringConvertible, Equatable {
    case kindMismatch(path: String, existing: String, incoming: String)

    public var description: String {
        switch self {
        case .kindMismatch(let path, let existing, let incoming):
            return "\(path) already holds kind '\(existing)'; will not overwrite it with '\(incoming)'"
        }
    }
}

extension ServiceKind {
    /// The built-in kinds, plus every kind a registry declares beside the manifest.
    public static func described(in registry: KindRegistry) -> [ServiceKind] {
        let discovered = ((try? registry.all()) ?? []).map { ServiceKind(rawValue: $0.kind) }
        var seen = Set<ServiceKind>()
        return (known + discovered).filter { seen.insert($0).inserted }
    }
}

extension EnvContract {
    /// The contract for a service kind, consulting `registry` before the built-in table.
    ///
    /// A registry entry wins even for a kind hatchery also knows built in: a service's own
    /// word about its own contract outranks hatchery's guess.
    public static func contract(
        for kind: ServiceKind, backend: Backend, registry: KindRegistry
    ) -> EnvContract? {
        if let file = try? registry.kindFile(for: kind) {
            return file.contract(backend: backend)
        }
        return contract(for: kind, backend: backend)
    }
}

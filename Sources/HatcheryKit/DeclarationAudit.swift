import Foundation

/// The machine's word for a kind of finding.
public enum FindingCode {
    /// The sidecar declares a different set of keys than the box runs with.
    public static let staleSidecar = "stale-sidecar"
    /// A key the contract marks secret is still in the sidecar rather than the secrets file.
    public static let secretInSidecar = "secret-in-sidecar"
}

/// Fills the declaration's findings by comparing what each service declares against what it runs with.
///
/// `hatchery config audit` already asks both questions and prints the answers on a terminal, where nothing
/// off the box can read them. This asks the same questions and puts the answers in the published document,
/// so the coop draws them beside the gap instead of a person having to ssh in to find out.
///
/// A service the box will not answer for produces no finding rather than an error: an unreadable service is
/// already visible as a gap, and a second complaint about it says nothing new.
public struct DeclarationAudit: Sendable {
    private let reader: LiveConfigReader

    public init(reader: LiveConfigReader = LiveConfigReader()) {
        self.reader = reader
    }

    /// The findings for every service in every manifest, keyed `<stack>/<service>`.
    public func findings(
        for manifests: [(manifest: StackManifest, path: String)]
    ) async -> [String: [Declaration.Finding]] {
        var result: [String: [Declaration.Finding]] = [:]
        for loaded in manifests {
            let registry = KindRegistry(manifestPath: loaded.path)
            for stack in loaded.manifest.stacks {
                for service in stack.services {
                    let found = await self.findings(
                        for: service, in: stack, manifestPath: loaded.path, registry: registry)
                    guard !found.isEmpty else { continue }
                    result["\(stack.name)/\(service.name)"] = found
                }
            }
        }
        return result
    }

    func findings(
        for service: ServiceSpec, in stack: StackSpec, manifestPath: String, registry: KindRegistry
    ) async -> [Declaration.Finding] {
        // The sidecar's own content, never the merge with the secrets file. A key still here is a key
        // `hatchery config split` has not moved yet.
        let sidecarURL = ConfigSync.configURL(for: service, in: stack, manifestPath: manifestPath)
        guard let sidecar = try? ConfigSync.readDeclared(at: sidecarURL) else { return [] }

        var findings: [Declaration.Finding] = []
        if let contract = EnvContract.contract(
            for: service.kind, backend: stack.backend, registry: registry)
        {
            findings += ConfigValidator.secretInSidecar(sidecar, against: contract).map {
                Declaration.Finding(
                    code: FindingCode.secretInSidecar,
                    text: "\($0.key) is a secret still in the sidecar; hatchery config split moves it out")
            }
        }

        // The declaration is both files, because a key moved to the secrets file is declared, not missing.
        let secretsURL = ConfigSync.secretsURL(for: service, in: stack, manifestPath: manifestPath)
        let declared = (try? ConfigSync.readDeclared(config: sidecarURL, secrets: secretsURL)) ?? sidecar
        if let live = try? await self.reader.config(for: service, in: stack),
            let stale = Self.staleSidecar(live: live, declared: declared)
        {
            findings.append(stale)
        }
        return findings
    }

    /// The finding for a key set that no longer matches the box, or `nil` when the two agree.
    ///
    /// Only key names appear in the text. The values are the whole reason the sidecar is gitignored, and a
    /// published document that named one would defeat that.
    static func staleSidecar(live: [String: String], declared: [String: String]) -> Declaration.Finding? {
        let difference = ConfigSync.diff(live: live, declared: declared)
        guard !difference.added.isEmpty || !difference.removed.isEmpty else { return nil }

        var parts: [String] = []
        if !difference.added.isEmpty {
            parts.append("the box also runs with \(difference.added.joined(separator: ", "))")
        }
        if !difference.removed.isEmpty {
            parts.append("the box does not run with \(difference.removed.joined(separator: ", "))")
        }
        return Declaration.Finding(
            code: FindingCode.staleSidecar,
            text: "the sidecar declares a different set of keys than the box runs with: "
                + parts.joined(separator: ", and "))
    }
}

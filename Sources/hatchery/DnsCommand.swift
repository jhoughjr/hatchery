import ArgumentParser
import Foundation
import HatcheryKit

/// The resolver's own verb.
///
/// A resolver's conf used to be a file a person edited on the box, so the names it answered and the names its kind declared
/// were one fact kept in two places. The declaration is the record now and this renders the file from it.
struct Dns: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dns",
        abstract: "Render a resolver's configuration from what its kind declares.",
        subcommands: [Render.self]
    )

    struct Render: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "render",
            abstract: "Print the dnsmasq configuration a resolver's kind implies.",
            discussion: """
                The kind names what the resolver answers and where it forwards, and the house shape is the same for every \
                resolver, so the file is a reading of the declaration rather than a thing to keep in step with it.

                Write it to the path the container mounts and restart the container. Until it is written, `hatchery declared` \
                reports the difference as `resolver-conf-drift`.
                """
        )

        @Argument(help: "The kind to render, by name.")
        var kind: String

        @Option(name: .shortAndLong, help: "Path to the stack manifest whose registry holds the kind.")
        var manifest: String = "hatchery.json"

        func run() async throws {
            let manifestPath = try ManifestLocator.resolve(self.manifest)
            let registry = KindRegistry(manifestPath: manifestPath)
            guard let file = try registry.kindFile(for: ServiceKind(rawValue: self.kind)) else {
                throw ValidationError("the registry beside \(manifestPath) declares no kind '\(self.kind)'")
            }
            guard file.resolves != nil || file.forwards != nil else {
                throw ValidationError("'\(self.kind)' declares no names and no forwarders, so there is no resolver configuration to render")
            }
            print(DnsConf.render(file), terminator: "")
        }
    }
}

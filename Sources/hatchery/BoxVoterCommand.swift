import ArgumentParser
import Foundation
import HatcheryKit

/// Makes a box a voter, or takes it out of the vote, in the declaration.
struct Voter: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voter",
        abstract: "Make a box watch its peers and vote on them, or take it out of the vote.",
        discussion: """
            The boxes watch each other with no coordinator: each voter runs the watcher from its roost checkout, \
            probes every other voter, and works the majority out itself. This declares the watcher job on a host \
            stack, records the name the box votes under and the address its peers reach it at, and writes every \
            voter's peers into its config, so the vote is what the manifests say. It changes the declaration only: \
            `hatchery install --yes` with the same manifests puts the job on each box. --remove takes the box out \
            of every peers list. Give every manifest that holds a voter, or a voter left out keeps its old peers.
            """
    )

    @Argument(help: "The host stack of the box.")
    var stack: String

    @Option(name: .long, help: "The name the box votes under, such as opi.")
    var `as`: String?

    @Option(name: .long, help: "Where its peers reach it, as host:port, by a name on the tailnet.")
    var address: String?

    @Flag(name: .long, help: "Take the box out of the vote.")
    var remove = false

    @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
    var manifest: [String] = []

    func run() async throws {
        let requested = self.manifest.isEmpty ? [ManifestLocator.defaultName] : self.manifest
        var loaded = try requested.map { try ManifestLocator.load($0) }
        guard let at = loaded.firstIndex(where: { $0.manifest.stacks.contains { $0.name == self.stack } }) else {
            throw ValidationError("\(BoxVoters.Failure.noStack(self.stack))")
        }
        if self.remove {
            try BoxVoters.remove(stack: self.stack, from: &loaded[at].manifest)
        } else {
            let current = loaded[at].manifest.stacks.first { $0.name == self.stack }?.settings
            guard let name = self.as ?? current?[BoxVoters.nameKey], let address = self.address ?? current?[BoxVoters.addressKey] else {
                throw ValidationError("a new voter needs --as <name> and --address <host:port>")
            }
            try BoxVoters.enrol(stack: self.stack, as: name, address: address, in: &loaded[at].manifest)
        }
        try loaded[at].manifest.write(to: loaded[at].path)

        // Every voter's config takes the peers as they stand now, so nobody keeps a box that left or misses one that came.
        let voters = BoxVoters.voters(in: loaded.map(\.manifest))
        for entry in loaded {
            for stack in entry.manifest.stacks {
                guard let voter = voters.first(where: { $0.stack == stack.name }),
                    let service = stack.services.first(where: { $0.name == BoxVoters.serviceName })
                else { continue }
                let url = ConfigSync.configURL(for: service, in: stack, manifestPath: entry.path)
                let existing = (try? ConfigSync.readDeclared(at: url)) ?? [:]
                let config = BoxVoters.config(for: voter, among: voters, existing: existing)
                let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: url, options: .atomic)
                print("  \(voter.name) on \(stack.name): peers \(config["BOX_WATCH_PEERS"].map { $0.isEmpty ? "none" : $0 } ?? "none")")
            }
        }
        print(self.remove
            ? "  \(self.stack) is out of the vote. Run hatchery install --yes with these manifests, and stop its watcher on the box."
            : "  \(voters.count) voter(s). Run hatchery install --yes with these manifests to put the watcher on each box.")
    }
}

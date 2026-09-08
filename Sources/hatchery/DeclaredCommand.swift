import ArgumentParser
import Foundation
import HatcheryKit

/// The read door on the declaration.
/// `hatchery serve` renders a page on loopback, and nothing on the box can read it, so this prints the same facts as one JSON document.
struct Declared: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "declared",
        abstract: "Print what the manifests declare as JSON, and publish it to pulse.",
        discussion: """
            One document of stacks and services, with the host, the kind, the image and the names, \
            and never a config value. With --publish the same document goes to pulse, where the coop \
            reads it beside what roost found answering.

            Each service also carries its findings: a secret still sitting in the sidecar, and a \
            sidecar whose key set no longer matches the box. Filling them reads the live \
            environment of every service, so the document costs one call per service.

            --answers prints one line per service instead, as `name kind backend`, which is the \
            list roost's reconcile should expect to find answering. It reads no box.
            """
    )

    @Option(name: .shortAndLong, help: "Path to a stack manifest. Repeat it to read several.")
    var manifest: [String] = []

    @Flag(name: .long, help: "POST the document to pulse, with the roost node key.")
    var publish = false

    @Option(name: .long, help: "The pulse instance to publish to.")
    var pulse: String = "https://pulse.jimmyhoughjr.net"

    @Option(name: .long, help: "The file holding the pulse node key.")
    var keyFile: String = "~/.roost_node_key"

    @Option(name: .long, help: "Write this pulse URL into each manifest as its publish target, so every later write publishes on its own. An empty string clears it.")
    var publishTo: String?

    @Flag(name: .long, help: "Print one line per service, as `name kind backend`, instead of the document.")
    var answers = false

    func run() async throws {
        let requested = self.manifest.isEmpty ? [ManifestLocator.defaultName] : self.manifest
        var loaded: [(manifest: StackManifest, path: String)] = []
        for request in requested {
            loaded.append(try ManifestLocator.load(request))
        }
        if let target = self.publishTo {
            // Setting the target is a write, and a write publishes, so each manifest reaches pulse here on its own.
            loaded = try loaded.map { entry in
                var manifest = entry.manifest
                manifest.publish = target.isEmpty ? nil : target
                try manifest.write(to: entry.path)
                return (manifest: manifest, path: entry.path)
            }
            print("  publish target \(target.isEmpty ? "cleared" : "set to " + target) on \(loaded.count) manifest(s)")
        }
        // The answers list says nothing about the saying of the declaration, so it skips the audit and
        // the round trip per service the audit costs.
        if self.answers {
            Declaration(manifests: loaded).answers.forEach { print($0) }
            return
        }

        let document = Declaration(
            manifests: loaded, findings: await DeclarationAudit().findings(for: loaded))
        let data = try document.encoded()
        print(String(decoding: data, as: UTF8.self))

        guard self.publish else { return }
        let key = try Declaration.nodeKey(at: self.keyFile)
        if let reason = await Declaration.publish(data, to: self.pulse, key: key) {
            FileHandle.standardError.write(Data("  publish: pulse did not take the document (\(reason))\n".utf8))
            throw ExitCode.failure
        }
        FileHandle.standardError.write(Data("  published \(document.stacks.count) stack(s) to \(self.pulse)/api/declared\n".utf8))
    }
}

import Foundation
import Testing

@testable import HatcheryKit

/// lan-dns as the box declares it, which is the only resolver the estate has.
private func resolverKind() -> KindFile {
    KindFile(
        kind: "lan-dns",
        resolves: [
            KindFile.Resolution(name: "vault.jimmyhoughjr.net", answer: "192.168.0.103"),
            KindFile.Resolution(name: "coop-mini.jimmyhoughjr.net", answer: "192.168.0.252"),
            KindFile.Resolution(name: "github.com"),
        ],
        forwards: ["1.1.1.1", "8.8.8.8"])
}

@Suite("The configuration a resolver's declaration renders")
struct DnsConfTests {
    @Test("a declared name with an answer becomes an address line")
    func namesBecomeAddresses() {
        let directives = DnsConf.directives(of: DnsConf.render(resolverKind()))

        #expect(directives.contains("address=/vault.jimmyhoughjr.net/192.168.0.103"))
        #expect(directives.contains("address=/coop-mini.jimmyhoughjr.net/192.168.0.252"))
    }

    @Test("a name with no answer is a probe target and not an address")
    func aForwardedNameIsNotAnAddress() {
        let rendered = DnsConf.render(resolverKind())

        #expect(!rendered.contains("address=/github.com/"))
    }

    @Test("the forwarders are declared rather than left in the file")
    func forwardersAreRendered() {
        let directives = DnsConf.directives(of: DnsConf.render(resolverKind()))

        #expect(directives.contains("server=1.1.1.1"))
        #expect(directives.contains("server=8.8.8.8"))
    }

    @Test("every rendered resolver binds dynamically, whatever it answers")
    func theHouseShapeIsAlwaysThere() {
        let directives = DnsConf.directives(of: DnsConf.render(resolverKind()))

        // bind-interfaces is the fault of 2026-09-10, so it must never be what a render produces.
        #expect(directives.contains("bind-dynamic"))
        #expect(!directives.contains("bind-interfaces"))
        #expect(directives.contains("port=53"))
    }

    @Test("comments and order are not the promise, so they are not drift")
    func commentsAreNotDrift() {
        let kind = resolverKind()
        let reordered = DnsConf.directives(of: DnsConf.render(kind)).sorted().joined(separator: "\n")
        let commented = "# a comment somebody wrote\n\n" + reordered + "\n"

        let (extra, missing) = DnsConf.drift(declared: kind, onBox: commented)

        #expect(extra.isEmpty)
        #expect(missing.isEmpty)
    }

    @Test("a line added by hand on the box is named as extra")
    func aHandEditIsExtra() {
        let kind = resolverKind()
        let onBox = DnsConf.render(kind) + "address=/sneaky.example/10.0.0.9\n"

        let (extra, missing) = DnsConf.drift(declared: kind, onBox: onBox)

        #expect(extra == ["address=/sneaky.example/10.0.0.9"])
        #expect(missing.isEmpty)
    }

    @Test("a declared name the box does not carry is named as missing")
    func anUnwrittenNameIsMissing() {
        let kind = resolverKind()
        let onBox = DnsConf.render(kind)
            .replacingOccurrences(of: "address=/vault.jimmyhoughjr.net/192.168.0.103\n", with: "")

        let (extra, missing) = DnsConf.drift(declared: kind, onBox: onBox)

        #expect(missing == ["address=/vault.jimmyhoughjr.net/192.168.0.103"])
        #expect(extra.isEmpty)
    }
}

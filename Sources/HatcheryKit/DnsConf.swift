import Foundation

/// The dnsmasq configuration a resolver's declaration implies.
///
/// The conf on the box used to be a file a person edited, so the names it answered and the names its kind declared were the
/// same facts kept in two places with nothing holding them equal. This renders one from the other, and the audit compares
/// what the box holds against it.
public enum DnsConf {
    /// The directives every house resolver carries, whatever it answers.
    ///
    /// `bind-dynamic` rather than `bind-interfaces` is the one that matters. `bind-interfaces` enumerates the interfaces once
    /// at startup, so a resolver that starts before the LAN interface has an address binds loopback alone and never
    /// reconsiders, which took the house's DNS out for two hours on 2026-09-10.
    static let fixed = [
        "interface=*",
        "bind-dynamic",
        "port=53",
        "domain-needed",
        "bogus-priv",
        "cache-size=1000",
        "log-facility=-",
    ]

    /// The conf text for a kind, ready to be written to the box.
    ///
    /// A declared name with no answer is left out. It is a probe target rather than an address, which is what a forwarded
    /// name is: something to ask about, not something to answer.
    public static func render(_ kind: KindFile) -> String {
        var lines = [
            "# Rendered by hatchery from \(kind.kind)'s declaration. Edits here are overwritten and are reported as drift.",
            "#",
            "# The names answered locally. These are public names, so they resolve to Cloudflare from anywhere including",
            "# from inside the house, which sends a request to a box on the same switch out to the internet and back.",
            "# Answering them here is what makes the LAN the LAN.",
        ]
        for resolution in kind.resolves ?? [] {
            guard let answer = resolution.answer else { continue }
            lines.append("address=/\(resolution.name)/\(answer)")
        }
        lines.append("")
        lines.append("# Everything else is forwarded. This is a local answer for a few names, not a resolver policy.")
        for forward in kind.forwards ?? [] {
            lines.append("server=\(forward)")
        }
        lines.append("")
        lines.append("# The house shape, which every resolver carries whatever it answers.")
        lines.append(contentsOf: fixed)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The directives a conf carries, with comments, blank lines and order thrown away.
    ///
    /// Comparing the text would report drift for a reworded comment, which is not a fault. The directives are the promise.
    public static func directives(of conf: String) -> Set<String> {
        Set(
            conf.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    /// What the box holds that the declaration does not ask for, and what it asks for that the box does not hold.
    public static func drift(declared: KindFile, onBox conf: String) -> (extra: [String], missing: [String]) {
        let wanted = directives(of: render(declared))
        let held = directives(of: conf)
        return (extra: held.subtracting(wanted).sorted(), missing: wanted.subtracting(held).sorted())
    }
}

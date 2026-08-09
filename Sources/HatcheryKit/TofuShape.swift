import Foundation

/// The per-app details a `dokku_app` declaration carries that the manifest does not.
///
/// The clone used to ask the person for these — port, network, gating — with defaults that
/// were silently wrong: a defaulted-nil network drops the very block whose own comment says
/// removing it cuts the app off from its database. The source's tofu files already say what
/// each app uses, so they are read rather than asked for.
public struct ServiceShape: Sendable, Equatable {
    public let containerPort: Int?
    public let network: String?
    public let gated: Bool

    public init(containerPort: Int?, network: String?, gated: Bool) {
        self.containerPort = containerPort
        self.network = network
        self.gated = gated
    }
}

/// Reads app shapes out of a directory of tofu files.
///
/// Not an HCL parser. It finds `resource "dokku_app"` blocks by brace matching and pulls three
/// attributes out with plain scans — the same shapes hatchery itself writes and the lab's
/// hand-written files use. An attribute it cannot find is nil, never a guess.
public enum TofuShapeReader {
    /// Shapes by dokku app name, from every `.tf` file in the directory.
    public static func shapes(
        inTofuDirectory directory: String,
        list: (String) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0) },
        read: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) }
    ) -> [String: ServiceShape] {
        let expanded = Paths.expanded(directory)
        guard let names = try? list(expanded) else { return [:] }

        var shapes: [String: ServiceShape] = [:]
        for name in names.sorted() where name.hasSuffix(".tf") {
            guard let text = try? read(Paths.join(expanded, name)) else { continue }
            for block in appBlocks(in: text) {
                guard let app = attribute("app_name", in: block) else { continue }
                shapes[app] = ServiceShape(
                    containerPort: attribute("container_port", in: block).flatMap(Int.init),
                    network: attribute("attach_post_create", in: block),
                    gated: block.contains("count") && block.contains("var.enable_"))
            }
        }
        return shapes
    }

    /// The bodies of every `resource "dokku_app" … { … }` block in one file.
    static func appBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var search = text.startIndex
        while let match = text.range(of: "resource \"dokku_app\"", range: search..<text.endIndex) {
            guard let open = text[match.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            var end: String.Index?
            while index < text.endIndex {
                let character = text[index]
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                }
                index = text.index(after: index)
            }
            guard let end else { break }
            blocks.append(String(text[open...end]))
            search = text.index(after: end)
        }
        return blocks
    }

    /// The value of `name = "value"` or `"name" = "value"` inside a block, first occurrence.
    static func attribute(_ name: String, in block: String) -> String? {
        var search = block.startIndex
        while let found = block.range(of: name, range: search..<block.endIndex) {
            search = found.upperBound
            let rest = block[found.upperBound...]
            let trimmedLead = rest.drop(while: { $0 == "\"" || $0 == " " || $0 == "\t" })
            guard trimmedLead.first == "=" else { continue }
            let afterEquals = trimmedLead.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            guard afterEquals.first == "\"" else {
                // A bare value: digits, up to whitespace or newline.
                let value = afterEquals.prefix(while: { !$0.isWhitespace && $0 != "\n" })
                return value.isEmpty ? nil : String(value)
            }
            let body = afterEquals.dropFirst()
            guard let close = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<close])
        }
        return nil
    }
}

import Foundation

public enum HostError: Error, CustomStringConvertible, Equatable {
    case unknown(String, known: [String])
    case invalidName(String)

    public var description: String {
        switch self {
        case .unknown(let name, let known):
            return known.isEmpty
                ? "no saved host named '\(name)'; none are saved yet"
                : "no saved host named '\(name)'; saved: \(known.joined(separator: ", "))"
        case .invalidName(let name):
            return "'\(name)' is not a usable host name; expected letters, digits, dashes"
        }
    }
}

/// Named SSH targets, so a box is written once and referred to afterwards.
///
/// An address is the same thing in six places — the stack that runs on it, the preflight check,
/// every logs and restart call — and retyping it is how `192.168.0.103` becomes `192.168.0.130`
/// in exactly one of them.
public enum HostRegistry {
    /// The prefix that means "look this up" rather than "connect to this".
    public static let reference: Character = "@"

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Resolves `@name` against the saved hosts, and leaves anything else alone.
    ///
    /// A literal target is passed through untouched, so nothing has to be saved before it can
    /// be used — the registry is a convenience, not a gate.
    public static func resolve(
        _ target: String, in hosts: [String: String]
    ) throws -> String {
        guard target.first == reference else { return target }
        let name = String(target.dropFirst())
        guard let saved = hosts[name] else {
            throw HostError.unknown(name, known: hosts.keys.sorted())
        }
        return saved
    }

    /// Every target worth offering: the ones saved by name, plus the ones already in use.
    ///
    /// A host a stack already runs on is known whether or not anyone saved it, and leaving it
    /// out would mean the list omits the box you are most likely to pick.
    public static func known(
        saved: [String: String],
        stacks: [StackSpec],
        advertised: [(name: String, target: String)] = RoostHosts.hosts()
    ) -> [(name: String?, target: String)] {
        var seen = Set<String>()
        var result: [(name: String?, target: String)] = []

        for name in saved.keys.sorted() {
            guard let target = saved[name], seen.insert(target).inserted else { continue }
            result.append((name, target))
        }
        for stack in stacks {
            guard let host = stack.host, !host.isEmpty, seen.insert(host).inserted else { continue }
            result.append((nil, host))
        }
        // roost configures the boxes, so it already knows they exist. Asking it beats making
        // someone retype an address that is written down two directories away.
        for entry in advertised where seen.insert(entry.target).inserted {
            result.append((entry.name, entry.target))
        }
        return result
    }
}

extension StackManifest {
    /// The saved hosts, or an empty map when none have been.
    public var savedHosts: [String: String] {
        hosts ?? [:]
    }

    public func savingHost(_ name: String, target: String) throws -> StackManifest {
        guard HostRegistry.isValidName(name) else {
            throw HostError.invalidName(name)
        }
        var copy = self
        var updated = copy.savedHosts
        updated[name] = target
        copy.hosts = updated
        return copy
    }

    public func removingHost(_ name: String) throws -> StackManifest {
        var copy = self
        var updated = copy.savedHosts
        guard updated.removeValue(forKey: name) != nil else {
            throw HostError.unknown(name, known: updated.keys.sorted())
        }
        copy.hosts = updated.isEmpty ? nil : updated
        return copy
    }
}

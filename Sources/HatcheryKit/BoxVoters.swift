import Foundation

/// The boxes that watch each other: which host stacks vote, under what name, and at what address.
///
/// A box votes when its host stack declares the watcher job and names itself. Enrolling a box declares the job on its
/// stack and writes its peers into every voter's config, and removing one takes it out of every peers list, so the
/// vote is read from the declaration and from nowhere else. `hatchery install --yes` then puts the job on the box.
/// Ruled on 2026-09-30, house#51 and #52: the watcher is a declared job that comes with adoption.
public enum BoxVoters {
    public static let serviceName = "box-watch"
    public static let configFile = "box-watch.config.json"
    /// The stack settings that say a box votes: the name it votes under, and where its peers reach it.
    public static let nameKey = "watchName"
    public static let addressKey = "watchAddress"
    public static let port = 9211
    public static let intervalSeconds = 30

    /// One voter, as its stack declares it.
    public struct Voter: Sendable, Equatable {
        public var stack: String
        public var name: String
        public var address: String
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noStack(String)
        case notAHost(String)
        case noRoost(String)
        case notAVoter(String)

        public var description: String {
            switch self {
            case .noStack(let stack): return "no manifest names a stack called \(stack)"
            case .notAHost(let stack): return "\(stack) is not a host stack, and only a box votes"
            case .noRoost(let stack):
                return "no job on \(stack) runs from a roost checkout, so where the watcher lives on that box is unknown; declare the node report first"
            case .notAVoter(let stack): return "\(stack) does not vote, so there is nothing to remove"
            }
        }
    }

    /// Every voter the manifests declare, in manifest order.
    public static func voters(in manifests: [StackManifest]) -> [Voter] {
        manifests.flatMap(\.stacks).compactMap { stack in
            guard stack.services.contains(where: { $0.name == Self.serviceName }),
                let name = stack.settings?[Self.nameKey], let address = stack.settings?[Self.addressKey]
            else { return nil }
            return Voter(stack: stack.name, name: name, address: address)
        }
    }

    /// The peers line one voter's watcher reads: every other voter as `name=address`, in name order.
    public static func peersLine(for voter: Voter, among voters: [Voter]) -> String {
        voters.filter { $0.name != voter.name }.sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.address)" }.joined(separator: ",")
    }

    /// The watcher job as a box declares it. It is kept alive, because a watcher that stopped is a box nobody hears.
    static func service(program: String, log: String?) throws -> ServiceSpec {
        var job: [String: Any] = ["keepAlive": true, "program": [program], "runAtLoad": true]
        if let log { job["log"] = log }
        let document: [String: Any] = [
            "configFile": Self.configFile, "domains": [String](), "image": "", "kind": "job", "name": Self.serviceName,
            "job": job,
        ]
        return try JSONDecoder().decode(ServiceSpec.self, from: JSONSerialization.data(withJSONObject: document))
    }

    /// Makes one host stack a voter: the job on its stack, and its name and address in the stack's settings.
    /// A stack that already votes keeps its job and takes the new name and address.
    public static func enrol(stack name: String, as voter: String, address: String, in manifest: inout StackManifest) throws {
        guard let index = manifest.stacks.firstIndex(where: { $0.name == name }) else { throw Failure.noStack(name) }
        var stack = manifest.stacks[index]
        guard stack.backend == .host else { throw Failure.notAHost(name) }
        if !stack.services.contains(where: { $0.name == Self.serviceName }) {
            let root = InstallPlan.roostRoot(in: stack, platform: stack.platform)
            guard !root.hasPrefix("$HOME") else { throw Failure.noRoost(name) }
            let home = (root as NSString).deletingLastPathComponent
            let log = stack.platform == .darwin
                ? (home.hasSuffix("/repos") ? (home as NSString).deletingLastPathComponent : home) + "/Library/Logs/box-watch.log" : nil
            stack.services.append(try Self.service(program: root + "/bin/box-watch.py", log: log))
        }
        var settings = stack.settings ?? [:]
        settings[Self.nameKey] = voter
        settings[Self.addressKey] = address
        stack.settings = settings
        manifest.stacks[index] = stack
    }

    /// Takes one stack out of the vote: its job and its two settings go.
    public static func remove(stack name: String, from manifest: inout StackManifest) throws {
        guard let index = manifest.stacks.firstIndex(where: { $0.name == name }) else { throw Failure.noStack(name) }
        var stack = manifest.stacks[index]
        guard stack.services.contains(where: { $0.name == Self.serviceName }) else { throw Failure.notAVoter(name) }
        stack.services.removeAll { $0.name == Self.serviceName }
        stack.settings?[Self.nameKey] = nil
        stack.settings?[Self.addressKey] = nil
        manifest.stacks[index] = stack
    }

    /// The config one voter's watcher reads, with what a person already set in it kept.
    public static func config(for voter: Voter, among voters: [Voter], existing: [String: String]) -> [String: String] {
        var config = existing
        config["BOX_WATCH_NAME"] = voter.name
        config["BOX_WATCH_PEERS"] = Self.peersLine(for: voter, among: voters)
        if config["BOX_WATCH_INTERVAL"] == nil { config["BOX_WATCH_INTERVAL"] = String(Self.intervalSeconds) }
        if config["BOX_WATCH_STACKS"] == nil { config["BOX_WATCH_STACKS"] = voter.stack }
        return config
    }
}

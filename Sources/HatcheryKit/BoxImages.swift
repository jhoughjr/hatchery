import Foundation

/// The images a box has pulled, which are not the same thing as the versions a registry keeps.
///
/// A deploy pulls an image onto the box and leaves it there, so a busy day of deploys fills the disk even while the registry is tidy.
/// On 2026-09-16 the opi reached zero bytes free with 54 rookery images on it, and a push to the forge was rejected for it.
public enum BoxImages {
    /// What a prune did on one box.
    public struct Outcome: Sendable, Equatable {
        public var repository: String
        public var removed: [String]
        public var kept: [String]
        public var freeAfter: String
    }

    /// The tags to keep: what the box runs, and the newest `keep` of the rest.
    ///
    /// `listing` is `<tag> <created>` a line, newest first or not, as `docker images` prints it.
    public static func keeping(_ listing: String, keep: Int, running: [String]) -> Set<String> {
        var held = Set(running.filter { !$0.isEmpty })
        held.insert("latest")
        let rows = listing.split(separator: "\n").map(String.init).compactMap { line -> (tag: String, created: String)? in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, parts[0] != "<none>" else { return nil }
            return (parts[0], parts[1].trimmingCharacters(in: .whitespaces))
        }
        let newest = rows.sorted { $0.created > $1.created }.prefix(max(0, keep)).map(\.tag)
        held.formUnion(newest)
        return held
    }

    /// Removes every image of one repository the box does not need, over ssh.
    ///
    /// The box is named as an ssh target, such as `jimmy@192.168.0.103`. Nothing but the named repository is touched,
    /// because another product's images on the same box are that product's business.
    public static func prune(
        box: String, repository: String, keep: Int, running: [String],
        run: (String, [String]) -> (status: Int32, out: String) = BoxImages.ssh
    ) -> Outcome? {
        let listed = run("/usr/bin/ssh", ["-o", "BatchMode=yes", box, "docker images --format '{{.Tag}} {{.CreatedAt}}' \(repository)"])
        guard listed.status == 0 else { return nil }
        let held = Self.keeping(listed.out, keep: keep, running: running)
        let tags = listed.out.split(separator: "\n").compactMap { line -> String? in
            let tag = line.split(separator: " ").first.map(String.init) ?? ""
            return tag.isEmpty || tag == "<none>" || held.contains(tag) ? nil : tag
        }
        var removed: [String] = []
        // One call for the lot, because a hundred ssh round trips is a minute of waiting for nothing.
        if !tags.isEmpty {
            let names = tags.map { "\(repository):\($0)" }.joined(separator: " ")
            let gone = run("/usr/bin/ssh", ["-o", "BatchMode=yes", box, "docker rmi -f \(names) >/dev/null 2>&1; echo done"])
            if gone.status == 0 { removed = tags }
        }
        let free = run("/usr/bin/ssh", ["-o", "BatchMode=yes", box, "df -h / | tail -1"])
        return Outcome(
            repository: repository, removed: removed, kept: held.sorted(),
            freeAfter: free.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One ssh call, with its output.
    public static func ssh(_ program: String, _ arguments: [String]) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (1, "")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

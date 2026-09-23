import Foundation

/// What a box has left, and the room a deploy can give back without asking anybody.
///
/// A deploy pulls an image and leaves it, and a build leaves its cache. Twice on 2026-09-16 the opi filled: once to 551 MB,
/// which failed an image build, and once to zero, which made the forge reject a push. Both were images nothing needed.
public enum BoxSpace {
    /// What one box reports.
    public struct Report: Sendable, Equatable {
        public var filesystem: String
        public var size: String
        public var used: String
        public var free: String
        /// How full, from 0 to 100.
        public var percent: Int
        /// The repositories with the most images on the box, largest count first.
        public var repositories: [(name: String, images: Int)]

        public static func == (left: Report, right: Report) -> Bool {
            left.filesystem == right.filesystem && left.percent == right.percent
                && left.repositories.map(\.name) == right.repositories.map(\.name)
        }

        /// A box with less than a tenth left is worth acting on, which is the rule the board's disks already use.
        public var low: Bool { self.percent >= 90 }
    }

    /// Reads one `df -h /` line, as the box prints it.
    public static func readDisk(_ line: String) -> Report? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 5, let percent = Int(parts[4].replacingOccurrences(of: "%", with: "")) else { return nil }
        return Report(
            filesystem: parts[0], size: parts[1], used: parts[2], free: parts[3], percent: percent, repositories: [])
    }

    /// Reads `docker images --format '{{.Repository}}'`, counting each repository.
    public static func readRepositories(_ listing: String) -> [(name: String, images: Int)] {
        var counts: [String: Int] = [:]
        for line in listing.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "<none>" else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { (name: $0.key, images: $0.value) }
    }

    /// What the box has left, and what is taking it.
    public static func report(
        box: String, run: (String, [String]) -> (status: Int32, out: String) = BoxImages.ssh
    ) -> Report? {
        let disk = run("/usr/bin/ssh", ["-o", "BatchMode=yes", box, "df -h / | tail -1"])
        guard disk.status == 0, var report = Self.readDisk(disk.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let images = run("/usr/bin/ssh", ["-o", "BatchMode=yes", box, "docker images --format '{{.Repository}}'"])
        if images.status == 0 { report.repositories = Self.readRepositories(images.out) }
        return report
    }

    /// Frees what nothing needs: the build cache, and the images no container references.
    ///
    /// Neither takes anything a running service uses. A build that follows pays for its own cache again, which is the price.
    public static func free(
        box: String, run: (String, [String]) -> (status: Int32, out: String) = BoxImages.ssh
    ) -> Report? {
        _ = run("/usr/bin/ssh", ["-o", "BatchMode=yes", box, "docker builder prune -f"])
        _ = run("/usr/bin/ssh", ["-o", "BatchMode=yes", box, "docker image prune -f"])
        return Self.report(box: box, run: run)
    }
}

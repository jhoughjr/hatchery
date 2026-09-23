import Foundation
import Testing

@testable import HatcheryKit

/// What a box has left, and the room a deploy can give back.
///
/// Twice on 2026-09-16 the opi filled with images nothing needed: once failing an image build, once making the forge reject a push.
@Suite("A box's space")
struct BoxSpaceTests {
    @Test("a df line reads as a report, and a line that is not one reads as nothing")
    func readsDisk() throws {
        let report = try #require(BoxSpace.readDisk("/dev/mmcblk0p1  230G  176G   45G  80% /"))
        #expect(report.filesystem == "/dev/mmcblk0p1")
        #expect(report.free == "45G")
        #expect(report.percent == 80)
        #expect(!report.low)
        #expect(BoxSpace.readDisk("Filesystem Size Used Avail Use% Mounted") == nil)
        #expect(BoxSpace.readDisk("") == nil)
    }

    @Test("a box with a tenth left or less is low, which is the rule the board's disks use")
    func low() throws {
        #expect(try #require(BoxSpace.readDisk("/dev/root 230G 220G 242M 100% /")).low)
        #expect(try #require(BoxSpace.readDisk("/dev/root 230G 200G 20G 90% /")).low)
    }

    @Test("the repositories are counted, largest first, and an untagged image counts for none")
    func countsRepositories() {
        let listing = """
        forge/rookery
        forge/rookery
        forge/rookery
        forge/vault-hb
        <none>
        """
        let counted = BoxSpace.readRepositories(listing)
        #expect(counted.first?.name == "forge/rookery")
        #expect(counted.first?.images == 3)
        #expect(counted.count == 2)
    }

    @Test("freeing takes the build cache and the images nothing references, and nothing else")
    func freeTakesOnlyTheSafeThings() {
        var asked: [String] = []
        let after = BoxSpace.free(box: "box") { _, arguments in
            let command = arguments.last ?? ""
            asked.append(command)
            if command.hasPrefix("df") { return (0, "/dev/root 230G 100G 130G 44% /") }
            if command.hasPrefix("docker images") { return (0, "forge/rookery") }
            return (0, "")
        }
        #expect(after?.percent == 44)
        #expect(asked.contains("docker builder prune -f"))
        #expect(asked.contains("docker image prune -f"))
        // Nothing that removes a tagged image, which belongs to the retention rule and not to this.
        #expect(!asked.contains { $0.contains("docker rmi") })
        #expect(!asked.contains { $0.contains("-a") })
    }

    @Test("a box that does not answer reports nothing, rather than a guess")
    func aSilentBox() {
        #expect(BoxSpace.report(box: "nowhere") { _, _ in (255, "") } == nil)
    }
}

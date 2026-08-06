import Foundation
import Testing

@testable import HatcheryKit

/// The one place a real filesystem is warranted.
///
/// Every other seal test injects `exists`, and that is exactly why this shipped broken: symlink
/// resolution happens below the injection seam, so a fake `exists` cannot see it. The manifest is
/// normally symlinked in from `~/.config/hatchery/hatchery.json`, the walk climbed out of
/// `~/.config`, and every automatic seal decided there was nothing to seal — silently.
@Suite("Finding the sealed root through a symlink")
struct SealSymlinkTests {
    /// A state directory with the marker, plus a symlink pointing into it from elsewhere.
    private func makeFixture() throws -> (root: String, link: String, cleanup: () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hatchery-seal-\(UUID().uuidString)")
        let state = base.appendingPathComponent("infra-state")
        let stack = state.appendingPathComponent("mwserver-tf")
        let elsewhere = base.appendingPathComponent("config/hatchery")

        try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "age1example\n".write(
            to: state.appendingPathComponent(SealedState.marker), atomically: true, encoding: .utf8)

        let real = stack.appendingPathComponent("hatchery.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)

        let link = elsewhere.appendingPathComponent("hatchery.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        return (state.path, link.path, { try? FileManager.default.removeItem(at: base) })
    }

    @Test("a symlinked manifest still finds the directory that seals it")
    func resolvesThroughSymlink() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let found = SealedState.root(containing: fixture.link)

        // Without resolution this is nil, and every automatic seal quietly does nothing.
        #expect(found != nil)
        #expect(
            found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == URL(fileURLWithPath: fixture.root).resolvingSymlinksInPath().path)
    }

    @Test("the real path finds it too")
    func resolvesDirectPath() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let direct = fixture.root + "/mwserver-tf/hatchery.json"
        #expect(SealedState.root(containing: direct) != nil)
    }

    /// The seam that actually matters: sealing is skipped on `.notSealed`, so a root that cannot
    /// be found is indistinguishable from a directory nobody asked to encrypt.
    @Test("the sealer runs the script rather than reporting nothing to do")
    func sealerReachesTheScript() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try "#!/bin/sh\nexit 0\n".write(
            toFile: fixture.root + "/" + SealedState.scriptName, atomically: true, encoding: .utf8)

        actor Ran {
            var directories: [String?] = []
            func record(_ d: String?) { directories.append(d) }
        }
        let ran = Ran()
        let sealer = StateSealer(execute: { _, directory in
            await ran.record(directory)
            return CommandOutput(status: 0, standardOutput: "sealed", standardError: "")
        })

        let outcome = await sealer.seal(pathInside: fixture.link)

        #expect(outcome.isProblem == false)
        if case .notSealed = outcome {
            Issue.record("a symlinked manifest reported .notSealed, so nothing would be backed up")
        }
        await #expect(ran.directories.count == 1)
    }
}

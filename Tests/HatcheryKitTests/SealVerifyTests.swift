import Foundation
import Testing

@testable import HatcheryKit

@Suite("Reading what unseal --check reported")
struct SealVerifyInterpretationTests {
    @Test("every file matching is a verified backup")
    func allOk() {
        let result = SealVerifier.interpret(
            output: """
                ok       a.config.json
                ok       sub/terraform.tfstate
                """, status: 0)
        #expect(result == .verified(files: 2))
        #expect(!result.isProblem)
    }

    /// The archive opened; a file inside disagrees. Bad, but the backup exists and most of it is
    /// recoverable — a different situation from one that will not open at all.
    @Test("a content mismatch names the files")
    func mismatch() {
        let result = SealVerifier.interpret(
            output: """
                ok       a.config.json
                DIFFERS  terraform.tfstate
                MISSING  gone.config.json
                """, status: 1)
        #expect(result == .mismatch(missing: ["gone.config.json"], differing: ["terraform.tfstate"]))
        #expect(result.isProblem)
    }

    /// The case that prompted all this: `state status` reports "ok" for an archive that is seven
    /// bytes of garbage, because it never opens it. Verification has to see through that.
    @Test("an archive that does not open is not a backup")
    func corrupt() {
        let result = SealVerifier.interpret(
            output: "age: error: failed to read header: unexpected EOF\ntar: Unexpected EOF",
            status: 1)
        guard case .unopenable = result else {
            Issue.record("a corrupt archive must not read as anything but unopenable, got \(result)")
            return
        }
        #expect(result.isProblem)
        #expect(result.summary.contains("unusable"))
    }

    /// Exit status alone cannot separate this from a mismatch — the script exits 1 for both — so
    /// the distinction is whether it managed to say anything about any file.
    @Test("silence with a failure is unopenable, not a pass")
    func silentFailure() {
        let result = SealVerifier.interpret(output: "", status: 1)
        guard case .unopenable = result else {
            Issue.record("expected .unopenable, got \(result)")
            return
        }
    }

    /// Not a broken backup — an unverifiable one. Saying "failed" here would send someone to
    /// re-seal a perfectly good archive; saying "ok" would claim a check that never ran.
    @Test("a missing key is reported as unverifiable, not as failure or success")
    func noIdentity() {
        let result = SealVerifier.interpret(
            output: "error: no age identity at /Users/x/.config/age/infra-state.txt",
            status: 1)
        #expect(result == .noIdentity(path: "/Users/x/.config/age/infra-state.txt"))
        // Still a problem — an unverifiable backup is not a verified one.
        #expect(result.isProblem)
    }

    @Test("a status of zero with no files reported is not a pass")
    func emptyButClean() {
        // Belt and braces: a script that exits 0 having checked nothing must not read as verified.
        guard case .unopenable = SealVerifier.interpret(output: "", status: 0) else {
            Issue.record("checking nothing must not report success")
            return
        }
    }
}

@Suite("Verifying a sealed directory")
struct SealVerifierTests {
    @Test("runs unseal --check from the sealed root")
    func runsScript() async {
        actor Calls {
            var argv: [[String]] = []
            var directories: [String?] = []
            func record(_ a: [String], _ d: String?) { argv.append(a); directories.append(d) }
        }
        let calls = Calls()
        let verifier = SealVerifier(
            execute: { argv, directory in
                await calls.record(argv, directory)
                return CommandOutput(status: 0, standardOutput: "ok  a.config.json", standardError: "")
            },
            // Specific rather than always-true: the marker lives at /infra, so a blanket yes
            // would make the walk stop at the stack directory and hide whether it climbs.
            exists: { path in
                path == "/infra/" + SealedState.marker
                    || path == "/infra/" + SealedState.archiveName
                    || path == "/infra/" + SealVerifier.scriptName
            }
        )

        let result = await verifier.verify(pathInside: "/infra/mwserver-tf")
        #expect(result == .verified(files: 1))
        await #expect(calls.argv == [["./unseal.sh", "--check"]])
        await #expect(calls.directories == ["/infra"])
    }

    @Test("says nothing about a directory that does not seal")
    func notSealed() async {
        let verifier = SealVerifier(
            execute: { _, _ in
                Issue.record("must not run anything outside a sealed directory")
                return CommandOutput(status: 0, standardOutput: "", standardError: "")
            },
            exists: { _ in false })
        #expect(await verifier.verify(pathInside: "/tmp/x") == .notSealed)
    }

    @Test("a directory sealed but never sealed-to reports no archive")
    func noArchive() async {
        let verifier = SealVerifier(
            execute: { _, _ in CommandOutput(status: 0, standardOutput: "", standardError: "") },
            // Marker present, archive absent.
            exists: { $0.hasSuffix(SealedState.marker) })
        #expect(await verifier.verify(pathInside: "/infra") == .noArchive)
    }
}

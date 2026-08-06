import Foundation
import Testing

@testable import HatcheryKit

@Suite("Planning a state directory")
struct StateInitPlanTests {
    @Test("puts the key outside the directory it protects")
    func keyLivesElsewhere() {
        let plan = StateInitPlanner.plan(
            StateInitRequest(directory: "/work/infra-state"), identityExists: { _ in false })
        // The key that opens the archive must not sit in the repository the archive is
        // committed to, or publishing the repo publishes the key with it.
        #expect(!plan.identityPath.hasPrefix(plan.directory))
        #expect(plan.identityPath.hasSuffix("infra-state.txt"))
    }

    @Test("reuses an existing key rather than replacing it")
    func reusesKey() {
        let plan = StateInitPlanner.plan(
            StateInitRequest(directory: "/work/infra-state"), identityExists: { _ in true })
        #expect(plan.reusesIdentity)
        #expect(plan.warnings.contains { $0.contains("Reusing the existing key") })
    }

    /// The identity is the single point of failure, and this is the only moment anyone is
    /// looking. If the warning stops being emitted, nothing else says it.
    @Test("always warns that losing the key loses the backup")
    func warnsAboutTheKey() {
        for exists in [true, false] {
            let plan = StateInitPlanner.plan(
                StateInitRequest(directory: "/work/s"), identityExists: { _ in exists })
            #expect(plan.warnings.contains(StateInitPlanner.identityWarning))
        }
    }

    @Test("says the repository is private when one is named")
    func privateRemote() {
        let plan = StateInitPlanner.plan(
            StateInitRequest(directory: "/work/s", remote: "me/infra"),
            identityExists: { _ in false })
        #expect(plan.warnings.contains { $0.contains("private") })
    }

    /// The whole point of the ignore rules. If a config map or a state file were committable,
    /// the encrypted archive would be pointless.
    @Test("ignores plaintext secrets and the key itself")
    func gitignoreCoversSecrets() {
        let ignore = StateInitPlanner.gitignore
        #expect(ignore.contains("*.config.json"))
        #expect(ignore.contains("terraform.tfstate"))
        #expect(ignore.contains("*.tfvars"))
        #expect(ignore.contains("**/.terraform/"))
    }

    @Test("does not ignore the archive it is meant to commit")
    func archiveIsCommitted() {
        // Sealing is pointless if the result is gitignored along with everything else.
        // Rules only — the comments mention the archive by name, and matching those would
        // pass or fail for reasons that have nothing to do with what git does.
        let rules = StateInitPlanner.gitignore
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        #expect(!rules.contains(SealedState.archiveName))
        #expect(!rules.contains(SealedState.manifestName))
        #expect(rules.contains("*.config.json"))
    }

    /// The audit and the script have to agree on what a secret is. They are separate
    /// implementations, so this pins them together.
    @Test("the generated script seals what the audit checks")
    func scriptMatchesAudit() {
        let script = StateInitPlanner.sealScript
        for name in ["*.config.json", "terraform.tfstate", "terraform.tfstate.backup"] {
            #expect(script.contains(name))
        }
        #expect(SealedState.isSecret("a.config.json"))
        #expect(SealedState.isSecret("terraform.tfstate.backup"))
    }

    @Test("bakes the identity path into unseal.sh")
    func unsealKnowsTheKey() {
        let files = StateInitPlanner.files(identityPath: "/keys/state.txt")
        let unseal = files.first { $0.path == "unseal.sh" }
        // unseal.sh runs on a fresh machine without hatchery, so it cannot be told at runtime.
        #expect(unseal?.contents.contains("/keys/state.txt") == true)
        #expect(unseal?.contents.contains("__IDENTITY__") == false)
        #expect(unseal?.executable == true)
    }
}

@Suite("Setting up a state directory")
struct StateInitializerTests {
    /// Records commands instead of running them, so no key is generated and no repo is touched.
    private final class Recorder: @unchecked Sendable {
        var argv: [[String]] = []
        var written: [String: String] = [:]
        /// What is already on disk, so a re-run reads back what a first run wrote.
        var onDisk: [String: String] = [:]
    }

    private func initializer(
        recorder: Recorder,
        present: @escaping @Sendable (String) -> Bool,
        recipient: String = "age1newkey"
    ) -> StateInitializer {
        StateInitializer(
            execute: { argv, _ in
                recorder.argv.append(argv)
                if argv.first == "age-keygen", argv.contains("-y") {
                    return CommandOutput(status: 0, standardOutput: recipient + "\n", standardError: "")
                }
                return CommandOutput(status: 0, standardOutput: "", standardError: "")
            },
            exists: present,
            // A directory that already exists holds the same recipient the fake key derives,
            // which is what a genuine re-run looks like.
            read: { path in
                recorder.onDisk[path] ?? (path.hasSuffix(SealedState.marker) ? recipient : nil)
            },
            write: { path, contents, _ in recorder.written[path] = contents },
            makeDirectory: { _ in }
        )
    }

    @Test("generates a key when there is none, and derives the recipient from it")
    func generatesKey() async throws {
        let recorder = Recorder()
        let plan = StateInitPlanner.plan(
            StateInitRequest(directory: "/work/s", identityPath: "/keys/s.txt"),
            identityExists: { _ in false })

        let result = try await initializer(recorder: recorder, present: { _ in false }).run(plan)

        #expect(result.generatedIdentity)
        #expect(result.recipient == "age1newkey")
        #expect(recorder.argv.contains(["age-keygen", "-o", "/keys/s.txt"]))
        // Derived, never typed — deriving is also the proof the key opens the archive.
        #expect(recorder.argv.contains(["age-keygen", "-y", "/keys/s.txt"]))
        #expect(recorder.written["/work/s/.age-recipient"] == "age1newkey\n")
    }

    @Test("does not regenerate a key that already exists")
    func keepsKey() async throws {
        let recorder = Recorder()
        let plan = StateInitPlanner.plan(
            StateInitRequest(directory: "/work/s", identityPath: "/keys/s.txt"),
            identityExists: { _ in true })

        let result = try await initializer(
            recorder: recorder, present: { $0 == "/keys/s.txt" }
        ).run(plan)

        #expect(!result.generatedIdentity)
        #expect(!recorder.argv.contains(["age-keygen", "-o", "/keys/s.txt"]))
    }

    /// The failure this must never allow: rewriting `.age-recipient` produces an archive the
    /// previous key cannot open, and nothing says so until a restore is attempted.
    @Test("refuses a key that does not match the existing recipient")
    func refusesMismatch() async {
        let recorder = Recorder()
        let plan = StateInitPlanner.plan(
            StateInitRequest(directory: "/work/s", identityPath: "/keys/other.txt"),
            identityExists: { _ in true })
        let sealer = StateInitializer(
            execute: { argv, _ in
                recorder.argv.append(argv)
                return CommandOutput(status: 0, standardOutput: "age1different\n", standardError: "")
            },
            exists: { $0 == "/keys/other.txt" || $0 == "/work/s/.age-recipient" },
            // The archive is encrypted to one key; the identity given derives another.
            read: { _ in "age1stored" },
            write: { path, contents, _ in recorder.written[path] = contents },
            makeDirectory: { _ in }
        )

        await #expect(throws: StateInitError.self) {
            _ = try await sealer.run(plan)
        }
        // Nothing was overwritten on the way to refusing.
        #expect(recorder.written["/work/s/.age-recipient"] == nil)
    }

    /// A directory that already encrypts to a key, with no key at the identity path, can only
    /// mismatch — and generating first would strand a useless key on disk.
    @Test("refuses before generating when the recipient is already set")
    func refusesBeforeGenerating() async {
        let recorder = Recorder()
        let plan = StateInitPlanner.plan(
            StateInitRequest(directory: "/work/s", identityPath: "/keys/missing.txt"),
            identityExists: { _ in false })

        await #expect(throws: StateInitError.self) {
            _ = try await initializer(
                recorder: recorder, present: { $0 == "/work/s/.age-recipient" }
            ).run(plan)
        }
        #expect(!recorder.argv.contains { $0.first == "age-keygen" && $0.contains("-o") })
    }

    @Test("keeps files a person may have edited, and refreshes the scripts")
    func preservesEdits() async throws {
        let recorder = Recorder()
        let plan = StateInitPlanner.plan(
            StateInitRequest(directory: "/work/s", identityPath: "/keys/s.txt"),
            identityExists: { _ in true })

        // Everything already there: a re-run on a set-up directory.
        let result = try await initializer(
            recorder: recorder, present: { _ in true }, recipient: "age1newkey"
        ).run(plan)

        // README and .gitignore may carry local edits; the scripts are hatchery's, so a fix
        // reaches existing directories rather than only new ones.
        #expect(result.preserved.contains("README.md"))
        #expect(result.preserved.contains(".gitignore"))
        #expect(result.created.contains("seal.sh"))
        #expect(result.created.contains("unseal.sh"))
    }

    @Test("initialises git only when the directory is not already a repository")
    func gitInit() async throws {
        let fresh = Recorder()
        _ = try await initializer(recorder: fresh, present: { _ in false })
            .run(StateInitPlanner.plan(
                StateInitRequest(directory: "/work/s", identityPath: "/keys/s.txt"),
                identityExists: { _ in false }))
        #expect(fresh.argv.contains(["git", "init", "-b", "main"]))

        let existing = Recorder()
        _ = try await initializer(recorder: existing, present: { _ in true })
            .run(StateInitPlanner.plan(
                StateInitRequest(directory: "/work/s", identityPath: "/keys/s.txt"),
                identityExists: { _ in true }))
        #expect(!existing.argv.contains(["git", "init", "-b", "main"]))
    }

    /// Setting the directory up must not publish it. Everything in `run` happens on this
    /// machine; only `publish` sends anything anywhere.
    @Test("setting up pushes nothing")
    func runDoesNotPublish() async throws {
        let recorder = Recorder()
        _ = try await initializer(recorder: recorder, present: { _ in false })
            .run(StateInitPlanner.plan(
                StateInitRequest(directory: "/work/s", identityPath: "/keys/s.txt", remote: "me/infra"),
                identityExists: { _ in false }))

        #expect(!recorder.argv.contains { $0.first == "git" && $0.contains("push") })
        #expect(!recorder.argv.contains { $0.first == "gh" })
    }

    @Test("publishing creates the repository private")
    func publishesPrivately() async throws {
        let recorder = Recorder()
        let plan = StateInitPlanner.plan(
            StateInitRequest(directory: "/work/s", identityPath: "/keys/s.txt", remote: "me/infra"),
            identityExists: { _ in true })

        let result = try await initializer(recorder: recorder, present: { _ in true })
            .publish(plan, message: "Set up")

        // The archive is committed to this repository. Public would publish every credential.
        let create = recorder.argv.first { $0.first == "gh" }
        #expect(create?.contains("--private") == true)
        #expect(result.pushed)
    }
}

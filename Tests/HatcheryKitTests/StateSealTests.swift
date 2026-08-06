import Foundation
import Testing

@testable import HatcheryKit

@Suite("SHA-256")
struct SHA256Tests {
    /// The published FIPS 180-4 vectors. If these pass, the audit agrees with `shasum -a 256`,
    /// which is what wrote the manifest it compares against.
    @Test("matches the published vectors")
    func vectors() {
        #expect(
            SHA256.hex("")
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(
            SHA256.hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// Crosses the 56-byte padding boundary, where the length no longer fits in the final block
    /// and a second block is appended. The off-by-one lives here or nowhere.
    @Test("pads across the block boundary")
    func padding() {
        // 55, 56 and 64 bytes: last that fits, first that spills, exactly one block.
        #expect(
            SHA256.hex(String(repeating: "a", count: 55))
                == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        #expect(
            SHA256.hex(String(repeating: "a", count: 56))
                == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        #expect(
            SHA256.hex(String(repeating: "a", count: 64))
                == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    }

    /// tfstate is text, but nothing guarantees the next thing sealed is. Bytes above 0x7f must
    /// not round-trip through any string conversion on the way to the digest.
    @Test("hashes bytes that are not text")
    func binary() {
        #expect(
            SHA256.hex(Data([0x00, 0xff, 0x80, 0x7f]))
                == "049426b578cc61154a0dffb6e0fe305e12ac496d6e36e0d833d55fffc363fa51")
    }
}

@Suite("Which files hold secrets")
struct SecretPredicateTests {
    @Test("config maps and state count")
    func included() {
        #expect(SealedState.isSecret("mwlab.config.json"))
        #expect(SealedState.isSecret("mwserver-tf/comlab.config.json"))
        #expect(SealedState.isSecret("mwserver-tf/terraform.tfstate"))
        #expect(SealedState.isSecret("mwserver-tf/terraform.tfstate.backup"))
    }

    @Test("declarations and provider binaries do not")
    func excluded() {
        #expect(!SealedState.isSecret("mwlab.tf"))
        #expect(!SealedState.isSecret("hatchery.json"))
        #expect(!SealedState.isSecret("versions.tf"))
        #expect(!SealedState.isSecret(".terraform.lock.hcl"))
    }

    /// `.terraform` holds unpacked provider binaries, some carrying example state. Sealing that
    /// would put 15 MB through age on every apply.
    @Test("prunes .terraform and .git wherever they appear")
    func pruned() {
        #expect(!SealedState.isSecret(".terraform/providers/x/terraform.tfstate"))
        #expect(!SealedState.isSecret("mwserver-tf/.terraform/plugins/a.config.json"))
        #expect(!SealedState.isSecret(".git/objects/terraform.tfstate"))
    }
}

@Suite("Finding the sealed root")
struct SealedRootTests {
    @Test("finds the marker in the directory itself")
    func here() {
        let root = SealedState.root(containing: "/infra") { $0 == "/infra/.age-recipient" }
        #expect(root == "/infra")
    }

    /// The stacks live a level down; the marker sits at the top. Walking up is what makes a
    /// per-stack write find the directory that seals it.
    @Test("walks up to find it")
    func upwards() {
        let root = SealedState.root(containing: "/infra/mwserver-tf") {
            $0 == "/infra/.age-recipient"
        }
        #expect(root == "/infra")
    }

    @Test("reports nothing when no directory seals")
    func absent() {
        #expect(SealedState.root(containing: "/tmp/scratch") { _ in false } == nil)
    }
}

@Suite("Reading the seal manifest")
struct SealManifestTests {
    let sample = """
        # Sealed 2026-08-05T00:47:24Z — contents of secrets.tar.age
        dc7dbaabd620dbfe0ff1664e997c15a90c2746ee5c1e8654d96e80e9520941ab  a.config.json
        0516faa838ab34878d01517e0b41a071e37599e447e483d1a77f676a3a3baa25  sub/b.config.json
        """

    @Test("reads the timestamp and every entry")
    func parses() {
        let (sealedAt, hashes) = SealAudit.parseManifest(sample)
        #expect(sealedAt == "2026-08-05T00:47:24Z")
        #expect(hashes.count == 2)
        #expect(
            hashes["sub/b.config.json"]
                == "0516faa838ab34878d01517e0b41a071e37599e447e483d1a77f676a3a3baa25")
    }

    @Test("survives a manifest that is missing or empty")
    func empty() {
        let (sealedAt, hashes) = SealAudit.parseManifest("")
        #expect(sealedAt == nil)
        #expect(hashes.isEmpty)
    }
}

@Suite("Auditing what is sealed")
struct SealAuditTests {
    /// Builds an audit over a fake directory: no filesystem, no age, no process.
    private func audit(files: [String: String], manifest: String) -> SealAudit {
        SealAudit(
            listFiles: { _ in Array(files.keys) },
            hash: { path in
                // `status` hashes an absolute path; strip the root back off to reach the key.
                let key = path.hasPrefix("/infra/")
                    ? String(path.dropFirst("/infra/".count)) : path
                guard let contents = files[key] else { throw CocoaError(.fileNoSuchFile) }
                return SHA256.hex(contents)
            },
            readManifest: { _ in manifest }
        )
    }

    private func manifest(_ entries: [String: String]) -> String {
        (["# Sealed 2026-08-05T00:00:00Z — contents of secrets.tar.age"]
            + entries.map { "\(SHA256.hex($0.value))  \($0.key)" }.sorted())
            .joined(separator: "\n")
    }

    @Test("says nothing when every secret is in the archive")
    func clean() throws {
        let files = ["a.config.json": "one", "terraform.tfstate": "two"]
        let status = try audit(files: files, manifest: manifest(files)).status(root: "/infra")
        #expect(status.sealed)
        #expect(status.summary == nil)
        #expect(status.sealedAt == "2026-08-05T00:00:00Z")
    }

    /// This is the case that actually happened: a stack scaffolded after the last seal, so its
    /// config exists only on this disk.
    @Test("catches a secret written since the last seal")
    func neverSealed() throws {
        let sealed = ["a.config.json": "one"]
        var files = sealed
        files["staging.config.json"] = "minted-key"

        let status = try audit(files: files, manifest: manifest(sealed)).status(root: "/infra")
        #expect(!status.sealed)
        #expect(status.unsealed == ["staging.config.json"])
        #expect(status.summary == "1 secret file not in the backup")
    }

    /// An apply rewrites tfstate. The file is in the manifest, so membership alone would pass it.
    @Test("catches a sealed file that changed afterwards")
    func changed() throws {
        let sealed = ["terraform.tfstate": "before"]
        let files = ["terraform.tfstate": "after"]

        let status = try audit(files: files, manifest: manifest(sealed)).status(root: "/infra")
        #expect(!status.sealed)
        #expect(status.unsealed == ["terraform.tfstate"])
    }

    @Test("notes a torn-down stack as stale rather than unsealed")
    func removed() throws {
        let sealed = ["a.config.json": "one", "gone.config.json": "two"]
        let files = ["a.config.json": "one"]

        let status = try audit(files: files, manifest: manifest(sealed)).status(root: "/infra")
        #expect(status.unsealed.isEmpty)
        #expect(status.stale == ["gone.config.json"])
        #expect(status.summary == "backup is stale")
    }

    @Test("ignores files that are not secrets")
    func filtered() throws {
        let files = ["mwlab.tf": "resource {}", "versions.tf": "terraform {}"]
        let status = try audit(files: files, manifest: "").status(root: "/infra")
        #expect(status.sealed)
    }

    /// The computed fields were dropped on the wire once already, on `ConfigStatus`. The browser
    /// reads `sealed` and `summary`; if they are not encoded it sees every directory as fine.
    @Test("encodes the computed fields")
    func encodesComputed() throws {
        let status = SealStatus(
            root: "/infra", unsealed: ["a.config.json"], stale: [], sealedAt: nil)
        let json =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as! [String: Any]

        #expect(json["sealed"] as? Bool == false)
        #expect(json["summary"] as? String == "1 secret file not in the backup")
    }
}

@Suite("Sealing after a write")
struct StateSealerTests {
    @Test("runs the directory's own seal.sh")
    func runsScript() async {
        actor Calls {
            var argv: [[String]] = []
            var directories: [String?] = []
            func record(_ a: [String], _ d: String?) { argv.append(a); directories.append(d) }
        }
        let calls = Calls()
        let sealer = StateSealer(
            execute: { argv, directory in
                await calls.record(argv, directory)
                return CommandOutput(status: 0, standardOutput: "wrote secrets.tar.age", standardError: "")
            },
            exists: { $0 == "/infra/.age-recipient" || $0 == "/infra/seal.sh" }
        )

        let outcome = await sealer.seal(pathInside: "/infra/mwserver-tf")
        #expect(outcome == .sealed(root: "/infra", detail: "wrote secrets.tar.age"))
        #expect(!outcome.isProblem)
        await #expect(calls.argv == [["./seal.sh"]])
        // Run from the root, not the stack directory — seal.sh collects relative to itself.
        await #expect(calls.directories == ["/infra"])
    }

    /// A directory nobody chose to encrypt is not a problem to report on every write.
    @Test("stays quiet where nothing seals")
    func unsealedDirectory() async {
        let sealer = StateSealer(
            execute: { _, _ in
                Issue.record("must not run a command outside a sealed directory")
                return CommandOutput(status: 0, standardOutput: "", standardError: "")
            },
            exists: { _ in false }
        )
        let outcome = await sealer.seal(pathInside: "/tmp/scratch")
        #expect(outcome == .notSealed)
        #expect(!outcome.isProblem)
        #expect(outcome.message == nil)
    }

    /// Marked sealed but with no script: the secrets are gitignored and nothing backs them up.
    /// Silence here is the failure mode that started all this.
    @Test("complains when marked sealed with no script")
    func missingScript() async {
        let sealer = StateSealer(
            execute: { _, _ in CommandOutput(status: 0, standardOutput: "", standardError: "") },
            exists: { $0 == "/infra/.age-recipient" }
        )
        let outcome = await sealer.seal(pathInside: "/infra")
        #expect(outcome == .noScript(root: "/infra"))
        #expect(outcome.isProblem)
    }

    @Test("reports a failing seal rather than swallowing it")
    func failure() async {
        let sealer = StateSealer(
            execute: { _, _ in
                CommandOutput(status: 1, standardOutput: "", standardError: "age: no recipient")
            },
            exists: { _ in true }
        )
        let outcome = await sealer.seal(pathInside: "/infra")
        #expect(outcome == .failed(root: "/infra", detail: "age: no recipient"))
        #expect(outcome.isProblem)
        #expect(outcome.message?.contains("age: no recipient") == true)
    }

    /// age not installed, or seal.sh not executable. The throw must not escape into the command
    /// that was only writing a config file.
    @Test("reports a thrown error rather than propagating it")
    func thrown() async {
        struct Boom: Error {}
        let sealer = StateSealer(execute: { _, _ in throw Boom() }, exists: { _ in true })
        let outcome = await sealer.seal(pathInside: "/infra")
        #expect(outcome.isProblem)
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
    }
}

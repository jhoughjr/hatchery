import Foundation
import Testing

@testable import HatcheryKit

@Suite("Reading a service's own kind file")
struct KindFileTests {
    /// Rookery's `hatchery-kind.json`, copied verbatim: the first file hatchery reads.
    static let rookery = """
        {
          "kind": "rookery",
          "summary": "A control plane for a company of Claude sessions: seats, gates, and a board.",
          "image": "rookery",
          "port": 5000,
          "healthcheck": "/healthz",
          "notes": [
            "A rookery deployment is one office. Multi-tenancy is not built, so stand up one per org.",
            "Seats need a Claude login on whatever machine runs them. The control plane needs none.",
            "The runner is a second process type on the same image, scaled to zero until that machine is signed in."
          ],
          "storage": [
            {
              "mount": "/data",
              "why": "The whole home directory, because Claude Code keeps state in both $HOME/.claude/ and $HOME/.claude.json beside it. Mounting only the directory loses the file on every new container, and with it the OAuth state a login writes when it starts and checks when the code comes back."
            },
            {
              "mount": "/var/lib/rookery/work",
              "why": "Seats' workspaces, so a deploy does not lose a running seat."
            }
          ],
          "environment": {
            "ROOKERY_HOST": {
              "default": "127.0.0.1",
              "deployed": "0.0.0.0",
              "why": "The server refuses to bind anything but loopback without a token, so this and ROOKERY_TOKEN move together."
            },
            "ROOKERY_PORT": { "default": "8422", "deployed": "5000" },
            "ROOKERY_TOKEN": {
              "required": true,
              "secret": true,
              "why": "The machine door. Without it the server will not reach a network at all, which is deliberate: a control plane that starts agents on somebody's subscription is not a thing to leave open."
            },
            "ROOKERY_PUBLIC_URL": {
              "required": true,
              "example": "https://rookery.example.net",
              "why": "The address the served skill and the provisioning commands are written against. Not the loopback one a seat's hooks post to."
            },
            "ROOKERY_SELF_URL": {
              "default": "http://127.0.0.1:5000",
              "why": "Where a seat's hooks report. Loopback inside the container, so the token never leaves the host."
            },
            "ROOKERY_VAULT_ORG": {
              "example": "austin-macworks",
              "why": "The human door. Unset means no gate, which is right only on loopback. The gate fails closed when vault does not answer."
            },
            "ROOKERY_VAULT_BASE": { "default": "https://vault.jimmyhoughjr.net" },
            "ROOKERY_LEDGER": {
              "default": "<work root>/ledger.jsonl",
              "why": "Append-only, replayed at boot. Put it on the persistent mount or every restart forgets who ruled on what."
            },
            "ROOKERY_WORK_ROOT": { "default": "/var/lib/rookery/work" },
            "ROOKERY_CLAUDE_BIN": { "default": "/usr/local/bin/claude" },
            "ROOKERY_SEAT_MODEL": { "default": "claude-haiku-4-5" },
            "ROOKERY_MAX_SEATS": {
              "default": "4",
              "why": "A window governor rather than a safety limit. Twelve concurrent headless sessions measured clean on one credential store; the cost is that one working seat consumes about what one person consumes."
            },
            "ROOKERY_PERMISSION_MODE": {
              "default": "bypassPermissions",
              "why": "The only mode in which a headless seat can use a writing tool at all. It is stricter than it sounds: the office's PreToolUse hook becomes the whole permission system, and a hook denial still blocks under it."
            },
            "ROOKERY_GATED_TOOLS": { "default": "Write,Edit,Bash,NotebookEdit" },
            "ROOKERY_GATE_TIMEOUT": {
              "default": "300",
              "why": "How long a held call waits for a person before the gate answers deny. The seat is suspended and spending nothing while it waits."
            },
            "ROOKERY_ALLOW_API_KEY": {
              "default": "unset",
              "why": "Leave unset. A seat that resolves anything but a subscription refuses to start, which is the point."
            },
            "IS_SANDBOX": {
              "default": "1",
              "why": "The container runs as root, and Claude Code refuses the permission bypass as root without it."
            }
          },
          "runner": {
            "process": "runner",
            "scale": 0,
            "why": "Scaled to zero until the machine is signed in. A runner with no login would claim queued seats and fail every one, taking work a working runner would have taken.",
            "environment": {
              "ROOKERY_RUNNER_TOKEN": {
                "secret": true,
                "why": "A minted token scoped to one principal, not the office token. Mint it from the board or POST /runners/token."
              },
              "ROOKERY_PRINCIPAL": { "required": true, "why": "Whose plan this machine spends." },
              "ROOKERY_DEPARTMENT": { "why": "Narrows what it takes. Unset means all of this principal's work." },
              "ROOKERY_RUNNER_NAME": { "default": "the hostname" }
            }
          },
          "bootstrap": [
            "POST /org?name=<office>",
            "POST /org/people?handle=<handle>&logins=<github login>",
            "POST /teams?name=<team>&department=<department>&people=<handles>",
            "Sign the runner's machine in: run the claude binary there and complete /login."
          ]
        }
        """

    /// Writes `contents` to a fresh temp file and returns its path, with a cleanup closure.
    private func fixture(_ contents: String, name: String = "hatchery-kind.json") throws -> (path: String, cleanup: () -> Void) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hatchery-kindfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name)
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return (path.path, { try? FileManager.default.removeItem(at: directory) })
    }

    @Test("rookery's file decodes: notes as a list, storage, and every environment entry")
    func decodesRookery() throws {
        let written = try fixture(Self.rookery)
        defer { written.cleanup() }

        let file = try KindFile.load(atPath: written.path)
        #expect(file.kind == "rookery")
        #expect(file.port == 5000)
        #expect(file.healthcheck == "/healthz")
        #expect(file.notes?.count == 3)
        #expect(file.storage?.map(\.mount) == ["/data", "/var/lib/rookery/work"])
        #expect(file.environment.count == 17)
        #expect(file.environment["ROOKERY_TOKEN"]?.required == true)
        #expect(file.environment["ROOKERY_TOKEN"]?.secret == true)
        #expect(file.environment["ROOKERY_HOST"]?.default == "127.0.0.1")
        #expect(file.environment["ROOKERY_HOST"]?.deployed == "0.0.0.0")
        #expect(file.bootstrap?.count == 4)
        // The runner section is opaque JSON, kept rather than dropped.
        if case .string(let process) = file.runner?["process"] {
            #expect(process == "runner")
        } else {
            Issue.record("runner.process did not decode as a string")
        }
    }

    @Test("notes decodes a bare string the same as a one-element list")
    func notesAcceptsAString() throws {
        let written = try fixture(
            #"{"kind": "coop", "environment": {}, "notes": "written by roost"}"#)
        defer { written.cleanup() }

        let file = try KindFile.load(atPath: written.path)
        #expect(file.notes == ["written by roost"])
    }

    @Test("the contract takes required and secret from the file, and everything else is optional")
    func buildsContract() throws {
        let written = try fixture(Self.rookery)
        defer { written.cleanup() }

        let file = try KindFile.load(atPath: written.path)
        let contract = file.contract(backend: .dokku)

        #expect(contract.required == ["ROOKERY_TOKEN", "ROOKERY_PUBLIC_URL"])
        #expect(contract.secret == ["ROOKERY_TOKEN"])
        #expect(contract.optional.count == 15)
        #expect(!contract.optional.contains("ROOKERY_TOKEN"))
        #expect(!contract.optional.contains("ROOKERY_PUBLIC_URL"))
        #expect(contract.retired.isEmpty)
        #expect(contract.ignored.isEmpty)
    }

    @Test("a kind that is not lower-case letters, digits, and hyphens is refused")
    func refusesABadKind() throws {
        let written = try fixture(#"{"kind": "Not Usable!", "environment": {}}"#)
        defer { written.cleanup() }

        #expect(throws: KindFileError.invalidKind(file: written.path, kind: "Not Usable!")) {
            try KindFile.load(atPath: written.path)
        }
    }
}

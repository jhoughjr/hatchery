import Foundation
import Testing

@testable import HatcheryKit

/// A value with every character a shell, JSON, XML or systemd reads as special, so a script that quotes it wrong fails here.
private let secret = #"s3cr3t-VALUE/x&y<z>%w"q'v\u"#

/// Every holder type, on a remote host where the type allows one.
private let holders: [KindFile.Holder] = [
    .dokkuConfig(app: "rookery", key: "TOKEN", restart: .rolling),
    .dokkuConfig(app: "forgejo", key: "TOKEN", restart: .stopStart),
    .roostrc(host: "jimmy@mini", key: "TOKEN"),
    .launchdEnvironment(host: "jimmy@mini", label: "net.jimmyhoughjr.serve", key: "TOKEN"),
    .systemdEnvironment(host: "jimmy@opi", unit: "roost-node.service", key: "TOKEN"),
    .file(host: "jimmy@opi", path: "~/.config/gigs/draft.token"),
    .file(host: "local", path: "~/.roost_node_key"),
]

private func plan(_ holders: [KindFile.Holder]) -> RotationPlan {
    RotationPlan(service: "rookery", keys: ["TOKEN"], rotation: KindFile.Rotation(issuer: .random(bytes: 32), holders: holders))
}

private func writes(_ holder: KindFile.Holder) throws -> [ShellCommand] {
    try RotationExecutor.writeCommands(
        holder,
        plan: plan([holder]),
        values: ["TOKEN": secret],
        dokkuTargets: ["rookery": "dokku@opi", "forgejo": "dokku@opi"])
}

/// A scratch directory with a `bin` of fake tools and a `tmp` the scripts' `mktemp` uses, removed by the caller.
private struct Scratch {
    let root: URL
    var bin: URL { self.root.appendingPathComponent("bin") }
    var tmp: URL { self.root.appendingPathComponent("tmp") }
    var home: URL { self.root.appendingPathComponent("home") }

    init() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("rotation-input-\(UUID().uuidString)")
        for directory in [self.bin, self.tmp, self.home] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func tool(_ name: String, _ body: String) throws {
        let url = self.bin.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The command as it runs here, with this scratch's home, tools and temp directory in its environment.
    func local(_ command: ShellCommand) -> ShellCommand {
        ShellCommand(
            ["env", "HOME=\(self.home.path)", "TMPDIR=\(self.tmp.path)", "PATH=\(self.bin.path):/usr/bin:/bin"] + command.argv,
            standardInput: command.standardInput)
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOf: self.home.appendingPathComponent(relative), encoding: .utf8)
    }

    func mode(_ relative: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: self.home.appendingPathComponent(relative).path)[.posixPermissions] as? Int) ?? -1
    }

    func tmpIsEmpty() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: self.tmp.path).isEmpty
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

@Suite("A rotation's value travels on standard input and never in an argument")
struct RotationValueInputTests {
    @Test("no holder type puts the value in any argument, and every one puts it on standard input")
    func noHolderPutsTheValueInAnArgument() throws {
        for holder in holders {
            let commands = try writes(holder)

            #expect(commands.count == 1, "\(holder)")
            for command in commands {
                #expect(!command.argv.contains { $0.contains(secret) }, "\(holder)")
                #expect(!command.argv.contains { $0.contains("s3cr3t") }, "\(holder)")
                #expect(command.standardInput != nil, "\(holder)")
                #expect(!command.description.contains("s3cr3t"), "\(holder)")
            }
        }
    }

    @Test("a dokku holder imports a JSON map from standard input, which decodes to the value exactly")
    func dokkuImportsJSONFromStandardInput() throws {
        let rolling = try writes(.dokkuConfig(app: "rookery", key: "TOKEN", restart: .rolling))[0]
        let stopStart = try writes(.dokkuConfig(app: "forgejo", key: "TOKEN", restart: .stopStart))[0]

        #expect(rolling.argv == ["ssh", "-o", "BatchMode=yes", "dokku@opi", "--quiet", "config:import", "--format=json", "rookery", "-"])
        #expect(
            stopStart.argv == ["ssh", "-o", "BatchMode=yes", "dokku@opi", "--quiet", "config:import", "--format=json", "--no-restart", "forgejo", "-"])
        let decoded = try JSONDecoder().decode([String: String].self, from: try #require(rolling.standardInput))
        #expect(decoded == ["TOKEN": secret])
    }

    @Test("ALTER ROLE carries the password on standard input, and the argv holds none")
    func alterRoleCarriesThePasswordOnStandardInput() {
        let command = RotationExecutor.alterRoleCommand(server: "rookery-pg", role: "rookery", password: "s3cr3t", on: "jimmy@opi")

        #expect(!command.argv.contains { $0.contains("s3cr3t") })
        #expect(String(decoding: command.standardInput ?? Data(), as: UTF8.self).contains("PASSWORD 's3cr3t'"))
    }

    @Test("a holder's error that echoes the value reaches the report with the value withheld")
    func anEchoedValueIsWithheldFromTheReport() async throws {
        let executor = RotationExecutor(
            vault: VaultAdmin(credential: .session("")),
            secrets: SecretsFile(read: { [:] }, write: { _ in }),
            dokkuTargets: ["rookery": "dokku@opi"],
            run: { command in
                let echoed = String(decoding: command.standardInput ?? Data(), as: UTF8.self)
                throw CommandFailure(command: "ssh", status: 1, message: "invalid input: \(echoed)")
            },
            mint: { _ in secret })

        let report = await executor.execute(plan([.dokkuConfig(app: "rookery", key: "TOKEN", restart: .rolling)]))

        #expect(!report.succeeded)
        #expect(report.reason?.contains("<value withheld>") == true)
        #expect(!report.lines().joined().contains("s3cr3t"))
    }

    // MARK: - The scripts, run on this machine

    @Test("the roostrc script replaces the key from standard input, keeps every other line, and leaves no temp file")
    func roostrcScriptSetsFromStandardInput() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try Data("OTHER=1\nTOKEN=old\nLAST=2\n".utf8).write(to: scratch.home.appendingPathComponent(".roostrc"))

        let command = RotationExecutor.onHost("local", script: RotationExecutor.roostrcScript(key: "TOKEN"), value: secret)
        _ = try await ShellRunner.withInput(scratch.local(command))

        #expect(try scratch.read(".roostrc") == "OTHER=1\nLAST=2\nTOKEN=\(secret)\n")
        #expect(try scratch.mode(".roostrc") == 0o600)
        #expect(try scratch.tmpIsEmpty())
    }

    @Test("the file script writes the value whole, mode 600, into a directory it makes")
    func fileScriptSetsFromStandardInput() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }

        let command = RotationExecutor.onHost("local", script: RotationExecutor.fileScript(path: "~/.config/gigs/draft.token"), value: secret)
        _ = try await ShellRunner.withInput(scratch.local(command))

        #expect(try scratch.read(".config/gigs/draft.token") == secret)
        #expect(try scratch.mode(".config/gigs/draft.token") == 0o600)
        #expect(try scratch.tmpIsEmpty())
    }

    @Test("the systemd script writes an escaped drop-in from standard input and reloads")
    func systemdScriptSetsFromStandardInput() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.tool("systemctl", "echo \"$@\" > \"$HOME/systemctl.called\"")

        let script = RotationExecutor.dropInScript(unit: "roost-node.service", key: "TOKEN")
        _ = try await ShellRunner.withInput(scratch.local(RotationExecutor.onHost("local", script: script, value: secret)))

        #expect(
            try scratch.read(".config/systemd/user/roost-node.service.d/rotation.conf")
                == #"[Service]"# + "\n" + #"Environment="TOKEN=s3cr3t-VALUE/x&y<z>%%w\"q'v\\u""# + "\n")
        #expect(try scratch.read("systemctl.called") == "--user daemon-reload\n")
        #expect(try scratch.tmpIsEmpty())
    }

    #if os(macOS)
    @Test("the launchd script sets the plist key from standard input, whether the key was there or not")
    func launchdScriptSetsFromStandardInput() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let agents = scratch.home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("net.jimmyhoughjr.serve.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "net.jimmyhoughjr.serve"], format: .xml, options: 0).write(to: plist)
        let script = RotationExecutor.plistScript(label: "net.jimmyhoughjr.serve", key: "TOKEN")

        // Given no EnvironmentVariables, then a key that is already there.
        for value in ["first", secret] {
            _ = try await ShellRunner.withInput(scratch.local(RotationExecutor.onHost("local", script: script, value: value)))

            let read = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            #expect((read?["EnvironmentVariables"] as? [String: String])?["TOKEN"] == value)
            #expect(read?["Label"] as? String == "net.jimmyhoughjr.serve")
        }
        #expect(try scratch.tmpIsEmpty())
    }
    #endif

    @Test("an empty standard input stops the script before it touches the holder")
    func emptyInputTouchesNothing() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try Data("TOKEN=old\n".utf8).write(to: scratch.home.appendingPathComponent(".roostrc"))

        let command = RotationExecutor.onHost("local", script: RotationExecutor.roostrcScript(key: "TOKEN"), value: "")
        await #expect(throws: CommandFailure.self) {
            _ = try await ShellRunner.withInput(scratch.local(command))
        }

        #expect(try scratch.read(".roostrc") == "TOKEN=old\n")
        #expect(try scratch.tmpIsEmpty())
    }

    // MARK: - The whole run, with ps watching

    @Test("a local rotation through a fake box sets every holder, and ps never shows the value while it runs")
    func psNeverShowsTheValue() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let value = "proof-\(UUID().uuidString)"
        // The fake ssh plays sshd: dokku's forced command for dokku@box, and the login shell running the joined words for any other target.
        // The import waits until the watcher below has seen it in ps, for up to ten seconds, so a fast or busy runner cannot slip past the sample.
        try scratch.tool(
            "ssh",
            """
            while [ "$1" = "-o" ]; do shift 2; done
            target="$1"; shift
            if [ "$target" = "dokku@box" ]; then
              [ "$1 $2 $3" = "--quiet config:import --format=json" ] || { echo "not an import: $*" >&2; exit 1; }
              shift 3
              [ "$1" = "--no-restart" ] && shift
              cat > "$HOME/dokku-$1.json"
              i=0; while [ ! -f "$HOME/import-seen" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
            else
              sh -c "$*"; rc=$?; sleep 1; exit $rc
            fi
            """)
        let rotation = plan([
            .dokkuConfig(app: "ps-proof", key: "TOKEN", restart: .rolling),
            .roostrc(host: "jimmy@box", key: "TOKEN"),
            .file(host: "jimmy@box", path: "~/.proof.token"),
        ])
        let seen = Seen()
        let executor = RotationExecutor(
            vault: VaultAdmin(credential: .session("")),
            secrets: SecretsFile(read: { [:] }, write: { _ in }),
            dokkuTargets: ["ps-proof": "dokku@box"],
            run: { command in
                seen.add(command.argv)
                return try await ShellRunner.withInput(scratch.local(command))
            },
            mint: { _ in value })

        // When the run goes, a watcher reads every process's arguments every 50 ms, and marks the import once it has seen it.
        let importSeen = scratch.home.appendingPathComponent("import-seen")
        let watcher = Task { () -> [String] in
            var lines: [String] = []
            while !Task.isCancelled {
                if let snapshot = try? await ShellRunner.withInput(ShellCommand(["ps", "-A", "-o", "args="])) {
                    let sample = String(decoding: snapshot, as: UTF8.self).split(separator: "\n").map(String.init)
                    lines += sample
                    if sample.contains(where: { $0.contains("config:import") }) {
                        FileManager.default.createFile(atPath: importSeen.path, contents: nil)
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return lines
        }
        let report = await executor.execute(rotation)
        watcher.cancel()
        let snapshots = await watcher.value

        // Then every holder has the value, and no argument anywhere held it.
        #expect(report.succeeded, "\(report.lines())")
        let imported = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: scratch.home.appendingPathComponent("dokku-ps-proof.json")))
        #expect(imported == ["TOKEN": value])
        #expect(try scratch.read(".roostrc") == "TOKEN=\(value)\n")
        #expect(try scratch.read(".proof.token") == value)
        #expect(!seen.all.joined().contains(value))
        #expect(snapshots.contains { $0.contains("config:import") }, "the watcher never saw the import, so it proves nothing")
        #expect(!snapshots.contains { $0.contains(value) })
        #expect(try scratch.tmpIsEmpty())
    }
}

/// Every argv a runner was handed, safe to read after the run.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var argvs: [[String]] = []
    func add(_ argv: [String]) { self.lock.withLock { self.argvs.append(argv) } }
    var all: [String] { self.lock.withLock { self.argvs.flatMap { $0 } } }
}

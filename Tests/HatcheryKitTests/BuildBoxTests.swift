import Foundation
import Testing

@testable import HatcheryKit

/// A build box's forge runner, read off the box into its declaration.
@Suite("Reading a build box's runner")
struct BuildBoxTests {
    /// The mini's `runner:` block as `sed` prints it on 2026-09-25, comments and all.
    private let miniBlock = """
        runner:
          file: .runner
          capacity: 1
          timeout: 3h
          # Host mode, so a job runs as this user with this PATH.
          labels:
            - "self-hosted:host"
            - "macos:host"
            # A capability label, not a place.
            - "rosetta:host"

        cache:
        """

    private func opiRunner() -> ServiceSpec {
        ServiceSpec(
            name: "act_runner", kind: ServiceKind(rawValue: "act-runner"), image: "code.forgejo.org/forgejo/runner:9",
            configFile: "act_runner.config.json",
            container: ContainerSpec(
                image: "code.forgejo.org/forgejo/runner:9",
                command: ["forgejo-runner", "daemon", "--config", "/data/config.yaml"]))
    }

    private func miniRunner() -> ServiceSpec {
        ServiceSpec(
            name: "forgejo-runner", kind: .job, image: "", configFile: "forgejo-runner.config.json",
            job: JobSpec(
                program: [
                    "/Users/jimmyhoughjr/forgejo-runner/forgejo-runner",
                    "daemon",
                    "--config",
                    "/Users/jimmyhoughjr/forgejo-runner/config.yaml",
                ],
                workingDirectory: "/Users/jimmyhoughjr/forgejo-runner"))
    }

    @Test("the runner block reads its capacity and labels, and a comment between labels does not end the list")
    func parsesTheBlock() {
        let parsed = BuildBox.parse(block: self.miniBlock)
        #expect(parsed.capacity == 1)
        #expect(parsed.file == ".runner")
        #expect(parsed.labels == ["self-hosted:host", "macos:host", "rosetta:host"])
    }

    @Test("the mode follows the labels, and the names are what runs-on asks for")
    func modeAndNames() {
        let host = RunnerSpec(registration: "mini-forge", labels: ["macos:host", "arm64:host"], capacity: 1, config: "c")
        let image = RunnerSpec(
            registration: "opi-forge", labels: ["linux:docker://roost-ci:arm64"], capacity: 2, config: "c")
        let both = RunnerSpec(
            registration: "x", labels: ["macos:host", "linux:docker://roost-ci:arm64"], capacity: 1, config: "c")
        #expect(host.mode == "host")
        #expect(image.mode == "container")
        #expect(both.mode == "mixed")
        #expect(host.names == ["macos", "arm64"])
    }

    @Test("a service that runs no runner daemon is not a build box")
    func notARunner() async {
        let web = ServiceSpec(
            name: "coop", kind: .container, image: "coop", configFile: "coop.config.json",
            container: ContainerSpec(image: "coop", command: ["node", "server.js"]))
        let stack = StackSpec(name: "box", backend: .host, host: "jimmy@192.168.0.103")
        await #expect(throws: BuildBox.Trouble.notARunner(service: "coop")) {
            try await BuildBox.read(web, in: stack) { _ in Data() }
        }
    }

    @Test("a container's runner is read inside the container, and only the runner block and the name are asked for")
    func readsInsideTheContainer() async throws {
        let asked = Asked()
        let stack = StackSpec(name: "box", backend: .host, host: "jimmy@192.168.0.103")
        let read = try await BuildBox.read(self.opiRunner(), in: stack) { argv in
            await asked.add(argv.last ?? "")
            let command = argv.last ?? ""
            if command.contains("/^runner:/") {
                return Data("runner:\n  capacity: 2\n  labels:\n    - \"linux:docker://roost-ci:arm64\"\n".utf8)
            }
            return Data("opi-forge\n".utf8)
        }

        #expect(read == RunnerSpec(
            registration: "opi-forge", labels: ["linux:docker://roost-ci:arm64"], capacity: 2,
            config: "/data/config.yaml"))
        let commands = await asked.all
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.hasPrefix("docker exec 'act_runner' sed -n ") })
        // The token line is never asked for: only the name comes back.
        #expect(commands[1].contains(#""name""#))
        #expect(commands[1].hasSuffix("'/data/.runner'"))
    }

    @Test("a job's runner is read on the host, and its .runner file sits in the job's working directory")
    func readsOnTheHost() async throws {
        let asked = Asked()
        let stack = StackSpec(
            name: "mini", backend: .host, host: "jimmyhoughjr@jimmys-mac-mini.local", settings: ["platform": "darwin"])
        let read = try await BuildBox.read(self.miniRunner(), in: stack) { argv in
            await asked.add(argv.last ?? "")
            return (argv.last ?? "").contains("/^runner:/") ? Data(self.miniBlock.utf8) : Data("mini-forge\n".utf8)
        }

        #expect(read.registration == "mini-forge")
        #expect(read.names == ["self-hosted", "macos", "rosetta"])
        let commands = await asked.all
        #expect(commands.allSatisfy { $0.hasPrefix("sed -n ") })
        #expect(commands[1].hasSuffix("'/Users/jimmyhoughjr/forgejo-runner/.runner'"))
    }

    @Test("the runner block is written into the manifest and published, and a service without one gains no field")
    func declaredAndPublished() throws {
        let runner = RunnerSpec(
            registration: "mini-forge", labels: ["macos:host", "rosetta:host"], capacity: 1, config: "/c.yaml")
        let manifest = StackManifest(stacks: [
            StackSpec(name: "mini", backend: .host, host: "m", services: [self.miniRunner()]),
        ]).settingRunner(stack: "mini", service: "forgejo-runner", to: runner)

        #expect(manifest.stack(named: "mini")?.services.first?.runner == runner)
        let published = Declaration.Runner(runner)
        #expect(published.labels == ["macos", "rosetta"])
        #expect(published.mode == "host")

        let plain = try JSONEncoder().encode(self.opiRunner())
        #expect(String(decoding: plain, as: UTF8.self).contains("\"runner\"") == false)
    }

    @Test("a bare name takes the target the labels share, a removal goes by name, and nothing else moves")
    func relabels() throws {
        let host = ["self-hosted:host", "macos:host", "rosetta:host"]
        #expect(try BuildBox.relabel(host, adding: ["big"], removing: ["rosetta"]) == ["self-hosted:host", "macos:host", "big:host"])
        #expect(try BuildBox.relabel(host, adding: ["macos"], removing: []) == host)
        let image = ["linux:docker://roost-ci:arm64", "arm64:docker://roost-ci:arm64"]
        #expect(try BuildBox.relabel(image, adding: ["swift"], removing: []).last == "swift:docker://roost-ci:arm64")
    }

    @Test("a label that could break the config, a mixed runner's bare name, and an empty runner are refused")
    func refusesBadLabels() {
        #expect(throws: BuildBox.Trouble.self) { try BuildBox.relabel(["a:host"], adding: ["b'; echo"], removing: []) }
        #expect(throws: BuildBox.Trouble.self) {
            try BuildBox.relabel(["a:host", "b:docker://img"], adding: ["c"], removing: [])
        }
        #expect(throws: BuildBox.Trouble.self) { try BuildBox.relabel(["a:host"], adding: [], removing: ["a"]) }
    }

    @Test("a container runner restarts through docker, and a Mac job through launchd under its own label")
    func restarts() {
        #expect(BuildBox.restartCommand(for: self.opiRunner(), platform: .linux) == "docker restart 'act_runner'")
        #expect(BuildBox.restartCommand(for: self.miniRunner(), platform: .darwin)
            == "launchctl kickstart -k gui/$(id -u)/net.jimmyhoughjr.forgejo-runner")
    }

    @Test("the rewrite carries its program and its labels as base64, so no label is read by the shell")
    func rewriteIsEncoded() throws {
        let command = try BuildBox.rewriteCommand(for: self.opiRunner(), config: "/data/config.yaml", labels: ["x:host"])
        #expect(command.hasPrefix("echo "))
        #expect(command.contains("python3 /tmp/hatchery-relabel.py docker 'act_runner' '/data/config.yaml' "))
        #expect(command.contains("x:host") == false)
        // `status` is read only in zsh, a Mac's login shell, and assigning it failed the command after the rewrite.
        #expect(command.contains("status=") == false)
        #expect(command.hasSuffix("rc=$?; rm -f /tmp/hatchery-relabel.py; exit $rc"))
    }

    @Test("the forge's runner list reads as a list, and a live registration wins over its offline twin")
    func forgeRunners() {
        let data = Data("""
            [{"id":1,"name":"opi-forge","status":"offline","labels":["linux"]},
             {"id":2,"name":"opi-forge","status":"idle","labels":["linux","big"]}]
            """.utf8)
        let runners = ForgeRunners.parse(data)
        #expect(runners.count == 2)
        #expect(ForgeRunners.current("opi-forge", in: runners)?.id == 2)
        #expect(ForgeRunners.current("mini-forge", in: runners) == nil)
    }
}

/// The commands a fake box was asked to run, in order.
private actor Asked {
    private(set) var all: [String] = []
    func add(_ command: String) { self.all.append(command) }
}

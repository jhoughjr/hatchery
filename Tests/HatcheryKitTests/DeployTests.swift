import Foundation
import Testing

@testable import HatcheryKit

private let variablesFixture = """
    variable "dokku_host" {
      description = "Dokku host to manage."
      type        = string
      default     = "192.168.0.103"
    }

    variable "mwlab_image" {
      # Built on opi (arm64) from an MWServer rev; bump the tag here and apply to deploy.
      description = "Docker image mwlab deploys from."
      type        = string
      default     = "mhehmsoth/mwserver2:arm64-0630f31-health"
    }

    variable "enable_paylab" {
      description = "Create and deploy the PaymentGateway lab app."
      type        = bool
      default     = true
    }
    """

private func labStack(image: String = "mhehmsoth/mwserver2:arm64-0630f31-health") -> StackSpec {
    StackSpec(
        name: "mwlab",
        backend: .dokku,
        host: "dokku@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/mwserver-tf"),
        services: [
            ServiceSpec(
                name: "mwlab",
                kind: .mwserver,
                image: image,
                domains: ["mwlab.opi"],
                configFile: "mwlab.config.json",
                imageVariable: "mwlab_image"
            )
        ]
    )
}

/// A filesystem and a command log that live in memory.
///
/// This is a lock rather than an actor because ``Deployer`` takes synchronous file closures,
/// matching Foundation's file APIs. Nothing here opens a file or spawns a process.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    private var log: [(argv: [String], directory: String?)] = []

    init(files: [String: String]) {
        self.files = files
    }

    var commands: [(argv: [String], directory: String?)] {
        lock.withLock { log }
    }

    func read(_ path: String) throws -> String {
        guard let contents = lock.withLock({ files[path] }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return contents
    }

    func write(_ path: String, _ contents: String) {
        lock.withLock { files[path] = contents }
    }

    func record(_ argv: [String], _ directory: String?) {
        lock.withLock { log.append((argv, directory)) }
    }
}

private func makeDeployer(
    _ recorder: Recorder,
    plan: @escaping @Sendable () -> CommandOutput,
    apply: @escaping @Sendable () -> CommandOutput = { CommandOutput(status: 0, standardOutput: "Apply complete!") }
) -> Deployer {
    Deployer(
        execute: { argv, directory in
            recorder.record(argv, directory)
            return argv.contains("apply") ? apply() : plan()
        },
        readFile: { try recorder.read($0) },
        writeFile: { recorder.write($0, $1) }
    )
}

@Suite("Tofu variables file")
struct TofuVariableFileTests {
    @Test("reads the default a variable declares")
    func readsDefault() {
        let file = TofuVariableFile(path: "variables.tf", contents: variablesFixture)
        #expect(file.defaultValue(of: "mwlab_image") == "mhehmsoth/mwserver2:arm64-0630f31-health")
        #expect(file.defaultValue(of: "dokku_host") == "192.168.0.103")
    }

    @Test("an absent variable reads as nil rather than the next one's default")
    func absentVariable() {
        let file = TofuVariableFile(path: "variables.tf", contents: variablesFixture)
        #expect(file.defaultValue(of: "comlab_image") == nil)
    }

    @Test("replacing a default leaves every other byte alone")
    func surgicalEdit() throws {
        let file = TofuVariableFile(path: "variables.tf", contents: variablesFixture)
        let updated = try file.settingDefault(of: "mwlab_image", to: "mwserver2:arm64-abc1234")

        #expect(updated.defaultValue(of: "mwlab_image") == "mwserver2:arm64-abc1234")
        #expect(updated.defaultValue(of: "dokku_host") == "192.168.0.103")
        // The comment above the variable is the most useful thing in the file.
        #expect(updated.contents.contains("# Built on opi (arm64) from an MWServer rev"))
        #expect(updated.contents.contains("variable \"enable_paylab\""))

        let before = variablesFixture.components(separatedBy: "\n")
        let after = updated.contents.components(separatedBy: "\n")
        #expect(before.count == after.count)
        #expect(zip(before, after).filter { $0 != $1 }.count == 1)
    }

    @Test("an unknown variable is an error, not a silent no-op")
    func unknownVariable() {
        let file = TofuVariableFile(path: "variables.tf", contents: variablesFixture)
        #expect(throws: TofuVariableError.variableNotFound("nope_image", file: "variables.tf")) {
            _ = try file.settingDefault(of: "nope_image", to: "x")
        }
    }

    @Test("a variable with no default is an error, not a fallthrough to the next block")
    func noDefault() {
        let contents = """
            variable "bare" {
              type = string
            }

            variable "other" {
              default = "wrong"
            }
            """
        let file = TofuVariableFile(path: "variables.tf", contents: contents)
        #expect(file.defaultValue(of: "bare") == nil)
        #expect(throws: TofuVariableError.noDefault(variable: "bare", file: "variables.tf")) {
            _ = try file.settingDefault(of: "bare", to: "x")
        }
    }

    @Test("a non-scalar default is left alone rather than corrupted")
    func listDefault() {
        let contents = """
            variable "domains" {
              type    = list(string)
              default = ["a.opi", "b.opi"]
            }
            """
        let file = TofuVariableFile(path: "variables.tf", contents: contents)
        #expect(file.defaultValue(of: "domains") == nil)
    }
}

@Suite("Deploy planning")
struct DeployPlanTests {
    @Test("a bare deploy targets the image the manifest declares")
    func targetsManifestImage() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 0, standardOutput: "No changes.") })
        let stack = labStack(image: "mwserver2:arm64-newrev")

        let plan = try deployer.plan(service: "mwlab", in: stack)
        #expect(plan.target == "mwserver2:arm64-newrev")
        #expect(plan.current == "mhehmsoth/mwserver2:arm64-0630f31-health")
        #expect(plan.needsWrite)
        #expect(!plan.updatesManifest)
    }

    @Test("an explicit image wins over the manifest and moves both")
    func explicitImage() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 2, standardOutput: "1 to change") })

        let plan = try deployer.plan(service: "mwlab", in: labStack(), image: "mwserver2:arm64-abc")
        #expect(plan.target == "mwserver2:arm64-abc")
        #expect(plan.needsWrite)
        #expect(plan.updatesManifest)
        #expect(!plan.wasDrifted)
    }

    @Test("a manifest that already disagrees with the variable reports drift")
    func reportsDrift() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 0, standardOutput: "") })

        let plan = try deployer.plan(service: "mwlab", in: labStack(image: "mwserver2:arm64-somethingelse"))
        #expect(plan.wasDrifted)
    }

    @Test("a service with no image variable cannot be deployed")
    func noImageVariable() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 0, standardOutput: "") })
        var stack = labStack()
        stack.services[0].imageVariable = nil

        #expect(throws: DeployError.noImageVariable(service: "mwlab")) {
            _ = try deployer.plan(service: "mwlab", in: stack)
        }
    }

    @Test("a stack with no tofu binding cannot be deployed")
    func noBinding() async throws {
        let recorder = Recorder(files: [:])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 0, standardOutput: "") })
        var stack = labStack()
        stack.tofu = nil

        #expect(throws: DeployError.noTofuBinding(stack: "mwlab")) {
            _ = try deployer.plan(service: "mwlab", in: stack)
        }
    }

    @Test("an unknown service names the stack it is missing from")
    func unknownService() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 0, standardOutput: "") })

        #expect(throws: DeployError.unknownService(stack: "mwlab", service: "paylab")) {
            _ = try deployer.plan(service: "paylab", in: labStack())
        }
    }
}

@Suite("Plan outcomes")
struct PlanOutcomeTests {
    @Test("detailed-exitcode 0 is clean, 2 is changes, anything else is a failure")
    func verdicts() {
        #expect(PlanOutcome.from(CommandOutput(status: 0, standardOutput: "No changes.")).verdict == .clean)
        #expect(PlanOutcome.from(CommandOutput(status: 2, standardOutput: "1 to change")).verdict == .changes)
        #expect(PlanOutcome.from(CommandOutput(status: 1, standardOutput: "")).verdict == .failed)
    }

    @Test("the plan is run in the stack's tofu directory")
    func runsInDirectory() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 2, standardOutput: "1 to change") })

        _ = try await deployer.tofuPlan(in: labStack())
        let commands = recorder.commands
        #expect(commands.count == 1)
        #expect(commands[0].directory == "/infra/mwserver-tf")
        #expect(commands[0].argv == ["tofu", "plan", "-detailed-exitcode", "-no-color", "-input=false"])
    }
}

@Suite("Deploy")
struct DeployTests {
    @Test("a deploy writes the variable and plans")
    func writesAndPlans() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 2, standardOutput: "1 to change") })

        let result = try await deployer.deploy(service: "mwlab", in: labStack(), image: "mwserver2:arm64-abc")
        #expect(result.outcome.verdict == .changes)
        #expect(!result.reverted)
        #expect(result.applied == nil)

        let written = try recorder.read("/infra/mwserver-tf/variables.tf")
        #expect(TofuVariableFile(path: "x", contents: written).defaultValue(of: "mwlab_image") == "mwserver2:arm64-abc")
    }

    @Test("a plan that stops evaluating puts the file back")
    func revertsOnFailure() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(
            recorder, plan: { CommandOutput(status: 1, standardOutput: "", standardError: "Error: invalid reference") })

        let result = try await deployer.deploy(service: "mwlab", in: labStack(), image: "mwserver2:arm64-abc")
        #expect(result.reverted)
        #expect(result.outcome.verdict == .failed)
        #expect(result.applied == nil)

        let written = try recorder.read("/infra/mwserver-tf/variables.tf")
        #expect(written == variablesFixture)
    }

    @Test("nothing is applied unless it is asked for")
    func doesNotApplyByDefault() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 2, standardOutput: "1 to change") })

        _ = try await deployer.deploy(service: "mwlab", in: labStack(), image: "mwserver2:arm64-abc")
        let commands = recorder.commands
        #expect(commands.allSatisfy { !$0.argv.contains("apply") })
    }

    @Test("applying runs tofu apply and returns what it said")
    func applies() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 2, standardOutput: "1 to change") })

        let result = try await deployer.deploy(
            service: "mwlab", in: labStack(), image: "mwserver2:arm64-abc", apply: true)
        #expect(result.applied == "Apply complete!")

        let commands = recorder.commands
        #expect(commands.contains { $0.argv == ["tofu", "apply", "-auto-approve", "-no-color", "-input=false"] })
    }

    @Test("a failed apply is an error rather than a quiet success")
    func failedApply() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(
            recorder,
            plan: { CommandOutput(status: 2, standardOutput: "1 to change") },
            apply: { CommandOutput(status: 1, standardOutput: "", standardError: "Error: image not found") }
        )

        await #expect(throws: DeployError.applyFailed(message: "Error: image not found")) {
            _ = try await deployer.deploy(
                service: "mwlab", in: labStack(), image: "mwserver2:arm64-abc", apply: true)
        }
    }

    @Test("a no-op deploy still plans, because the box can lag the variable")
    func noOpStillPlans() async throws {
        let recorder = Recorder(files: ["/infra/mwserver-tf/variables.tf": variablesFixture])
        let deployer = makeDeployer(recorder, plan: { CommandOutput(status: 2, standardOutput: "1 to change") })

        let result = try await deployer.deploy(service: "mwlab", in: labStack())
        #expect(!result.plan.needsWrite)
        #expect(result.outcome.verdict == .changes)

        let commands = recorder.commands
        #expect(commands.count == 1)
    }
}

@Suite("Manifest image updates")
struct ManifestImageTests {
    @Test("setting an image changes only the named service")
    func setsOneService() {
        let manifest = StackManifest(stacks: [
            StackSpec(
                name: "mwlab", backend: .dokku, host: "dokku@h",
                services: [
                    ServiceSpec(name: "mwlab", kind: .mwserver, image: "old", configFile: "a.json"),
                    ServiceSpec(name: "paylab", kind: .paymentGateway, image: "pay", configFile: "b.json"),
                ]
            )
        ])

        let updated = manifest.settingImage(stack: "mwlab", service: "mwlab", to: "new")
        #expect(updated.stack(named: "mwlab")?.service(named: "mwlab")?.image == "new")
        #expect(updated.stack(named: "mwlab")?.service(named: "paylab")?.image == "pay")
    }

    @Test("a tofu binding survives a manifest round trip")
    func roundTripsBinding() throws {
        let manifest = StackManifest(stacks: [labStack()])
        let decoded = try StackManifest.decode(from: try manifest.encoded())
        #expect(decoded.stack(named: "mwlab")?.tofu?.directory == "/infra/mwserver-tf")
        #expect(decoded.stack(named: "mwlab")?.tofu?.resolvedVariablesFile == "variables.tf")
        #expect(decoded.stack(named: "mwlab")?.service(named: "mwlab")?.imageVariable == "mwlab_image")
    }

    @Test("a manifest written before these fields still reads")
    func decodesWithoutBinding() throws {
        let json = """
            {"version":1,"stacks":[{"name":"mwlab","backend":"dokku","host":"dokku@h",
            "services":[{"name":"mwlab","kind":"mwserver","image":"i","domains":[],
            "configFile":"a.json"}]}]}
            """
        let decoded = try StackManifest.decode(from: Data(json.utf8))
        #expect(decoded.stack(named: "mwlab")?.tofu == nil)
        #expect(decoded.stack(named: "mwlab")?.service(named: "mwlab")?.imageVariable == nil)
    }
}

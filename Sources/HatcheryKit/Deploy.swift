import Foundation

public enum DeployError: Error, CustomStringConvertible, Equatable {
    case unknownService(stack: String, service: String)
    case noTofuBinding(stack: String)
    case noImageVariable(service: String)
    case planFailed(message: String)
    case applyFailed(message: String)

    public var description: String {
        switch self {
        case .unknownService(let stack, let service):
            return "stack '\(stack)' declares no service named '\(service)'"
        case .noTofuBinding(let stack):
            return """
                stack '\(stack)' declares no tofu directory, so there is no declaration to \
                deploy through
                """
        case .noImageVariable(let service):
            return """
                service '\(service)' declares no imageVariable, so hatchery cannot tell which \
                tofu variable moves its image
                """
        case .planFailed(let message):
            return "tofu plan failed: \(message)"
        case .applyFailed(let message):
            return "tofu apply failed: \(message)"
        }
    }
}

/// What a deploy would change, worked out before anything is written.
public struct ImagePlan: Sendable, Equatable {
    public let service: String
    public let variable: String
    /// The image the manifest declares.
    public let declared: String
    /// The image the tofu variable's default currently carries.
    public let current: String
    /// What both should read once the deploy is done.
    public let target: String

    public init(service: String, variable: String, declared: String, current: String, target: String) {
        self.service = service
        self.variable = variable
        self.declared = declared
        self.current = current
        self.target = target
    }

    /// Whether the tofu variable has to move.
    public var needsWrite: Bool {
        current != target
    }

    /// Whether the manifest has to move.
    public var updatesManifest: Bool {
        declared != target
    }

    /// The manifest and the tofu variable already disagreed before this deploy was asked for.
    ///
    /// Worth saying out loud: it means someone changed the image outside hatchery, and the
    /// deploy is about to overwrite whatever they did.
    public var wasDrifted: Bool {
        declared != current
    }
}

/// What `tofu plan -detailed-exitcode` said.
public struct PlanOutcome: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// Exit 0. The configuration and the world already agree.
        case clean
        /// Exit 2. There are changes to apply.
        case changes
        /// Anything else. The configuration did not evaluate.
        case failed
    }

    public let verdict: Verdict
    public let output: String

    public init(verdict: Verdict, output: String) {
        self.verdict = verdict
        self.output = output
    }

    /// `-detailed-exitcode` overloads the exit status: 0 clean, 2 changes, everything else an error.
    public static func from(_ result: CommandOutput) -> PlanOutcome {
        switch result.status {
        case 0: return PlanOutcome(verdict: .clean, output: result.combined)
        case 2: return PlanOutcome(verdict: .changes, output: result.combined)
        default: return PlanOutcome(verdict: .failed, output: result.combined)
        }
    }
}

/// The whole of one deploy attempt.
public struct DeployResult: Sendable, Equatable {
    public let plan: ImagePlan
    public let outcome: PlanOutcome
    /// The variables file was put back, because the plan did not evaluate after the write.
    public let reverted: Bool
    /// The output of `tofu apply`, when one was asked for and run.
    public let applied: String?

    public init(plan: ImagePlan, outcome: PlanOutcome, reverted: Bool = false, applied: String? = nil) {
        self.plan = plan
        self.outcome = outcome
        self.reverted = reverted
        self.applied = applied
    }
}

/// Deploys a service by moving the image its declaration carries, then asking tofu what that did.
///
/// Nothing here talks to dokku. The image is a tofu-declared attribute, so writing it at the box
/// would leave the declaration stale and `tofu plan` permanently dirty — the same two-owners
/// mistake that `config sync` exists to undo. hatchery writes the declaration; tofu applies it.
public struct Deployer: Sendable {
    private let execute: CommandExecutor
    private let readFile: @Sendable (String) throws -> String
    private let writeFile: @Sendable (String, String) throws -> Void

    public init(
        execute: @escaping CommandExecutor = ShellRunner.liveExecutor,
        readFile: @escaping @Sendable (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
        writeFile: @escaping @Sendable (String, String) throws -> Void = {
            try $1.write(toFile: $0, atomically: true, encoding: .utf8)
        }
    ) {
        self.execute = execute
        self.readFile = readFile
        self.writeFile = writeFile
    }

    static func planCommand() -> [String] {
        ["tofu", "plan", "-detailed-exitcode", "-no-color", "-input=false"]
    }

    static func destroyPlanCommand() -> [String] {
        ["tofu", "plan", "-destroy", "-detailed-exitcode", "-no-color", "-input=false"]
    }

    /// Public for the same reason as `applyCommand`: the watchable destroy job streams it.
    public static func destroyCommand() -> [String] {
        ["tofu", "destroy", "-auto-approve", "-no-color", "-input=false"]
    }

    /// Public because a watchable apply job streams this exact command; two spellings of
    /// `tofu apply` drifting apart would be two different applies.
    public static func applyCommand() -> [String] {
        ["tofu", "apply", "-auto-approve", "-no-color", "-input=false"]
    }

    /// Works out what a deploy would change, without writing anything.
    ///
    /// Passing no image reconciles tofu to whatever the manifest already declares, which is the
    /// right default: the manifest is the source of truth, so a bare `deploy` means *make it so*.
    public func plan(
        service serviceName: String,
        in stack: StackSpec,
        image: String? = nil
    ) throws -> ImagePlan {
        guard let service = stack.service(named: serviceName) else {
            throw DeployError.unknownService(stack: stack.name, service: serviceName)
        }
        guard let binding = stack.tofu else {
            throw DeployError.noTofuBinding(stack: stack.name)
        }
        guard let variable = service.imageVariable, !variable.isEmpty else {
            throw DeployError.noImageVariable(service: service.name)
        }

        let file = TofuVariableFile(path: binding.variablesPath, contents: try readFile(binding.variablesPath))
        let location = try file.locateDefault(of: variable)

        return ImagePlan(
            service: service.name,
            variable: variable,
            declared: service.image,
            current: location.value,
            target: image ?? service.image
        )
    }

    /// Writes the new image into the variables file and returns what was there before.
    @discardableResult
    public func write(_ plan: ImagePlan, in stack: StackSpec) throws -> String {
        guard let binding = stack.tofu else {
            throw DeployError.noTofuBinding(stack: stack.name)
        }
        let path = binding.variablesPath
        let original = try readFile(path)
        let updated = try TofuVariableFile(path: path, contents: original)
            .settingDefault(of: plan.variable, to: plan.target)
        try writeFile(path, updated.contents)
        return original
    }

    public func tofuPlan(in stack: StackSpec) async throws -> PlanOutcome {
        guard let binding = stack.tofu else {
            throw DeployError.noTofuBinding(stack: stack.name)
        }
        let result = try await execute(Self.planCommand(), Paths.expanded(binding.directory))
        return PlanOutcome.from(result)
    }

    /// What destroying would remove, without removing it.
    public func destroyPlan(in stack: StackSpec) async throws -> PlanSummary {
        guard let binding = stack.tofu else {
            throw DeployError.noTofuBinding(stack: stack.name)
        }
        let result = try await execute(Self.destroyPlanCommand(), Paths.expanded(binding.directory))
        return PlanSummary.parse(result.combined)
    }

    public func tofuDestroy(in stack: StackSpec) async throws -> String {
        guard let binding = stack.tofu else {
            throw DeployError.noTofuBinding(stack: stack.name)
        }
        let result = try await execute(Self.destroyCommand(), Paths.expanded(binding.directory))
        guard result.status == 0 else {
            throw DeployError.applyFailed(message: result.combined)
        }
        return result.combined
    }

    public func tofuApply(in stack: StackSpec) async throws -> String {
        guard let binding = stack.tofu else {
            throw DeployError.noTofuBinding(stack: stack.name)
        }
        let result = try await execute(Self.applyCommand(), Paths.expanded(binding.directory))
        guard result.status == 0 else {
            throw DeployError.applyFailed(message: result.combined)
        }
        return result.combined
    }

    /// Writes the image, plans, and puts the file back if the plan stops evaluating.
    ///
    /// A configuration that no longer parses is worse than an undeployed image: it blocks every
    /// other change to the stack until someone notices. So a failed plan is always followed by a
    /// revert, and the caller is told that it happened.
    public func deploy(
        service serviceName: String,
        in stack: StackSpec,
        image: String? = nil,
        apply: Bool = false
    ) async throws -> DeployResult {
        let plan = try plan(service: serviceName, in: stack, image: image)

        guard plan.needsWrite else {
            // Nothing to write, but the plan still runs: the variable can already read the target
            // while the box runs something else, and that is exactly what a person wants to know.
            return DeployResult(plan: plan, outcome: try await tofuPlan(in: stack))
        }

        let original = try write(plan, in: stack)
        let outcome = try await tofuPlan(in: stack)

        if outcome.verdict == .failed {
            guard let binding = stack.tofu else { throw DeployError.noTofuBinding(stack: stack.name) }
            try writeFile(binding.variablesPath, original)
            return DeployResult(plan: plan, outcome: outcome, reverted: true)
        }

        guard apply else {
            return DeployResult(plan: plan, outcome: outcome)
        }
        return DeployResult(plan: plan, outcome: outcome, applied: try await tofuApply(in: stack))
    }
}

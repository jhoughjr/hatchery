import Foundation

/// One thing an empty box needs before it can host stacks, as an assertion: a check that
/// says whether it already holds, and the commands that make it hold. Convergent by
/// construction — running box init twice lands in the same place, and a box that is
/// half-prepared finishes rather than starting over.
public struct BoxAssertion: Sendable {
    public let name: String
    /// Exit 0 means the box already satisfies this and the fix is skipped.
    public let check: String
    /// Run in order, stopping at the first failure. Empty means check-only: a fact the
    /// box must already have (an OS with apt, a reachable sshd) that hatchery cannot make.
    public let fix: [String]
    /// What to tell the person when the fix cannot be made.
    public let remedy: String

    public init(name: String, check: String, fix: [String] = [], remedy: String = "") {
        self.name = name
        self.check = check
        self.fix = fix
        self.remedy = remedy
    }
}

/// What happened to one assertion.
public struct BoxStep: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        /// The check passed before any fix ran.
        case held
        /// The fix ran and the re-check passed.
        case fixed
        /// The fix ran (or could not) and the re-check still fails.
        case failed
    }

    public let name: String
    public let outcome: Outcome
    public let detail: String

    public init(name: String, outcome: Outcome, detail: String) {
        self.name = name
        self.outcome = outcome
        self.detail = detail
    }
}

/// Points hatchery at an empty box and asserts the prerequisites onto it.
///
/// The onboarding guide was a recipe a person typed; this executes the same recipe as
/// convergent assertions over ssh, narrating each one. The target must be an account that
/// can run the fixes — root on a fresh box, or a sudo-capable user; the assertions say
/// which fix refused rather than guessing at privileges.
public struct BoxInitializer: Sendable {
    private let execute: CommandExecutor

    public init(execute: @escaping CommandExecutor = ShellRunner.liveExecutor) {
        self.execute = execute
    }

    /// The dokku box recipe, in dependency order.
    ///
    /// `operatorKey` is the public key that will drive the box afterwards — the one
    /// hatchery's own ssh uses — registered with dokku so `dokku@box` works the moment
    /// init finishes.
    public static func dokkuAssertions(
        operatorKey: String, network: String = "hatchery-net",
        dokkuVersion: String = Onboarding.knownGoodDokku
    ) -> [BoxAssertion] {
        let key = operatorKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            BoxAssertion(
                name: "box answers over ssh",
                check: "true",
                remedy: "the target must accept this machine's key non-interactively"),
            BoxAssertion(
                name: "apt is present",
                check: "command -v apt-get >/dev/null",
                remedy: "dokku's bootstrap needs Debian or Ubuntu; this box has no apt"),
            BoxAssertion(
                name: "running as root, or sudo without a password",
                check: "[ \"$(id -u)\" = 0 ] || sudo -n true",
                remedy: "the fixes install packages; point box init at root@box or grant sudo"),
            BoxAssertion(
                name: "dokku \(dokkuVersion) installed",
                check: "command -v dokku >/dev/null",
                fix: [
                    "wget -qNP . https://dokku.com/bootstrap.sh",
                    "SUDO=; [ \"$(id -u)\" = 0 ] || SUDO=sudo; "
                        + "DOKKU_TAG=v\(dokkuVersion) $SUDO -E bash bootstrap.sh"
                        + " || DOKKU_TAG=v\(dokkuVersion) bash bootstrap.sh",
                ],
                remedy: "run dokku's bootstrap by hand: https://dokku.com/docs/getting-started/"),
            BoxAssertion(
                name: "operator key authorized for the dokku user",
                check: "SUDO=; [ \"$(id -u)\" = 0 ] || SUDO=sudo; "
                    + "$SUDO dokku ssh-keys:list 2>/dev/null | grep -q hatchery-operator",
                fix: [
                    "SUDO=; [ \"$(id -u)\" = 0 ] || SUDO=sudo; "
                        + "echo '\(key)' | $SUDO dokku ssh-keys:add hatchery-operator",
                ],
                remedy: "add your public key: sudo dokku ssh-keys:add hatchery-operator < key.pub"),
            BoxAssertion(
                name: "shared docker network '\(network)'",
                check: "SUDO=; [ \"$(id -u)\" = 0 ] || SUDO=sudo; "
                    + "$SUDO dokku network:list 2>/dev/null | grep -qx '\(network)'"
                    + " || $SUDO docker network inspect '\(network)' >/dev/null 2>&1",
                fix: [
                    "SUDO=; [ \"$(id -u)\" = 0 ] || SUDO=sudo; "
                        + "$SUDO dokku network:create '\(network)'"
                ],
                remedy: "dokku network:create \(network) — apps and their databases share it"),
        ]
    }

    /// Runs every assertion against the box, in order, narrating as it goes. A failed
    /// assertion stops the run: later steps depend on earlier ones, and continuing would
    /// bury the one line that matters under its consequences.
    public func run(
        host: String, assertions: [BoxAssertion],
        onProgress: @Sendable (String) -> Void
    ) async -> [BoxStep] {
        var steps: [BoxStep] = []
        for assertion in assertions {
            if await passes(assertion.check, on: host) {
                steps.append(BoxStep(name: assertion.name, outcome: .held, detail: "already so"))
                onProgress("hold   \(assertion.name)")
                continue
            }
            guard !assertion.fix.isEmpty else {
                steps.append(
                    BoxStep(name: assertion.name, outcome: .failed, detail: assertion.remedy))
                onProgress("FAILED \(assertion.name) — \(assertion.remedy)")
                break
            }
            onProgress("fixing \(assertion.name)…")
            var fixFailure: String?
            for command in assertion.fix {
                let output = await runRemote(command, on: host)
                if output.status != 0 {
                    fixFailure = output.combined
                    break
                }
            }
            if fixFailure == nil, await passes(assertion.check, on: host) {
                steps.append(BoxStep(name: assertion.name, outcome: .fixed, detail: "fixed"))
                onProgress("fixed  \(assertion.name)")
            } else {
                let detail = fixFailure ?? "the fix ran but the check still fails"
                steps.append(
                    BoxStep(
                        name: assertion.name, outcome: .failed,
                        detail: "\(detail) — \(assertion.remedy)"))
                onProgress("FAILED \(assertion.name) — \(assertion.remedy)")
                break
            }
        }
        return steps
    }

    private func passes(_ check: String, on host: String) async -> Bool {
        (await runRemote(check, on: host)).status == 0
    }

    private func runRemote(_ command: String, on host: String) async -> CommandOutput {
        let argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
                    "sh", "-c", DatabaseProvisioner.shellQuoted(command)]
        do {
            return try await execute(argv, nil)
        } catch {
            return CommandOutput(status: 255, standardOutput: "", standardError: "\(error)")
        }
    }
}

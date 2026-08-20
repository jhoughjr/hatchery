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

/// Where a recipe's commands run. A self-hosted box answers over ssh. A hosted platform
/// has no box, so its facts are checked from this machine, with the operator's own
/// environment and credentials.
public enum BoxLocus: Sendable, Equatable {
    case ssh(host: String)
    case local

    /// The name the narration and the ready line print for this locus.
    public var label: String {
        switch self {
        case .ssh(let host): return host
        case .local: return "this machine"
        }
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

    /// The App Platform recipe. There is no metal to prepare, so every assertion is
    /// check-only: a platform fact the operator must supply, never one hatchery can make.
    ///
    /// The checks run on this machine and read `DIGITALOCEAN_TOKEN` from its environment,
    /// the same way the tofu provider does. `cluster` names the managed Postgres cluster
    /// that clones will create databases in. Without a name, any visible pg cluster holds.
    public static func appPlatformAssertions(cluster: String? = nil) -> [BoxAssertion] {
        let api = "https://api.digitalocean.com/v2"
        let curl = "curl -fsS --max-time 10 -H \"Authorization: Bearer $DIGITALOCEAN_TOKEN\""
        let clusterCheck: String
        let clusterName: String
        let clusterRemedy: String
        if let cluster, !cluster.isEmpty {
            clusterCheck = "\(curl) \(api)/databases | grep -q '\"name\": *\"\(cluster)\"'"
            clusterName = "managed Postgres cluster '\(cluster)' is visible"
            clusterRemedy = "the token sees no cluster named '\(cluster)'. "
                + "Check the name in the DigitalOcean console, or drop --cluster to accept any"
        } else {
            clusterCheck = "\(curl) \(api)/databases | grep -q '\"engine\": *\"pg\"'"
            clusterName = "a managed Postgres cluster is visible"
            clusterRemedy = "clones need an existing cluster to create databases in. "
                + "Create one, or pass --cluster to name the one clones may use"
        }
        return [
            BoxAssertion(
                name: "curl is present",
                check: "command -v curl >/dev/null",
                remedy: "the platform checks speak to the DigitalOcean API through curl"),
            BoxAssertion(
                name: "DIGITALOCEAN_TOKEN is set",
                check: "[ -n \"$DIGITALOCEAN_TOKEN\" ]",
                remedy: "export DIGITALOCEAN_TOKEN=<a personal access token with write scope>"),
            BoxAssertion(
                name: "the token answers",
                check: "\(curl) \(api)/account >/dev/null",
                remedy: "the API refused the token. It has expired, or it lacks read scope"),
            BoxAssertion(
                name: "the container registry answers",
                check: "\(curl) \(api)/registry >/dev/null",
                remedy: "no DOCR registry answers this token. "
                    + "Create one, or grant the token registry scope"),
            BoxAssertion(
                name: clusterName,
                check: clusterCheck,
                remedy: clusterRemedy),
        ]
    }

    /// The Cloud Run recipe. Like App Platform, nothing to prepare, so every assertion is a
    /// check-only platform fact, asked through gcloud on this machine: the CLI is present and
    /// signed in, a project is set, the Run and Artifact Registry APIs are enabled, and a
    /// Cloud SQL Postgres instance is visible. `project` overrides the CLI's configured
    /// project, and `instance` names the Cloud SQL instance clones may create databases in.
    public static func cloudRunAssertions(
        project: String? = nil, instance: String? = nil
    ) -> [BoxAssertion] {
        let scope = project.map { " --project \($0)" } ?? ""
        let instanceCheck: String
        let instanceName: String
        let instanceRemedy: String
        if let instance, !instance.isEmpty {
            instanceCheck = "gcloud sql instances describe '\(instance)'\(scope) --format='value(databaseVersion)' | grep -q POSTGRES"
            instanceName = "Cloud SQL Postgres instance '\(instance)' is visible"
            instanceRemedy = "no Postgres instance named '\(instance)' in the project. "
                + "Check the name in the console, or drop --cluster to accept any"
        } else {
            instanceCheck = "gcloud sql instances list\(scope) --filter='databaseVersion:POSTGRES' --format='value(name)' | grep -q ."
            instanceName = "a Cloud SQL Postgres instance is visible"
            instanceRemedy = "clones need an existing instance to create databases in. "
                + "Create one, or pass --cluster to name the one clones may use"
        }
        return [
            BoxAssertion(
                name: "gcloud is present",
                check: "command -v gcloud >/dev/null",
                remedy: "the platform checks speak to Google Cloud through gcloud: "
                    + "brew install --cask google-cloud-sdk"),
            BoxAssertion(
                name: "gcloud is signed in",
                check: "gcloud auth print-access-token >/dev/null 2>&1",
                remedy: "gcloud auth login, then gcloud auth application-default login for tofu"),
            BoxAssertion(
                name: "a project is set",
                check: project.map { "gcloud projects describe '\($0)' >/dev/null 2>&1" }
                    ?? "[ -n \"$(gcloud config get-value project 2>/dev/null)\" ]",
                remedy: project.map { "the token cannot see project '\($0)'" }
                    ?? "gcloud config set project <id>, or pass --project"),
            BoxAssertion(
                name: "the Cloud Run API is enabled",
                check: "gcloud services list --enabled\(scope) --filter='config.name=run.googleapis.com' --format='value(config.name)' | grep -q run",
                remedy: "gcloud services enable run.googleapis.com\(scope)"),
            BoxAssertion(
                name: "the Artifact Registry API is enabled",
                check: "gcloud services list --enabled\(scope) --filter='config.name=artifactregistry.googleapis.com' --format='value(config.name)' | grep -q artifactregistry",
                remedy: "gcloud services enable artifactregistry.googleapis.com\(scope)"),
            BoxAssertion(
                name: "the Cloud SQL Admin API is enabled",
                check: "gcloud services list --enabled\(scope) --filter='config.name=sqladmin.googleapis.com' --format='value(config.name)' | grep -q sqladmin",
                remedy: "gcloud services enable sqladmin.googleapis.com\(scope)"),
            BoxAssertion(name: instanceName, check: instanceCheck, remedy: instanceRemedy),
        ]
    }

    /// Runs every assertion against the box, in order, narrating as it goes. A failed
    /// assertion stops the run: later steps depend on earlier ones, and continuing would
    /// bury the one line that matters under its consequences.
    public func run(
        host: String, assertions: [BoxAssertion],
        onProgress: @Sendable (String) -> Void
    ) async -> [BoxStep] {
        await self.run(at: .ssh(host: host), assertions: assertions, onProgress: onProgress)
    }

    /// The same run, at any locus.
    public func run(
        at locus: BoxLocus, assertions: [BoxAssertion],
        onProgress: @Sendable (String) -> Void
    ) async -> [BoxStep] {
        var steps: [BoxStep] = []
        for assertion in assertions {
            if await passes(assertion.check, at: locus) {
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
                let output = await self.run(command, at: locus)
                if output.status != 0 {
                    fixFailure = output.combined
                    break
                }
            }
            if fixFailure == nil, await passes(assertion.check, at: locus) {
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

    private func passes(_ check: String, at locus: BoxLocus) async -> Bool {
        (await self.run(check, at: locus)).status == 0
    }

    /// One command at the locus. Over ssh it travels as one quoted `sh -c`. Locally it
    /// is the same `sh -c`, with this process's environment.
    private func run(_ command: String, at locus: BoxLocus) async -> CommandOutput {
        let argv: [String]
        switch locus {
        case .ssh(let host):
            argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
                    "sh", "-c", DatabaseProvisioner.shellQuoted(command)]
        case .local:
            argv = ["sh", "-c", command]
        }
        do {
            return try await execute(argv, nil)
        } catch {
            return CommandOutput(status: 255, standardOutput: "", standardError: "\(error)")
        }
    }
}

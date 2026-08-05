import Foundation

/// One prerequisite, and what to do when it is not met.
public struct PreflightCheck: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case ok
        case failed
        /// Not attempted, because something it depends on already failed.
        case skipped
    }

    public let name: String
    public let status: Status
    /// What was actually found.
    public let detail: String
    /// What to do about it, when there is something to do.
    public let remedy: String?

    public init(name: String, status: Status, detail: String, remedy: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.remedy = remedy
    }
}

/// Checks the things a stack needs before it can be created.
///
/// These are the failures that otherwise surface halfway through `tofu init` or, worse, after a
/// stack has been half-written — as a provider error that says nothing about the missing SSH key
/// that actually caused it. Checking first turns each one into a sentence with a fix in it.
public struct Preflight: Sendable {
    private let execute: CommandExecutor

    public init(execute: @escaping CommandExecutor = ShellRunner.liveExecutor) {
        self.execute = execute
    }

    /// A short connect timeout: an unreachable LAN address should fail in seconds, not hang.
    static func sshCommand(host: String, remote: [String]) -> [String] {
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host] + remote
    }

    /// Whatever the named backend needs, asked of the backend itself.
    public func run(backend: Backend, host: String?) async -> [PreflightCheck] {
        await Providers.support(for: backend).readiness(host: host, execute: execute)
    }

    /// Kept for callers that only ever meant dokku.
    public func run(host: String?) async -> [PreflightCheck] {
        await dokku(host: host)
    }

    /// AWS needs a CLI, credentials that actually resolve, and a region.
    ///
    /// Credentials are checked by asking who they belong to rather than by looking for a file.
    /// They can come from a profile, the environment, SSO or an instance role, and only the
    /// answer matters.
    public func aws() async -> [PreflightCheck] {
        var checks = [await tofu()]

        let cli = await binary(
            "aws", arguments: ["--version"], label: "aws cli", remedy: "brew install awscli")
        checks.append(cli)
        guard cli.status == .ok else {
            // One cause, one failure: without the CLI the other two cannot be asked.
            for name in ["aws credentials", "aws region"] {
                checks.append(
                    PreflightCheck(
                        name: name, status: .skipped,
                        detail: "the aws cli is not installed", remedy: nil))
            }
            return checks
        }

        checks.append(await credentials())
        checks.append(await region())
        return checks
    }

    /// App Platform needs a token; `doctl` is convenient but the provider reads the environment.
    public func digitalOcean() async -> [PreflightCheck] {
        var checks = [await tofu()]

        let token = ProcessInfo.processInfo.environment["DIGITALOCEAN_TOKEN"]
            ?? ProcessInfo.processInfo.environment["DIGITALOCEAN_ACCESS_TOKEN"]
        if let token, !token.isEmpty {
            // Never the value, and never a prefix of it — only that one is present.
            checks.append(
                PreflightCheck(
                    name: "digitalocean token", status: .ok,
                    detail: "DIGITALOCEAN_TOKEN is set (\(token.count) chars)"))
        } else {
            checks.append(
                PreflightCheck(
                    name: "digitalocean token", status: .failed,
                    detail: "DIGITALOCEAN_TOKEN is not set",
                    remedy: "export DIGITALOCEAN_TOKEN=<a personal access token with write scope>"))
        }

        checks.append(
            await binary(
                "doctl", arguments: ["version"], label: "doctl (optional)",
                remedy: "brew install doctl — only needed to inspect apps outside hatchery"))
        return checks
    }

    /// Cloud Run needs gcloud credentials and a project.
    public func google() async -> [PreflightCheck] {
        var checks = [await tofu()]

        let cli = await binary(
            "gcloud", arguments: ["version"], label: "gcloud",
            remedy: "brew install --cask google-cloud-sdk")
        checks.append(cli)
        guard cli.status == .ok else {
            for name in ["google credentials", "google project"] {
                checks.append(
                    PreflightCheck(
                        name: name, status: .skipped, detail: "gcloud is not installed"))
            }
            return checks
        }

        checks.append(
            await value(
                ["gcloud", "auth", "list", "--filter=status:ACTIVE", "--format=value(account)"],
                name: "google credentials", missing: "no active account",
                remedy: "run `gcloud auth application-default login`"))
        checks.append(
            await value(
                ["gcloud", "config", "get-value", "project"],
                name: "google project", missing: "no project configured",
                remedy: "run `gcloud config set project <id>`"))
        return checks
    }

    /// Runs a command whose stdout *is* the answer, and fails when there is not one.
    private func value(
        _ argv: [String], name: String, missing: String, remedy: String
    ) async -> PreflightCheck {
        do {
            let result = try await execute(argv, nil)
            let answer = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            // gcloud prints "(unset)" rather than nothing when a value is missing.
            guard result.status == 0, !answer.isEmpty, answer != "(unset)" else {
                return PreflightCheck(name: name, status: .failed, detail: missing, remedy: remedy)
            }
            return PreflightCheck(name: name, status: .ok, detail: Self.firstLine(answer))
        } catch {
            return PreflightCheck(name: name, status: .failed, detail: "\(error)", remedy: remedy)
        }
    }

    private func credentials() async -> PreflightCheck {
        do {
            let result = try await execute(
                ["aws", "sts", "get-caller-identity", "--output", "text", "--query", "Arn"], nil)
            let arn = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, !arn.isEmpty else {
                return PreflightCheck(
                    name: "aws credentials", status: .failed,
                    detail: arn.isEmpty ? "no identity returned" : Self.firstLine(arn),
                    remedy: "run `aws configure`, or `aws sso login` if the account uses SSO")
            }
            return PreflightCheck(name: "aws credentials", status: .ok, detail: arn)
        } catch {
            return PreflightCheck(
                name: "aws credentials", status: .failed, detail: "\(error)",
                remedy: "run `aws configure`")
        }
    }

    private func region() async -> PreflightCheck {
        do {
            let result = try await execute(["aws", "configure", "get", "region"], nil)
            let name = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, !name.isEmpty else {
                return PreflightCheck(
                    name: "aws region", status: .failed, detail: "no default region configured",
                    remedy: "run `aws configure set region <region>`, or set AWS_REGION")
            }
            return PreflightCheck(name: "aws region", status: .ok, detail: name)
        } catch {
            return PreflightCheck(
                name: "aws region", status: .failed, detail: "\(error)",
                remedy: "run `aws configure set region <region>`")
        }
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    public func dokku(host rawHost: String?) async -> [PreflightCheck] {
        // Normalised here so a bare address is checked as it will actually be used, rather than
        // passing and then failing later under a different user.
        let host = rawHost.map { DokkuProvider.sshTarget($0) }
        var checks: [PreflightCheck] = []
        checks.append(await tofu())
        checks.append(
            await binary(
                "ssh", arguments: ["-V"], label: "ssh client", remedy: "install an ssh client"))

        guard let host, !host.isEmpty else {
            checks.append(
                PreflightCheck(
                    name: "box reachable", status: .skipped,
                    detail: "no host given", remedy: nil))
            checks.append(
                PreflightCheck(
                    name: "dokku responds", status: .skipped,
                    detail: "no host given", remedy: nil))
            return checks
        }

        var reachable = await reachability(host: host)
        // An explicitly wrong user is the likeliest cause, and the generic key advice sends
        // people to authorize the wrong account.
        if reachable.status == .failed, let warning = DokkuProvider.userWarning(host) {
            reachable = PreflightCheck(
                name: reachable.name, status: .failed, detail: reachable.detail, remedy: warning)
        }
        checks.append(reachable)
        if reachable.status == .ok {
            checks.append(await dokku(host: host))
        } else {
            checks.append(
                PreflightCheck(
                    name: "dokku responds", status: .skipped,
                    detail: "the box could not be reached", remedy: nil))
        }
        return checks
    }

    private func tofu() async -> PreflightCheck {
        do {
            let result = try await execute(["tofu", "version"], nil)
            guard result.status == 0, !Self.isMissing(result) else {
                return PreflightCheck(
                    name: "tofu installed", status: .failed,
                    detail: result.combined.isEmpty ? "exited \(result.status)" : result.combined,
                    remedy: "brew install opentofu")
            }
            let version = result.standardOutput
                .split(separator: "\n").first.map(String.init) ?? "installed"
            return PreflightCheck(name: "tofu installed", status: .ok, detail: version)
        } catch {
            return PreflightCheck(
                name: "tofu installed", status: .failed,
                detail: "not found on PATH",
                remedy: "brew install opentofu — hatchery drives tofu rather than the box directly")
        }
    }

    /// Whether a command exists and runs.
    ///
    /// Exit status alone will not do: `ssh -V` writes its version to stderr and exits non-zero
    /// on some builds, so a strict check would call a working ssh broken. But a *missing*
    /// binary is not an error either — `env` exits 127 and says so rather than throwing, and
    /// treating that as success reported "ok: aws: No such file or directory", which is how a
    /// missing CLI passed its own check.
    private func binary(
        _ name: String, arguments: [String], label: String, remedy: String? = nil
    ) async -> PreflightCheck {
        do {
            let result = try await execute([name] + arguments, nil)
            if Self.isMissing(result) {
                return PreflightCheck(
                    name: label, status: .failed, detail: "not found on PATH",
                    remedy: remedy ?? "install \(name)")
            }
            let detail = Self.firstLine(result.combined)
            return PreflightCheck(
                name: label, status: .ok, detail: detail.isEmpty ? "present" : detail)
        } catch {
            return PreflightCheck(
                name: label, status: .failed, detail: "not found on PATH",
                remedy: remedy ?? "install \(name)")
        }
    }

    /// 127 is the shell's "command not found"; the message is checked too because `env` reports
    /// it on stderr and not every platform agrees on the status.
    static func isMissing(_ result: CommandOutput) -> Bool {
        if result.status == 127 { return true }
        let text = result.combined.lowercased()
        return text.contains("no such file or directory") || text.contains("command not found")
    }

    private func reachability(host: String) async -> PreflightCheck {
        do {
            let result = try await execute(Self.sshCommand(host: host, remote: ["version"]), nil)
            if result.status == 0 {
                return PreflightCheck(name: "box reachable", status: .ok, detail: "\(host) answered")
            }
            let message = result.combined.split(separator: "\n").first.map(String.init)
                ?? "exited \(result.status)"
            return PreflightCheck(
                name: "box reachable", status: .failed, detail: message,
                remedy: Self.remedy(for: message, host: host))
        } catch {
            return PreflightCheck(
                name: "box reachable", status: .failed, detail: "\(error)",
                remedy: "check the address and that you are on the same network")
        }
    }

    private func dokku(host: String) async -> PreflightCheck {
        do {
            let result = try await execute(Self.sshCommand(host: host, remote: ["version"]), nil)
            let text = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, !text.isEmpty else {
                return PreflightCheck(
                    name: "dokku responds", status: .failed,
                    detail: text.isEmpty ? "no output" : text,
                    remedy: "the SSH user must be `dokku`; a shell user answers but cannot manage apps")
            }
            return PreflightCheck(
                name: "dokku responds", status: .ok,
                detail: text.split(separator: "\n").first.map(String.init) ?? text)
        } catch {
            return PreflightCheck(
                name: "dokku responds", status: .failed, detail: "\(error)", remedy: nil)
        }
    }

    /// Turns the common SSH failures into the thing to actually do about them.
    static func remedy(for message: String, host: String) -> String {
        let lower = message.lowercased()
        if lower.contains("permission denied") {
            return """
                the key is not authorized for this user. On the box: \
                `dokku ssh-keys:add <name> < ~/.ssh/id_rsa.pub`
                """
        }
        if lower.contains("could not resolve") || lower.contains("name or service not known") {
            return "the hostname does not resolve; use the address, e.g. dokku@192.168.0.103"
        }
        if lower.contains("timed out") || lower.contains("no route to host") {
            return "the box is not reachable from here; check you are on the same network as \(host)"
        }
        if lower.contains("connection refused") {
            return "nothing is listening on port 22 at \(host)"
        }
        return "check the SSH target and that your key is authorized for it"
    }
}

extension Array where Element == PreflightCheck {
    /// Whether anything would stop a stack being created.
    public var allPassed: Bool {
        !contains { $0.status == .failed }
    }
}

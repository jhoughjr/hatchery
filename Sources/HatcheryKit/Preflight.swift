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

    public func run(host: String?) async -> [PreflightCheck] {
        var checks: [PreflightCheck] = []
        checks.append(await tofu())
        checks.append(await binary("ssh", arguments: ["-V"], label: "ssh client"))

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

        let reachable = await reachability(host: host)
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
            guard result.status == 0 else {
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

    private func binary(_ name: String, arguments: [String], label: String) async -> PreflightCheck {
        do {
            let result = try await execute([name] + arguments, nil)
            // `ssh -V` writes its version to stderr and exits non-zero on some builds, so the
            // test is whether it ran at all rather than what it returned.
            let detail = result.combined.split(separator: "\n").first.map(String.init) ?? "present"
            return PreflightCheck(name: label, status: .ok, detail: detail)
        } catch {
            return PreflightCheck(
                name: label, status: .failed, detail: "not found on PATH",
                remedy: "install an ssh client")
        }
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

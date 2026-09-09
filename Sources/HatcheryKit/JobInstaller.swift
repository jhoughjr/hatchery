import Foundation

/// Puts a scaffolded job on the box and asks the supervisor to follow it.
///
/// A container's declaration is applied by tofu. A job's is not: the plist or the unit is the artifact, and the only
/// way to make it true is to write the file and tell launchd or systemd to read it again.
/// Every step goes through the same ssh channel the rest of the host backend uses, so a box that refuses one refuses
/// all of them and nothing is half-applied without saying so.
public struct JobInstaller: Sendable {
    private let execute: CommandExecutor

    public init(execute: @escaping CommandExecutor = ShellRunner.liveExecutor) {
        self.execute = execute
    }

    /// The remote shell lines that install one job, in the order they must run.
    ///
    /// The file travels as base64 rather than as a quoted heredoc. A plist carries quotes, angle brackets and
    /// newlines, and every one of them means something to the remote shell.
    /// `~` is left for the remote shell to expand, because the account's home is the box's answer and not this
    /// machine's.
    public static func steps(
        for service: ServiceSpec, platform: HostPlatform, files: [GeneratedFile]
    ) -> [String] {
        var lines = files.map { file -> String in
            let encoded = Data(file.contents.utf8).base64EncodedString()
            let path = "$HOME/\(file.path)"
            let directory = (file.path as NSString).deletingLastPathComponent
            return "mkdir -p \"$HOME/\(directory)\" && printf %s '\(encoded)' | base64 --decode > \"\(path)\""
        }
        let label = HostProvider.jobLabel(for: service, platform: platform)
        switch platform {
        case .darwin:
            // bootout answers nonzero for a label launchd is not holding, which is the first install every time.
            // The status is dropped so a first install is not read as a failure.
            lines.append("launchctl bootout gui/$(id -u)/\(label) >/dev/null 2>&1 || true")
            lines.append(
                "launchctl bootstrap gui/$(id -u) \"$HOME/Library/LaunchAgents/\(label).plist\"")

        case .linux:
            // The timer is what is enabled for a scheduled job. Enabling the oneshot beside it would run the job
            // once at login as well as on its schedule.
            let unit = service.job?.schedule == nil ? "\(label).service" : "\(label).timer"
            lines.append("systemctl --user daemon-reload")
            lines.append("systemctl --user enable --now \(unit)")
        }
        return lines
    }

    /// Runs the steps on the box and stops at the first one that fails.
    ///
    /// The failing step's own output is what the error carries, because `launchctl bootstrap` says which key of a
    /// plist it refused and no summary of ours would say as much.
    public func install(
        _ service: ServiceSpec, on box: String, platform: HostPlatform, files: [GeneratedFile]
    ) async throws {
        for step in Self.steps(for: service, platform: platform, files: files) {
            let output = try await self.execute(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", box, step], nil)
            guard output.status == 0 else {
                throw CommandFailure(
                    command: "ssh \(box)", status: output.status, message: output.combined)
            }
        }
    }
}

import Foundation

/// The launchd agent that keeps `hatchery serve` running on the control plane.
///
/// A dashboard someone has to remember to start is not a control plane, and the status
/// board's collector polls it on a schedule. The agent runs at load and is kept alive,
/// so the server survives crashes and reboots. It is a user agent rather than a daemon,
/// because serve holds the operator's SSH identity and must run as the operator.
public enum ServeAgent {
    public static let label = "net.jimmyhoughjr.hatchery-serve"

    public static func plistPath(home: String) -> String {
        Paths.join(home, "Library/LaunchAgents/\(label).plist")
    }

    public static func logPath(home: String) -> String {
        Paths.join(home, "Library/Logs/hatchery-serve.log")
    }

    /// The agent's property list. Every argument is spelled out rather than inherited,
    /// because launchd starts the agent with none of the shell's environment.
    public static func plist(
        binary: String, manifest: String, bind: String, port: Int, token: String?,
        home: String
    ) -> String {
        var arguments = [binary, "serve", "--manifest", manifest, "--bind", bind,
                         "--port", String(port)]
        if let token, !token.isEmpty {
            arguments += ["--token", token]
        }
        let log = logPath(home: home)
        let items = arguments.map { "        <string>\(escaped($0))</string>" }
            .joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
            \(items)
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>StandardOutPath</key>
                <string>\(escaped(log))</string>
                <key>StandardErrorPath</key>
                <string>\(escaped(log))</string>
            </dict>
            </plist>

            """
    }

    // MARK: systemd, for a Linux control plane

    public static func unitPath(home: String) -> String {
        Paths.join(home, ".config/systemd/user/hatchery-serve.service")
    }

    /// The systemd user unit. Restart=always is launchd's KeepAlive, and default.target
    /// is a user unit's "at login"; enable-linger is what makes it "at boot" instead.
    public static func unit(
        binary: String, manifest: String, bind: String, port: Int, token: String?
    ) -> String {
        var command = "\(quoted(binary)) serve --manifest \(quoted(manifest)) "
            + "--bind \(bind) --port \(port)"
        if let token, !token.isEmpty {
            command += " --token \(quoted(token))"
        }
        return """
            [Unit]
            Description=hatchery serve — the stack dashboard and status route
            After=network-online.target

            [Service]
            ExecStart=\(command)
            Restart=always
            RestartSec=3

            [Install]
            WantedBy=default.target

            """
    }

    /// systemd's quoting for an ExecStart argument.
    static func quoted(_ value: String) -> String {
        value.contains(" ") || value.contains("\"")
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : value
    }

    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

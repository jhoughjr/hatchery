import Foundation

/// Where hatchery is running, for the purpose of telling someone how to install something.
///
/// hatchery builds and runs on Linux arm64 as well as macOS — it was proven on the opi box —
/// so a remedy that says `brew install` is wrong half the time, and wrong in the one place a
/// person is most likely to copy it verbatim.
public enum Platform: String, Sendable, Codable {
    case macOS
    case linux
    case other

    public static var current: Platform {
        #if os(macOS)
            return .macOS
        #elseif os(Linux)
            return .linux
        #else
            return .other
        #endif
    }
}

/// How to install the tools hatchery shells out to.
///
/// Where a package manager genuinely carries the tool, the command is given. Where the vendor's
/// own installer is the real answer, this names the documentation rather than inventing a URL
/// or a flag — a confidently wrong install command costs more than an honest pointer.
public enum InstallHint {
    public static func forTool(
        _ tool: String, platform: Platform = .current
    ) -> String {
        switch (tool, platform) {
        case ("opentofu", .macOS):
            return "brew install opentofu"
        case ("opentofu", _):
            return "install OpenTofu — see opentofu.org/docs/intro/install"

        case ("awscli", .macOS):
            return "brew install awscli"
        case ("awscli", _):
            return "install the AWS CLI — see docs.aws.amazon.com/cli (your package manager may carry `awscli`)"

        case ("gcloud", .macOS):
            return "brew install --cask google-cloud-sdk"
        case ("gcloud", _):
            return "install the gcloud SDK — see cloud.google.com/sdk/docs/install"

        case ("doctl", .macOS):
            return "brew install doctl"
        case ("doctl", _):
            return "install doctl — see docs.digitalocean.com/reference/doctl/how-to/install"

        case ("ssh", .macOS):
            return "an ssh client ships with macOS; check your PATH"
        case ("ssh", .linux):
            return "install an ssh client, e.g. `apt install openssh-client`"
        case ("ssh", _):
            return "install an ssh client"

        default:
            return "install \(tool)"
        }
    }

    /// The install step for a setup guide, as commands rather than prose.
    ///
    /// A guide is copied line by line, so it gets a command for the platform it is read on and
    /// the other named beside it — someone reading on a Mac may well be setting up from Linux
    /// next week, and silently hiding the other half would make the guide look incomplete.
    public static func commands(
        for tool: String, platform: Platform = .current
    ) -> [String] {
        switch tool {
        case "awscli":
            return platform == .macOS
                ? ["brew install awscli", "# Linux: see docs.aws.amazon.com/cli"]
                : ["# see docs.aws.amazon.com/cli for your distribution",
                   "# macOS: brew install awscli"]
        case "gcloud":
            return platform == .macOS
                ? ["brew install --cask google-cloud-sdk",
                   "# Linux: see cloud.google.com/sdk/docs/install"]
                : ["# see cloud.google.com/sdk/docs/install for your distribution",
                   "# macOS: brew install --cask google-cloud-sdk"]
        case "doctl":
            return platform == .macOS
                ? ["brew install doctl",
                   "# Linux: see docs.digitalocean.com/reference/doctl/how-to/install"]
                : ["# see docs.digitalocean.com/reference/doctl/how-to/install",
                   "# macOS: brew install doctl"]
        default:
            return [forTool(tool, platform: platform)]
        }
    }
}

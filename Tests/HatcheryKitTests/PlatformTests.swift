import Foundation
import Testing

@testable import HatcheryKit

@Suite("Install hints follow the platform")
struct InstallHintTests {
    @Test("macOS gets brew, Linux never does")
    func platformSpecific() {
        for tool in ["opentofu", "awscli", "gcloud", "doctl"] {
            #expect(InstallHint.forTool(tool, platform: .macOS).contains("brew"))
            // hatchery builds and runs on Linux arm64; `brew install` there is wrong in the one
            // place someone is most likely to copy it verbatim.
            #expect(!InstallHint.forTool(tool, platform: .linux).contains("brew"))
            #expect(!InstallHint.forTool(tool, platform: .linux).isEmpty)
        }
    }

    @Test("a Linux hint points somewhere real rather than inventing a command")
    func linuxPointsAtDocs() {
        // Where the vendor's own installer is the answer, naming the docs beats a confidently
        // wrong flag.
        #expect(InstallHint.forTool("opentofu", platform: .linux).contains("opentofu.org"))
        #expect(InstallHint.forTool("awscli", platform: .linux).contains("docs.aws.amazon.com"))
        #expect(InstallHint.forTool("gcloud", platform: .linux).contains("cloud.google.com"))
        #expect(InstallHint.forTool("doctl", platform: .linux).contains("digitalocean.com"))
    }

    @Test("ssh differs by platform rather than telling macOS to install what it ships with")
    func sshHint() {
        #expect(InstallHint.forTool("ssh", platform: .macOS).contains("ships with macOS"))
        #expect(InstallHint.forTool("ssh", platform: .linux).contains("openssh-client"))
    }

    @Test("an unknown tool still gets a sentence rather than nothing")
    func unknownTool() {
        #expect(InstallHint.forTool("nonesuch", platform: .linux) == "install nonesuch")
    }

    @Test("a guide names the other platform too, so it does not look incomplete")
    func guideCoversBoth() {
        let onMac = InstallHint.commands(for: "awscli", platform: .macOS)
        let onLinux = InstallHint.commands(for: "awscli", platform: .linux)

        // The platform you are reading on gets the runnable line; the other is named beside it.
        #expect(onMac.first?.hasPrefix("brew") == true)
        #expect(onMac.contains { $0.contains("Linux") })
        #expect(onLinux.allSatisfy { !$0.hasPrefix("brew") })
        #expect(onLinux.contains { $0.contains("macOS: brew") })
    }

    @Test("the AWS guide's install step follows the platform it is read on")
    func onboardingUsesTheTable() {
        let install = Onboarding.awsSteps.first { $0.title.contains("Install the AWS CLI") }
        #expect(install != nil)
        let text = install?.commands.joined(separator: " ") ?? ""
        if Platform.current == .linux {
            #expect(!text.hasPrefix("brew"))
        }
        #expect(text.contains("aws configure"))
    }

    @Test("no setup guide hardcodes a package manager for the machine it is not on")
    func noGuideAssumesMacOS() {
        for backend in Backend.allCases {
            for step in Providers.support(for: backend).setupSteps where step.on == "here" {
                for command in step.commands {
                    // A commented line naming the other platform is fine; a runnable one is not.
                    guard !command.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
                    if Platform.current != .macOS {
                        #expect(
                            !command.hasPrefix("brew"),
                            "\(backend.rawValue) tells a non-mac to run: \(command)")
                    }
                }
            }
        }
    }
}

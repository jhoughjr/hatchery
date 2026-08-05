import Foundation
import Testing

@testable import HatcheryKit

private func awsStack() -> StackSpec {
    StackSpec(
        name: "cloud", backend: .aws, environment: .dev,
        tofu: TofuBinding(directory: "/infra/cloud"), services: [])
}

private func request(_ name: String = "mwprod") -> ScaffoldRequest {
    var service = ServiceSpec(
        name: name, kind: .mwserver,
        image: "123456789012.dkr.ecr.us-east-1.amazonaws.com/mwserver:v1",
        domains: [], configFile: "\(name).config.json")
    service.imageVariable = "\(name)_image"
    return ScaffoldRequest(stack: awsStack(), service: service, containerPort: 8080)
}

@Suite("AWS App Runner provider")
struct AWSProviderTests {
    @Test("the service declaration carries the pieces App Runner needs")
    func declarationShape() throws {
        let files = try AWSProvider().declaration(for: request())
        let tf = try #require(files.first { $0.role == .declaration })

        #expect(tf.path == "mwprod.tf")
        #expect(tf.contents.contains("resource \"aws_apprunner_service\" \"mwprod\""))
        #expect(tf.contents.contains("service_name = \"mwprod\""))
        #expect(tf.contents.contains("image_identifier      = var.mwprod_image"))
        #expect(tf.contents.contains("image_repository_type = \"ECR\""))
        #expect(tf.contents.contains("port = \"8080\""))
        // The same gitignored sidecar the dokku backend uses, so one service keeps one config
        // file wherever it runs and `config sync` still means something.
        #expect(tf.contents.contains("jsondecode(file(\"${path.module}/mwprod.config.json\"))"))
        #expect(tf.contents.contains("sensitive("))
    }

    @Test("the health path follows the service kind, as it does everywhere else")
    func healthPathFollowsKind() throws {
        let files = try AWSProvider().declaration(for: request())
        let tf = try #require(files.first { $0.role == .declaration })
        #expect(tf.contents.contains("path     = \"/health\""))

        var gsx = request("gsx")
        gsx.service.kind = .gsxGateway
        let other = try AWSProvider().declaration(for: gsx)
        #expect(other.first { $0.role == .declaration }?.contents.contains("\"/healthz\"") == true)
    }

    @Test("auto deployments are off, because hatchery owns when a deploy happens")
    func autoDeploymentsOff() throws {
        let files = try AWSProvider().declaration(for: request())
        let tf = try #require(files.first { $0.role == .declaration })
        // Otherwise pushing a tag would deploy behind hatchery's back and `tofu plan` would
        // stop describing what is running.
        #expect(tf.contents.contains("auto_deployments_enabled = false"))
    }

    @Test("the assigned URL is an output, since AWS chooses it rather than the manifest")
    func exposesURL() throws {
        let files = try AWSProvider().declaration(for: request())
        let tf = try #require(files.first { $0.role == .declaration })
        #expect(tf.contents.contains("output \"mwprod_url\""))
        #expect(tf.contents.contains("aws_apprunner_service.mwprod.service_url"))
    }

    @Test("no domain is required, unlike dokku, because App Runner assigns one")
    func needsNoDomain() throws {
        // A dokku app with no domain is unreachable and is refused. Here it is normal.
        _ = try AWSProvider().declaration(for: request())
    }

    @Test("the bootstrap names the aws provider and a region")
    func bootstrapShape() {
        let files = AWSProvider().bootstrapFiles(host: "", sshKeyPath: "", region: "eu-west-2")
        let versions = files.first { $0.path == "versions.tf" }
        let variables = files.first { $0.path == "variables.tf" }

        #expect(versions?.contents.contains("source  = \"hashicorp/aws\"") == true)
        #expect(variables?.contents.contains("default     = \"eu-west-2\"") == true)
        // Credentials are never written into the configuration.
        #expect(files.allSatisfy { !$0.contents.lowercased().contains("secret_key") })
    }

    @Test("a missing region falls back rather than generating an empty one")
    func regionFallback() {
        let files = AWSProvider().bootstrapFiles(host: "", sshKeyPath: "", region: nil)
        #expect(files.first { $0.path == "variables.tf" }?.contents.contains("us-east-1") == true)
    }

    @Test("names that are not legal identifiers are folded")
    func foldsIdentifier() {
        #expect(AWSProvider.identifier("mw-prod") == "mw_prod")
        #expect(AWSProvider.identifier("2fast") == "svc_2fast")
    }

    @Test("AWS uses the connection-string contract, not the discrete database keys")
    func contractMatchesAppPlatform() throws {
        let aws = try #require(EnvContract.contract(for: .mwserver, backend: .aws))
        let dokku = try #require(EnvContract.contract(for: .mwserver, backend: .dokku))

        // There is no postgres on the same box to reach with DATABASE_HOST and friends.
        #expect(aws.retired.contains("DATABASE_HOST"))
        #expect(!dokku.retired.contains("DATABASE_HOST"))
    }

    @Test("reading live config from AWS is refused rather than half-answered")
    func liveConfigRefused() async {
        let reader = LiveConfigReader(run: { _ in Data() })
        let service = awsStack().services.first
            ?? ServiceSpec(name: "x", kind: .mwserver, image: "i", configFile: "c.json")

        await #expect(throws: LiveConfigError.unsupportedBackend(.aws)) {
            _ = try await reader.config(for: service, in: awsStack())
        }
    }
}

@Suite("Backend readiness")
struct BackendReadinessTests {
    private func preflight(
        _ handler: @escaping @Sendable ([String]) -> CommandOutput
    ) -> Preflight {
        Preflight(execute: { argv, _ in handler(argv) })
    }

    /// What `/usr/bin/env` actually does for a command that is not installed: exit 127 with a
    /// message, rather than throwing. Treating that as success reported a missing CLI as `ok`.
    private func missing() -> CommandOutput {
        CommandOutput(status: 127, standardOutput: "", standardError: "env: aws: No such file or directory")
    }

    @Test("a binary that is not installed fails rather than passing on a message")
    func missingBinaryFails() async {
        let checks = await preflight({ argv in
            argv.first == "tofu" ? CommandOutput(status: 0, standardOutput: "OpenTofu v1.12.5") : self.missing()
        }).aws()

        let cli = checks.first { $0.name == "aws cli" }
        #expect(cli?.status == .failed)
        #expect(cli?.detail == "not found on PATH")
        #expect(cli?.remedy?.contains("awscli") == true)
    }

    @Test("without the cli, credentials and region are skipped rather than failed twice")
    func skipsWhatCannotBeAsked() async {
        let checks = await preflight({ argv in
            argv.first == "tofu" ? CommandOutput(status: 0, standardOutput: "v1") : self.missing()
        }).aws()

        #expect(checks.first { $0.name == "aws credentials" }?.status == .skipped)
        #expect(checks.first { $0.name == "aws region" }?.status == .skipped)
    }

    @Test("a configured account passes, reporting the identity it resolved to")
    func configuredAccountPasses() async {
        let checks = await preflight({ argv in
            if argv.first == "tofu" { return CommandOutput(status: 0, standardOutput: "v1") }
            if argv.contains("get-caller-identity") {
                return CommandOutput(status: 0, standardOutput: "arn:aws:iam::123456789012:user/jimmy")
            }
            if argv.contains("region") { return CommandOutput(status: 0, standardOutput: "us-east-1") }
            return CommandOutput(status: 0, standardOutput: "aws-cli/2.15.0")
        }).aws()

        #expect(checks.allPassed)
        #expect(checks.first { $0.name == "aws credentials" }?.detail.contains("123456789012") == true)
        #expect(checks.first { $0.name == "aws region" }?.detail == "us-east-1")
    }

    @Test("credentials that do not resolve say how to sign in")
    func unresolvedCredentials() async {
        let checks = await preflight({ argv in
            if argv.first == "tofu" { return CommandOutput(status: 0, standardOutput: "v1") }
            if argv.contains("get-caller-identity") {
                return CommandOutput(
                    status: 255, standardOutput: "",
                    standardError: "Unable to locate credentials")
            }
            return CommandOutput(status: 0, standardOutput: "aws-cli/2.15.0")
        }).aws()

        let creds = checks.first { $0.name == "aws credentials" }
        #expect(creds?.status == .failed)
        #expect(creds?.remedy?.contains("sso login") == true)
        #expect(!checks.allPassed)
    }

    @Test("each backend answers for itself, and asks only what it needs")
    func backendsAskDifferentQuestions() async {
        let handler: @Sendable ([String]) -> CommandOutput = { _ in
            CommandOutput(status: 0, standardOutput: "ok")
        }
        let aws = await preflight(handler).run(backend: .aws, host: nil)
        let dokku = await preflight(handler).run(backend: .dokku, host: nil)

        // AWS never asks about a box; dokku never asks about a region.
        #expect(aws.contains { $0.name.contains("region") })
        #expect(!aws.contains { $0.name.contains("box") })
        #expect(dokku.contains { $0.name.contains("box") })
        #expect(!dokku.contains { $0.name.contains("region") })
    }

    @Test("App Platform reports that it cannot be created, with the reason")
    func appPlatformIsHonest() async {
        let checks = await preflight({ _ in CommandOutput(status: 0, standardOutput: "doctl 1.0") })
            .run(backend: .appPlatform, host: nil)
        #expect(!checks.allPassed)
        #expect(checks.contains { $0.remedy?.contains("EV[...]") == true })
    }
}

@Suite("Per-backend setup guides")
struct BackendSetupTests {
    @Test("every backend explains itself, including the one that cannot be authored")
    func everyBackendHasAGuide() {
        for backend in Backend.allCases {
            let steps = Providers.support(for: backend).setupSteps
            #expect(!steps.isEmpty, "\(backend.rawValue) has no setup guide")
            for step in steps {
                #expect(step.why.count > 40)
                #expect(["box", "here"].contains(step.on))
            }
        }
    }

    @Test("the AWS guide covers what its readiness check asks about")
    func awsGuideMatchesChecks() {
        let text = Onboarding.awsSteps
            .map { $0.title + " " + $0.why + " " + $0.commands.joined(separator: " ") }
            .joined(separator: "\n").lowercased()

        #expect(text.contains("aws configure"))
        #expect(text.contains("region"))
        #expect(text.contains("ecr"))
        // The access role is the one people create four of; the guide says it is per account.
        #expect(text.contains("once per account"))
        #expect(text.contains("hatchery doctor --backend aws"))
    }

    @Test("hatchery is never told to hold AWS credentials")
    func neverStoresCredentials() {
        let text = Onboarding.awsSteps.map(\.why).joined(separator: " ").lowercased()
        #expect(text.contains("does not hold aws credentials"))
    }
}

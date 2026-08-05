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

    @Test("App Platform checks for a token, and never reports its value")
    func appPlatformChecksToken() async {
        let checks = await preflight({ _ in CommandOutput(status: 0, standardOutput: "doctl 1.0") })
            .run(backend: .appPlatform, host: nil)

        let token = checks.first { $0.name == "digitalocean token" }
        #expect(token != nil)
        // Whatever the environment holds, the check reports presence and a length, never the
        // value and never a prefix of it.
        #expect(token?.detail.contains("dop_v1") == false)
        if token?.status == .failed {
            #expect(token?.remedy?.contains("DIGITALOCEAN_TOKEN") == true)
        }
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

private func stack(_ backend: Backend) -> StackSpec {
    StackSpec(
        name: "cloud", backend: backend, environment: .dev,
        tofu: TofuBinding(directory: "/infra/cloud"), services: [])
}

private func req(_ backend: Backend, name: String = "mwprod", domains: [String] = []) -> ScaffoldRequest {
    var service = ServiceSpec(
        name: name, kind: .mwserver, image: "myorg/mwserver:v1",
        domains: domains, configFile: "\(name).config.json")
    service.imageVariable = "\(name)_image"
    return ScaffoldRequest(stack: stack(backend), service: service, containerPort: 8080)
}

@Suite("App Platform is authorable after all")
struct AppPlatformProviderTests {
    @Test("hatchery can create an App Platform app")
    func isAuthorable() {
        // This was reported as impossible on the grounds that a spec is YAML applied through
        // doctl. The provider has a first-class digitalocean_app resource; the claim was wrong.
        #expect(Providers.support(for: .appPlatform).authorable)
        #expect((try? Providers.provider(for: .appPlatform)) != nil)
    }

    @Test("the spec carries the image, port, health check and environment")
    func declarationShape() throws {
        let files = try AppPlatformProvider().declaration(for: req(.appPlatform))
        let tf = try #require(files.first { $0.role == .declaration })

        #expect(tf.contents.contains("resource \"digitalocean_app\" \"mwprod\""))
        #expect(tf.contents.contains("http_port          = 8080"))
        #expect(tf.contents.contains("http_path = \"/health\""))
        // The provider wants repository and tag separately, but a deploy still moves one value.
        #expect(tf.contents.contains("repository    = split(\":\", var.mwprod_image)[0]"))
        #expect(tf.contents.contains("try(split(\":\", var.mwprod_image)[1], \"latest\")"))
        // Environment is repeated blocks here, not a map, so the config file is expanded.
        #expect(tf.contents.contains("dynamic \"env\""))
        #expect(tf.contents.contains("for_each = jsondecode(file(\"${path.module}/mwprod.config.json\"))"))
    }

    @Test("each declared domain becomes its own block")
    func domains() throws {
        let files = try AppPlatformProvider().declaration(
            for: req(.appPlatform, domains: ["a.example.com", "b.example.com"]))
        let tf = try #require(files.first { $0.role == .declaration })
        #expect(tf.contents.contains("name = \"a.example.com\""))
        #expect(tf.contents.contains("name = \"b.example.com\""))
    }

    @Test("no domain is fine, because App Platform assigns one")
    func noDomains() throws {
        let files = try AppPlatformProvider().declaration(for: req(.appPlatform))
        #expect(files.first { $0.role == .declaration }?.contents.contains("domain {") == false)
    }

    @Test("reading config back is still refused, which is the part that was actually blocked")
    func readingIsStillUnsupported() async {
        let reader = LiveConfigReader(run: { _ in Data() })
        let service = ServiceSpec(name: "x", kind: .mwserver, image: "i", configFile: "c.json")
        await #expect(throws: LiveConfigError.unsupportedBackend(.appPlatform)) {
            _ = try await reader.config(for: service, in: stack(.appPlatform))
        }
    }

    @Test("the token is never written into the configuration")
    func tokenStaysInTheEnvironment() {
        let files = AppPlatformProvider().bootstrapFiles(host: "", sshKeyPath: "", region: "lon1")
        for file in files {
            #expect(!file.contents.contains("dop_v1"))
            #expect(!file.contents.lowercased().contains("token ="))
        }
        #expect(files.first { $0.path == "variables.tf" }?.contents.contains("lon1") == true)
    }
}

@Suite("Cloud Run")
struct CloudRunProviderTests {
    @Test("the container carries the image, port, environment and a startup probe")
    func declarationShape() throws {
        let files = try CloudRunProvider().declaration(for: req(.cloudRun))
        let tf = try #require(files.first { $0.role == .declaration })

        #expect(tf.contents.contains("resource \"google_cloud_run_v2_service\" \"mwprod\""))
        #expect(tf.contents.contains("image = var.mwprod_image"))
        #expect(tf.contents.contains("container_port = 8080"))
        // Cloud Run names the field `name`, unlike App Platform's `key`.
        #expect(tf.contents.contains("name  = env.key"))
        #expect(tf.contents.contains("value = env.value"))
        #expect(tf.contents.contains("startup_probe"))
        #expect(tf.contents.contains("path = \"/health\""))
    }

    @Test("a startup probe rather than a liveness probe")
    func startupNotLiveness() throws {
        let files = try CloudRunProvider().declaration(for: req(.cloudRun))
        let tf = try #require(files.first { $0.role == .declaration })
        // A slow boot should be waited out, not restarted in a loop.
        #expect(!tf.contents.contains("liveness_probe"))
    }

    @Test("the assigned URI is an output, since Google chooses it")
    func exposesURL() throws {
        let files = try CloudRunProvider().declaration(for: req(.cloudRun))
        #expect(
            files.first { $0.role == .declaration }?.contents
                .contains("google_cloud_run_v2_service.mwprod.uri") == true)
    }

    @Test("scaling to zero is the default, because an idle lab service should cost nothing")
    func scalesToZero() throws {
        let files = try CloudRunProvider().declaration(for: req(.cloudRun))
        let variables = try #require(files.first { $0.role == .variableAppend })
        #expect(variables.contents.contains("min_instances"))
        #expect(variables.contents.contains("default     = 0"))
    }
}

@Suite("Every backend agrees with itself")
struct BackendConsistencyTests {
    @Test("an authorable backend can generate a declaration and a bootstrap")
    func authorableBackendsGenerate() throws {
        for provider in Providers.all where provider.authorable {
            let files = provider.bootstrapFiles(
                host: "dokku@h", sshKeyPath: "~/.ssh/id_rsa", region: "r")
            #expect(!files.isEmpty, "\(provider.backend.rawValue) generates no bootstrap")
            #expect(files.contains { $0.path == "versions.tf" })

            // Every authorable backend must produce a declaration for the same request shape.
            let declaration = try provider.declaration(for: req(provider.backend, domains: ["x.example.com"]))
            #expect(!declaration.isEmpty)
        }
    }

    @Test("no generated configuration ever carries a credential")
    func noCredentialsInGeneratedFiles() throws {
        for provider in Providers.all where provider.authorable {
            // A domain is supplied for every backend because dokku requires one; the others
            // tolerate it, so one request shape covers them all.
            let files = provider.bootstrapFiles(host: "dokku@h", sshKeyPath: "~/.ssh/id_rsa", region: "r")
                + (try provider.declaration(for: req(provider.backend, domains: ["x.example.com"])))
            for file in files {
                let lower = file.contents.lowercased()
                #expect(!lower.contains("secret_key"))
                #expect(!lower.contains("access_key ="))
                #expect(!lower.contains("password ="))
            }
        }
    }

    @Test("only dokku keeps the discrete database keys")
    func contractsSplitOnPlacement() throws {
        for backend in Backend.allCases {
            let contract = try #require(EnvContract.contract(for: .mwserver, backend: backend))
            if backend == .dokku {
                #expect(!contract.retired.contains("DATABASE_HOST"))
            } else {
                // Nothing else has a postgres on the same box to reach that way.
                #expect(contract.retired.contains("DATABASE_HOST"))
            }
        }
    }
}

import Foundation

/// Authors an AWS App Runner service.
///
/// App Runner rather than ECS or Fargate, for the first AWS backend, because hatchery's model of
/// a service is *an image, some environment, a domain and a health path* — which is exactly what
/// App Runner takes. Fargate would need a VPC, subnets, a load balancer and target groups
/// generated alongside every service, none of which hatchery has an opinion about yet. ECS can
/// arrive later as its own backend rather than as a flag on this one.
///
/// **Untested against a live AWS account.** The generated configuration is checked for shape and
/// for `tofu fmt`, not for a successful apply. Treat the first real deploy as the actual test.
public struct AWSProvider: ServiceProvider {
    public init() {}

    public var backend: Backend { .aws }
    public var displayName: String { "AWS App Runner" }
    public var authorable: Bool { true }

    public var setupSteps: [SetupStep] { Onboarding.awsSteps }

    public func readiness(
        host: String?, execute: @escaping CommandExecutor
    ) async -> [PreflightCheck] {
        await Preflight(execute: execute).aws()
    }

    public func imageVariableName(for request: ScaffoldRequest) -> String? {
        request.service.imageVariable ?? "\(Self.identifier(request.service.name))_image"
    }

    public func imageVariable(for request: ScaffoldRequest) -> String? {
        guard let name = imageVariableName(for: request) else { return nil }
        return """

            variable "\(name)" {
              description = "Image for the \(request.service.name) service. App Runner pulls from \
            ECR, so this is a repository URI and tag."
              type        = string
              default     = "\(request.service.image)"
            }
            """
    }

    public func bootstrapFiles(host: String, sshKeyPath: String, region: String?) -> [GeneratedFile] {
        [
            GeneratedFile(path: "versions.tf", contents: Self.versions, role: .declaration),
            GeneratedFile(path: "providers.tf", contents: Self.providers, role: .declaration),
            GeneratedFile(
                path: "variables.tf",
                contents: Self.variables(region: region ?? "us-east-1"),
                role: .declaration),
        ]
    }

    public func declaration(for request: ScaffoldRequest) throws -> [GeneratedFile] {
        let service = request.service
        guard let variable = imageVariableName(for: request) else {
            throw ProviderError.missingDetail("an image variable")
        }
        let identifier = Self.identifier(service.name)
        let healthPath = service.healthPath ?? service.kind.defaultHealthPath

        // The config map is read from the same gitignored sidecar the dokku backend uses, so a
        // service keeps one config file wherever it runs and `config sync` stays meaningful.
        let body = """
            # \(service.kind.rawValue) service '\(service.name)', authored by hatchery.
            resource "aws_apprunner_service" "\(identifier)" {
              service_name = "\(service.name)"

              source_configuration {
                # App Runner pulls the image; it does not build it.
                image_repository {
                  image_identifier      = var.\(variable)
                  image_repository_type = "ECR"

                  image_configuration {
                    port = "\(request.containerPort)"

                    # Loaded from a gitignored file rather than variables, matching the dokku
                    # backend: the values are secrets and never belong in the configuration.
                    runtime_environment_variables = sensitive(
                      jsondecode(file("${path.module}/\(service.configFile)"))
                    )
                  }
                }

                authentication_configuration {
                  access_role_arn = var.apprunner_access_role_arn
                }

                auto_deployments_enabled = false
              }

              instance_configuration {
                cpu    = var.\(identifier)_cpu
                memory = var.\(identifier)_memory
              }

              health_check_configuration {
                protocol = "HTTP"
                path     = "\(healthPath)"
              }

              tags = {
                ManagedBy = "hatchery"
                Stack     = "\(request.stack.name)"
              }
            }

            output "\(identifier)_url" {
              description = "The URL App Runner assigned to \(service.name)."
              value       = aws_apprunner_service.\(identifier).service_url
            }

            """

        var files = [GeneratedFile(path: "\(identifier).tf", contents: body, role: .declaration)]
        files.append(
            GeneratedFile(
                path: "variables.tf",
                contents: """

                    variable "\(identifier)_cpu" {
                      description = "vCPU for \(service.name), in App Runner units."
                      type        = string
                      default     = "1024"
                    }

                    variable "\(identifier)_memory" {
                      description = "Memory for \(service.name), in App Runner units."
                      type        = string
                      default     = "2048"
                    }
                    """,
                role: .variableAppend))
        return files
    }

    static let versions = """
        # Written by hatchery.
        terraform {
          required_version = ">= 1.5"

          required_providers {
            aws = {
              source  = "hashicorp/aws"
              version = "~> 5.0"
            }
          }
        }
        """

    static let providers = """
        # Written by hatchery.
        #
        # Credentials come from the environment or your AWS profile, never from this file.
        # `hatchery doctor --backend aws` checks that they resolve.
        provider "aws" {
          region = var.aws_region
        }
        """

    static func variables(region: String) -> String {
        """
        # Written by hatchery. Per-service variables are appended below as services are added,
        # so keep this file rather than regenerating it.
        variable "aws_region" {
          description = "Region the stack runs in."
          type        = string
          default     = "\(region)"
        }

        # IAM role App Runner assumes to pull from ECR. Create it once per account with the
        # AWSAppRunnerServicePolicyForECRAccess policy attached, then put its ARN here.
        # `hatchery setup --backend aws` has the commands.
        variable "apprunner_access_role_arn" {
          description = "IAM role App Runner assumes to pull images from ECR."
          type        = string
          default     = ""
        }
        """
    }

    /// A terraform identifier for a service name.
    static func identifier(_ name: String) -> String {
        let folded = String(
            name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        ).lowercased()
        return folded.first?.isNumber == true ? "svc_" + folded : folded
    }
}

import Foundation

/// Authors a DigitalOcean App Platform app.
///
/// hatchery previously reported that it could not create one, on the grounds that a spec is YAML
/// applied through `doctl`. That was wrong: the DigitalOcean provider has a first-class
/// `digitalocean_app` resource whose `spec.service` block takes an image, an environment, a port
/// and a health check — hatchery's whole model.
///
/// What remains true is the *other* half. Reading a spec back returns `EV[...]` ciphertext for
/// every value typed SECRET, so `config audit` and `config sync` still refuse for this backend
/// rather than reporting drift they cannot see.
public struct AppPlatformProvider: ServiceProvider {
    public init() {}

    public var backend: Backend { .appPlatform }
    public var displayName: String { "DigitalOcean App Platform" }
    public var authorable: Bool { true }

    public var setupSteps: [SetupStep] { Onboarding.appPlatformSteps }

    public func readiness(
        host: String?, execute: @escaping CommandExecutor
    ) async -> [PreflightCheck] {
        await Preflight(execute: execute).digitalOcean()
    }

    public func imageVariableName(for request: ScaffoldRequest) -> String? {
        request.service.imageVariable ?? "\(Self.identifier(request.service.name))_image"
    }

    public func imageVariable(for request: ScaffoldRequest) -> String? {
        guard let name = imageVariableName(for: request) else { return nil }
        return """

            variable "\(name)" {
              description = "Image for \(request.service.name), as repository:tag. Split into the \
            registry fields the provider wants."
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
                path: "variables.tf", contents: Self.variables(region: region ?? "nyc3"),
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
        let domains = service.domains.filter { !$0.isEmpty }

        var body = """
            # \(service.kind.rawValue) app '\(service.name)', authored by hatchery.
            resource "digitalocean_app" "\(identifier)" {
              spec {
                name   = "\(service.name)"
                region = var.do_region

                service {
                  name               = "\(service.name)"
                  http_port          = \(request.containerPort)
                  instance_count     = var.\(identifier)_instance_count
                  instance_size_slug = var.\(identifier)_instance_size

                  # The variable carries repository:tag, so a deploy moves one value and the
                  # provider still gets the split fields it wants.
                  image {
                    registry_type = var.\(identifier)_registry_type
                    repository    = split(":", var.\(variable))[0]
                    tag           = try(split(":", var.\(variable))[1], "latest")
                  }

                  health_check {
                    http_path = "\(healthPath)"
                  }

                  # App Platform takes environment as repeated blocks rather than a map, so the
                  # same gitignored config file is expanded rather than passed through.
                  dynamic "env" {
                    for_each = jsondecode(file("${path.module}/\(service.configFile)"))
                    content {
                      key   = env.key
                      value = env.value
                      scope = "RUN_TIME"
                      type  = "SECRET"
                    }
                  }
                }

            """

        for domain in domains {
            body += """

                    domain {
                      name = "\(domain)"
                    }

                """
        }

        body += """
              }
            }

            output "\(identifier)_url" {
              description = "The live URL App Platform assigned to \(service.name)."
              value       = digitalocean_app.\(identifier).live_url
            }

            """

        return [
            GeneratedFile(path: "\(identifier).tf", contents: body, role: .declaration),
            GeneratedFile(
                path: "variables.tf",
                contents: """

                    variable "\(identifier)_instance_size" {
                      description = "Instance size slug for \(service.name)."
                      type        = string
                      default     = "basic-xxs"
                    }

                    variable "\(identifier)_instance_count" {
                      description = "How many instances of \(service.name) to run."
                      type        = number
                      default     = 1
                    }

                    variable "\(identifier)_registry_type" {
                      description = "Where the image lives: DOCKER_HUB, DOCR, or GHCR."
                      type        = string
                      default     = "DOCKER_HUB"
                    }
                    """,
                role: .variableAppend),
        ]
    }

    static let versions = """
        # Written by hatchery.
        terraform {
          required_version = ">= 1.5"

          required_providers {
            digitalocean = {
              source  = "digitalocean/digitalocean"
              version = "~> 2.0"
            }
          }
        }
        """

    static let providers = """
        # Written by hatchery.
        #
        # The token comes from DIGITALOCEAN_TOKEN in the environment, never from this file.
        # `hatchery doctor --backend appPlatform` checks that it resolves.
        provider "digitalocean" {}
        """

    static func variables(region: String) -> String {
        """
        # Written by hatchery. Per-service variables are appended below as services are added,
        # so keep this file rather than regenerating it.
        variable "do_region" {
          description = "Region the app runs in."
          type        = string
          default     = "\(region)"
        }
        """
    }

    static func identifier(_ name: String) -> String {
        let folded = String(
            name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        ).lowercased()
        return folded.first?.isNumber == true ? "app_" + folded : folded
    }
}

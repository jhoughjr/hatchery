import Foundation

/// Authors a Google Cloud Run service.
///
/// The closest sibling to App Runner: an image, an environment, a port and a health path, with
/// the URL assigned rather than declared. `google_cloud_run_v2_service` rather than the older
/// `google_cloud_run_service`, because v2 takes the container shape directly instead of through
/// a Knative-style annotation soup.
public struct CloudRunProvider: ServiceProvider {
    public init() {}

    public var backend: Backend { .cloudRun }
    public var displayName: String { "Google Cloud Run" }
    public var authorable: Bool { true }

    public var setupSteps: [SetupStep] { Onboarding.cloudRunSteps }

    public func readiness(
        host: String?, execute: @escaping CommandExecutor
    ) async -> [PreflightCheck] {
        await Preflight(execute: execute).google()
    }

    public func imageVariableName(for request: ScaffoldRequest) -> String? {
        request.service.imageVariable ?? "\(Self.identifier(request.service.name))_image"
    }

    public func imageVariable(for request: ScaffoldRequest) -> String? {
        guard let name = imageVariableName(for: request) else { return nil }
        return """

            variable "\(name)" {
              description = "Image for \(request.service.name). Cloud Run pulls from Artifact \
            Registry or GCR, so this is a full image path and tag."
              type        = string
              default     = "\(request.service.image)"
            }
            """
    }

    public var settings: [BackendSetting] {
        [
            BackendSetting(
                key: "project", label: "Project ID",
                help: "The Google Cloud project services are created in."),
            .region(default: "us-central1", help: "Region Cloud Run services are created in."),
        ]
    }

    public func bootstrapFiles(settings values: [String: String]) -> [GeneratedFile] {
        let resolved = settings.resolving(values)
        return [
            GeneratedFile(path: "versions.tf", contents: Self.versions, role: .declaration),
            GeneratedFile(path: "providers.tf", contents: Self.providers, role: .declaration),
            GeneratedFile(
                path: "variables.tf",
                contents: Self.variables(
                    region: resolved["region"] ?? "us-central1",
                    project: resolved["project"] ?? ""),
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

        // A stack with a Cloud SQL instance mounts it at /cloudsql, which is how a Cloud Run
        // service reaches Cloud SQL without a public address: the config's DATABASE_URL says
        // host=/cloudsql/<connection>, and this volume is what makes that path exist.
        let cluster = request.stack.settings?["db_cluster"] ?? ""
        let mount = cluster.isEmpty ? "" : """

                  volume_mounts {
                    name       = "cloudsql"
                    mount_path = "/cloudsql"
                  }
            """
        let volume = cluster.isEmpty ? "" : """

                volumes {
                  name = "cloudsql"
                  cloud_sql_instance {
                    instances = ["${var.gcp_project}:${var.gcp_region}:\(cluster)"]
                  }
                }
            """

        let body = """
            # \(service.kind.rawValue) service '\(service.name)', authored by hatchery.
            resource "google_cloud_run_v2_service" "\(identifier)" {
              name     = "\(service.name)"
              location = var.gcp_region

              template {
                containers {
                  image = var.\(variable)

                  ports {
                    container_port = \(request.containerPort)
                  }

                  # Cloud Run takes environment as repeated blocks rather than a map, so the
                  # same gitignored config file is expanded rather than passed through.
                  dynamic "env" {
                    for_each = jsondecode(file("${path.module}/\(service.configFile)"))
                    content {
                      name  = env.key
                      value = env.value
                    }
                  }

                  resources {
                    limits = {
                      cpu    = var.\(identifier)_cpu
                      memory = var.\(identifier)_memory
                    }
                  }\(mount)

                  # A startup probe rather than a liveness probe: a service that is slow to boot
                  # should be given time, not restarted in a loop.
                  startup_probe {
                    initial_delay_seconds = 5
                    period_seconds        = 10
                    failure_threshold     = 6

                    http_get {
                      path = "\(healthPath)"
                      port = \(request.containerPort)
                    }
                  }
                }

                scaling {
                  min_instance_count = var.\(identifier)_min_instances
                  max_instance_count = var.\(identifier)_max_instances
                }\(volume)
              }

              labels = {
                managed-by = "hatchery"
                stack      = "\(request.stack.name)"
              }
            }

            output "\(identifier)_url" {
              description = "The URL Cloud Run assigned to \(service.name)."
              value       = google_cloud_run_v2_service.\(identifier).uri
            }

            """

        return [
            GeneratedFile(path: "\(identifier).tf", contents: body, role: .declaration),
            GeneratedFile(
                path: "variables.tf",
                contents: """

                    variable "\(identifier)_cpu" {
                      description = "CPU limit for \(service.name)."
                      type        = string
                      default     = "1"
                    }

                    variable "\(identifier)_memory" {
                      description = "Memory limit for \(service.name)."
                      type        = string
                      default     = "512Mi"
                    }

                    variable "\(identifier)_min_instances" {
                      description = "Scale floor. Zero means it scales to nothing when idle."
                      type        = number
                      default     = 0
                    }

                    variable "\(identifier)_max_instances" {
                      description = "Scale ceiling for \(service.name)."
                      type        = number
                      default     = 2
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
            google = {
              source  = "hashicorp/google"
              version = "~> 5.0"
            }
          }
        }
        """

    static let providers = """
        # Written by hatchery.
        #
        # Credentials come from your gcloud application-default login or from
        # GOOGLE_APPLICATION_CREDENTIALS, never from this file.
        provider "google" {
          project = var.gcp_project
          region  = var.gcp_region
        }
        """

    static func variables(region: String, project: String = "") -> String {
        """
        # Written by hatchery. Per-service variables are appended below as services are added,
        # so keep this file rather than regenerating it.
        variable "gcp_project" {
          description = "Project the services run in."
          type        = string
          default     = "\(project)"
        }

        variable "gcp_region" {
          description = "Region the services run in."
          type        = string
          default     = "\(region)"
        }
        """
    }

    static func identifier(_ name: String) -> String {
        let folded = String(
            name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        ).lowercased()
        return folded.first?.isNumber == true ? "svc_" + folded : folded
    }
}

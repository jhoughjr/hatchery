import Foundation

/// Authors a `dokku_app` resource for the `aliksend/dokku` provider.
///
/// The generated shape follows the lab's hand-written declarations rather than the provider's
/// documentation, because the lab encodes two things the documentation does not: the config map
/// has to come from a file (the provider cannot take variables there — aliksend#94), and the app
/// has to join the shared docker network or it cannot reach its database.
public struct DokkuProvider: ServiceProvider {
    public init() {}

    public var backend: Backend { .dokku }

    public func imageVariableName(for request: ScaffoldRequest) -> String? {
        request.service.imageVariable ?? "\(Self.identifier(request.service.name))_image"
    }

    public func imageVariable(for request: ScaffoldRequest) -> String? {
        guard let name = imageVariableName(for: request) else { return nil }
        return """

            variable "\(name)" {
              description = "Docker image for the \(request.service.name) app, built on the \
            host for its architecture."
              type        = string
              default     = "\(request.service.image)"
            }
            """
    }

    public func declaration(for request: ScaffoldRequest) throws -> [GeneratedFile] {
        let service = request.service
        guard !service.domains.isEmpty else {
            throw ProviderError.missingDetail("at least one domain")
        }
        guard let variable = imageVariableName(for: request) else {
            throw ProviderError.missingDetail("an image variable")
        }

        let identifier = Self.identifier(service.name)
        let domains = service.domains.map { "    \"\($0)\"," }.joined(separator: "\n")

        var body = """
            # \(service.kind.rawValue) app '\(service.name)', authored by hatchery.
            resource "dokku_app" "\(identifier)" {

            """

        if request.gated {
            body += """
                  count = var.enable_\(identifier) ? 1 : 0

                """
        }

        body += """
              app_name = "\(service.name)"

              domains = [
            \(domains)
              ]

              ports = {
                "80" = {
                  scheme         = "http"
                  container_port = "\(request.containerPort)"
                }
              }

              # Zero-downtime checks are off, matching the rest of the lab.
              checks = {
                status = "disabled"
              }

            """

        if let network = request.network, !network.isEmpty {
            body += """

                  # Shared docker network with the database app — removing this cuts the app off
                  # from its database.
                  networks = {
                    attach_post_create = "\(network)"
                  }

                """
        }

        body += """

              # Loaded from a gitignored file rather than a variable: the provider cannot accept
              # variables in this map (aliksend/terraform-provider-dokku#94).
              config = sensitive(jsondecode(file("${path.module}/\(service.configFile)")))

              deploy = {
                type         = "docker_image"
                docker_image = var.\(variable)
              }
            }

            """

        var files = [GeneratedFile(path: "\(identifier).tf", contents: body, role: .declaration)]

        if request.gated {
            files.append(
                GeneratedFile(
                    path: "variables.tf",
                    contents: """

                        variable "enable_\(identifier)" {
                          description = "Create and deploy the \(service.name) app."
                          type        = bool
                          default     = true
                        }
                        """,
                    role: .variableAppend))
        }
        return files
    }

    /// A terraform identifier for a service name. Dokku app names allow characters that a
    /// resource label does not, so they are folded rather than passed through.
    static func identifier(_ name: String) -> String {
        let folded = name.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        let identifier = String(folded).lowercased()
        // A terraform identifier cannot lead with a digit.
        return identifier.first?.isNumber == true ? "app_" + identifier : identifier
    }
}

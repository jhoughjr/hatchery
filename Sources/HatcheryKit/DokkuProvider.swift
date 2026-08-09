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
    public var displayName: String { "Dokku (self-hosted)" }
    public var authorable: Bool { true }

    public var setupSteps: [SetupStep] { Onboarding.dokkuSteps }

    public func readiness(
        host: String?, execute: @escaping CommandExecutor
    ) async -> [PreflightCheck] {
        await Preflight(execute: execute).dokku(host: host)
    }

    public var settings: [BackendSetting] { [.sshHost, .sshKey, .dbAdmin] }

    public func bootstrapFiles(settings values: [String: String]) -> [GeneratedFile] {
        let resolved = settings.resolving(values)
        let host = resolved["host"] ?? ""
        let sshKeyPath = resolved["ssh_key"] ?? "~/.ssh/id_rsa"
        // The SSH user is stripped: the provider block supplies it separately.
        let address = host.split(separator: "@").last.map(String.init) ?? host
        return [
            GeneratedFile(path: "versions.tf", contents: Self.versions, role: .declaration),
            GeneratedFile(path: "providers.tf", contents: Self.providers, role: .declaration),
            GeneratedFile(
                path: "variables.tf",
                contents: Self.variables(host: address, sshKeyPath: sshKeyPath),
                role: .declaration),
        ]
    }

    static let versions = """
        # Written by hatchery.
        terraform {
          required_version = ">= 1.5"

          required_providers {
            dokku = {
              source  = "aliksend/dokku"
              version = "~> 1.0"
            }
          }
        }
        """

    static let providers = """
        # Written by hatchery.
        provider "dokku" {
          ssh_host = var.dokku_host
          ssh_user = "dokku"
          ssh_port = 22
          ssh_cert = var.ssh_key_path

          # The host key is not pinned. Pin it with ssh_host_key before this runs anywhere
          # but a network you control.
          ssh_skip_host_key_check = true
        }
        """

    static func variables(host: String, sshKeyPath: String) -> String {
        """
        # Written by hatchery. Per-service image variables are appended below as services
        # are added, so keep this file rather than regenerating it.
        variable "dokku_host" {
          description = "Dokku host to manage."
          type        = string
          default     = "\(host)"
        }

        variable "ssh_key_path" {
          description = "Private key authorized for the dokku user on the host."
          type        = string
          default     = "\(sshKeyPath)"
        }
        """
    }

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

    /// The account dokku commands must arrive as.
    ///
    /// Not a preference: `dokku` is not a shell account. Its authorized_keys entry wraps every
    /// command in dokku's own dispatcher, which is what turns `ssh <host> logs app` into a dokku
    /// command. Any other user either fails to authenticate or lands in a plain shell where
    /// `logs` means nothing.
    public static let sshUser = "dokku"

    /// The SSH target to actually use for a host as someone wrote it.
    ///
    /// A bare address is the whole bug this exists for: `ssh 192.168.0.103` falls back to the
    /// *local* login, so it arrives as `jimmyhoughjr@…`, fails on publickey, and the failure
    /// reads as a missing key rather than as the wrong user.
    public static func sshTarget(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        guard trimmed.contains("@") else { return "\(sshUser)@\(trimmed)" }
        return trimmed
    }

    /// Whether a target names a user that cannot work, and what to say about it.
    ///
    /// An explicit wrong user is left alone rather than rewritten — silently changing what
    /// someone typed would hide the mistake instead of correcting it.
    public static func userWarning(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard let user = trimmed.split(separator: "@").first, trimmed.contains("@") else {
            return nil
        }
        guard String(user) != sshUser else { return nil }
        return """
            '\(user)' is not the dokku account. Dokku commands must arrive as \
            \(sshUser)@\(trimmed.split(separator: "@").last.map(String.init) ?? "<host>"); any \
            other user lands in a plain shell where dokku commands mean nothing.
            """
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

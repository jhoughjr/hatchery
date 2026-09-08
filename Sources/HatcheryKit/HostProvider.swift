import Foundation

/// Authors a `docker_container` for the `kreuzwerker/docker` provider, on a box reached over ssh.
///
/// This is the plane for the containers dokku does not own. Dokku's provider can only speak about apps dokku
/// made, so a dnsmasq, a Postgres cluster or a CI runner on the same box answers to no declaration at all.
/// The docker provider drives the same daemon dokku drives, through `ssh://user@host`, and declares those
/// containers as themselves.
public struct HostProvider: ServiceProvider {
    public init() {}

    public var backend: Backend { .host }
    public var displayName: String { "Docker on a box (self-hosted)" }
    public var authorable: Bool { true }

    public var setupSteps: [SetupStep] { Onboarding.hostSteps }

    public func readiness(
        host: String?, execute: @escaping CommandExecutor
    ) async -> [PreflightCheck] {
        await Preflight(execute: execute).host(host: host)
    }

    public var settings: [BackendSetting] {
        [.boxHost, .boxKey]
    }

    /// A container's image is a field of its own declaration, not a variable a deploy moves.
    ///
    /// Nothing deploys a bare container: the box runs the image the declaration names, and changing it is a
    /// change to the declaration. Answering `nil` here is what tells the scaffolder there is no variable.
    public func imageVariableName(for request: ScaffoldRequest) -> String? { nil }

    public func imageVariable(for request: ScaffoldRequest) -> String? { nil }

    public func bootstrapFiles(settings values: [String: String]) -> [GeneratedFile] {
        let resolved = settings.resolving(values)
        let host = resolved["host"] ?? ""
        let sshKeyPath = resolved["ssh_key"] ?? "~/.ssh/id_rsa"
        return [
            GeneratedFile(path: "versions.tf", contents: Self.versions, role: .declaration),
            GeneratedFile(
                path: "providers.tf",
                contents: Self.providers(host: host, sshKeyPath: sshKeyPath),
                role: .declaration),
        ]
    }

    static let versions = """
        # Written by hatchery.
        terraform {
          required_version = ">= 1.5"

          required_providers {
            docker = {
              source  = "kreuzwerker/docker"
              version = "~> 3.0"
            }
          }
        }
        """

    /// The provider block, with the ssh target written in rather than carried by a variable.
    ///
    /// The docker provider takes its whole address as one string, so a variable would only move the same
    /// literal one file away. The key travels in `ssh_opts`, which is the provider's only door for it.
    static func providers(host: String, sshKeyPath: String) -> String {
        """
        # Written by hatchery.
        provider "docker" {
          host = "ssh://\(host)"

          # BatchMode stops an unreachable box from hanging a plan on a password prompt.
          ssh_opts = ["-i", "\(sshKeyPath)", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        }
        """
    }

    public func declaration(for request: ScaffoldRequest) throws -> [GeneratedFile] {
        let service = request.service
        // A service scaffolded rather than adopted knows only its image. That is enough to declare a
        // container: everything else in the spec has a working default, and adopt supplies the rest.
        let container = service.container ?? ContainerSpec(image: service.image)

        // The same folding the dokku provider uses, through the one door ScanKit's
        // `tofuIdentifier(for:)` also calls, so a name folds to one identifier everywhere.
        let identifier = DokkuProvider.identifier(service.name)
        var body = """
            # container '\(service.name)', authored by hatchery.
            resource "docker_image" "\(identifier)" {
              name = "\(container.image)"

              # An adopted container's image is already on the box, and a scaffolded one needs a pull.
              # keep_locally stops a destroy from deleting an image other containers share.
              keep_locally = true
            }

            resource "docker_container" "\(identifier)" {
              name  = "\(service.name)"
              image = docker_image.\(identifier).image_id

              restart = "\(container.restart)"

            """

        if container.privileged {
            body += """

                  privileged = true

                """
        }

        if let command = container.command, !command.isEmpty {
            let items = command.map { "\"\(Self.escaped($0))\"" }.joined(separator: ", ")
            body += """

                  command = [\(items)]

                """
        }

        body += Self.networkBlock(container.network)
        body += Self.portBlocks(container.ports)
        body += Self.volumeBlocks(container.mounts)
        body += Self.hostBlocks(container.extraHosts)
        body += Self.environmentBlock(for: service)

        body += """
            }

            """

        if let containerID = request.containerID, !containerID.isEmpty {
            // Without this tofu plans to create a container that is already running, and the apply
            // fails on the name it is holding. The import binds the declaration to what is there.
            body += """

                import {
                  to = docker_container.\(identifier)
                  id = "\(containerID)"
                }

                """
        }

        return [GeneratedFile(path: "\(identifier).tf", contents: body, role: .declaration)]
    }

    // MARK: - The blocks of a container resource

    /// `host` and `bridge` are daemon modes and go in `network_mode`.
    /// A named network is a resource of its own, and the provider attaches it through `networks_advanced`.
    static func networkBlock(_ network: String?) -> String {
        guard let network, !network.isEmpty else { return "" }
        if ["host", "bridge", "none"].contains(network) {
            return """

                  network_mode = "\(network)"

                """
        }
        return """

              networks_advanced {
                name = "\(network)"
              }

            """
    }

    static func portBlocks(_ ports: [ContainerSpec.PortMap]) -> String {
        ports.map { port in
            """

              ports {
                internal = \(port.container)
                external = \(port.host)
                protocol = "\(port.protocol)"
              }

            """
        }.joined()
    }

    /// A source that starts with `/` is a path on the box, and anything else is the name of a docker volume.
    /// The provider takes the two through different attributes, so the difference has to be read here.
    static func volumeBlocks(_ mounts: [ContainerSpec.Mount]) -> String {
        mounts.map { mount in
            let source = mount.source.hasPrefix("/")
                ? "    host_path      = \"\(Self.escaped(mount.source))\""
                : "    volume_name    = \"\(Self.escaped(mount.source))\""
            return """

                  volumes {
                \(source)
                    container_path = "\(Self.escaped(mount.target))"
                    read_only      = \(mount.readOnly)
                  }

                """
        }.joined()
    }

    /// `--add-host name:address` becomes one `host` block per entry.
    /// An entry without a colon is dropped, because a name with no address resolves to nothing.
    static func hostBlocks(_ extraHosts: [String]) -> String {
        extraHosts.compactMap { entry -> String? in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return """

                  host {
                    host = "\(parts[0])"
                    ip   = "\(parts[1])"
                  }

                """
        }.joined()
    }

    /// The environment, read from the same gitignored sidecar and secrets file every service uses.
    ///
    /// `docker_container` takes a list of `KEY=value` strings rather than a map, so the merged map is turned
    /// into one by a comprehension. The secrets file may not exist yet, so the merge only reads it when
    /// fileexists says it is there.
    static func environmentBlock(for service: ServiceSpec) -> String {
        let merged: String
        if let secretsName = service.secretsFile ?? service.conventionalSecretsFile {
            merged = """
                merge(jsondecode(file("${path.module}/\(service.configFile)")), fileexists("${path.module}/\(secretsName)") ? jsondecode(file("${path.module}/\(secretsName)")) : {})
                """
        } else {
            merged = "jsondecode(file(\"${path.module}/\(service.configFile)\"))"
        }
        return """

              env = sensitive([
                for key, value in \(merged) : "${key}=${value}"
              ])

            """
    }

    /// A backslash or a quote inside a generated string would end the HCL string early.
    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

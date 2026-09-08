import Foundation
import Testing

@testable import HatcheryKit

private func hostStack() -> StackSpec {
    StackSpec(
        name: "box", backend: .host, environment: .prod, host: "jimmy@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/box"), services: [])
}

/// dnsmasq as the box actually runs it: the host network, one read-only bind, and no published port.
private func lanDNS() -> ServiceSpec {
    ServiceSpec(
        name: "lan-dns", kind: .container, image: "4km3/dnsmasq:latest",
        configFile: "lan-dns.config.json",
        container: ContainerSpec(
            image: "4km3/dnsmasq:latest",
            network: "host",
            mounts: [
                ContainerSpec.Mount(
                    source: "/home/jimmy/lan-dns/dnsmasq.conf", target: "/etc/dnsmasq.conf",
                    readOnly: true)
            ],
            restart: "unless-stopped"))
}

/// The rookery cluster as the box actually runs it: its own network, a named volume, and a published port.
private func rookeryPG() -> ServiceSpec {
    ServiceSpec(
        name: "rookery-pg", kind: .container, image: "postgres:17-alpine",
        configFile: "rookery-pg.config.json",
        container: ContainerSpec(
            image: "postgres:17-alpine",
            network: "rookery_default",
            mounts: [
                ContainerSpec.Mount(
                    source: "rookery-pg-data", target: "/var/lib/postgresql/data")
            ],
            ports: [ContainerSpec.PortMap(host: 5433, container: 5432)],
            restart: "unless-stopped",
            command: ["postgres"]))
}

@Suite("The host backend: a container declared as itself")
struct HostProviderTests {
    @Test("a manifest with a container service reads back exactly as it was written")
    func containerRoundTrip() throws {
        var stack = hostStack()
        stack.services = [lanDNS(), rookeryPG()]
        let manifest = StackManifest(version: 1, stacks: [stack])

        let decoded = try StackManifest.decode(from: try manifest.encoded())
        #expect(decoded == manifest)
        #expect(decoded.stacks[0].services[0].container?.network == "host")
        #expect(decoded.stacks[0].services[1].container?.ports.first?.protocol == "tcp")
    }

    @Test("a service with no container carries no container field into the manifest")
    func containerOmittedWhenAbsent() throws {
        let stack = StackSpec(
            name: "lab", backend: .dokku, host: "dokku@192.168.0.103",
            services: [
                ServiceSpec(
                    name: "mwlab", kind: .mwserver, image: "dokku/mwlab:latest",
                    configFile: "mwlab.config.json")
            ])
        let json = String(
            decoding: try StackManifest(version: 1, stacks: [stack]).encoded(), as: UTF8.self)
        #expect(!json.contains("container"))
    }

    @Test("the container kind is offered as a kind but ships no built-in contract")
    func containerKindIsUnknownByDesign() {
        #expect(ServiceKind.all.contains(.container))
        #expect(!ServiceKind.known.contains(.container))
        #expect(EnvContract.contract(for: .container, backend: .host) == nil)
    }

    @Test("the bootstrap declares the docker provider and reaches the daemon over ssh")
    func bootstrapProviders() throws {
        let files = HostProvider().bootstrapFiles(
            settings: ["host": "jimmy@192.168.0.103", "ssh_key": "~/.ssh/id_ed25519"])
        #expect(files.map(\.path) == ["versions.tf", "providers.tf"])

        let versions = try #require(files.first { $0.path == "versions.tf" })
        #expect(versions.contents == """
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
            """)

        let providers = try #require(files.first { $0.path == "providers.tf" })
        #expect(providers.contents == """
            # Written by hatchery.
            provider "docker" {
              host = "ssh://jimmy@192.168.0.103"

              # BatchMode stops an unreachable box from hanging a plan on a password prompt.
              ssh_opts = ["-i", "~/.ssh/id_ed25519", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
            }
            """)
    }

    @Test("a host-network container with one bind mount declares as the box runs it")
    func lanDNSDeclaration() throws {
        let files = try HostProvider().declaration(
            for: ScaffoldRequest(stack: hostStack(), service: lanDNS()))
        let tf = try #require(files.first { $0.role == .declaration })

        #expect(tf.path == "lan_dns.tf")
        #expect(tf.contents == """
            # container 'lan-dns', authored by hatchery.
            resource "docker_image" "lan_dns" {
              name = "4km3/dnsmasq:latest"

              # An adopted container's image is already on the box, and a scaffolded one needs a pull.
              # keep_locally stops a destroy from deleting an image other containers share.
              keep_locally = true
            }

            resource "docker_container" "lan_dns" {
              name  = "lan-dns"
              image = docker_image.lan_dns.image_id

              restart = "unless-stopped"

              network_mode = "host"

              volumes {
                host_path      = "/home/jimmy/lan-dns/dnsmasq.conf"
                container_path = "/etc/dnsmasq.conf"
                read_only      = true
              }

              env = sensitive([
                for key, value in merge(jsondecode(file("${path.module}/lan-dns.config.json")), fileexists("${path.module}/lan-dns.secrets.json") ? jsondecode(file("${path.module}/lan-dns.secrets.json")) : {}) : "${key}=${value}"
              ])
            }

            """)
    }

    @Test("a container on a named network with a volume and a published port declares as the box runs it")
    func rookeryDeclaration() throws {
        let files = try HostProvider().declaration(
            for: ScaffoldRequest(stack: hostStack(), service: rookeryPG()))
        let tf = try #require(files.first { $0.role == .declaration })

        #expect(tf.path == "rookery_pg.tf")
        #expect(tf.contents == """
            # container 'rookery-pg', authored by hatchery.
            resource "docker_image" "rookery_pg" {
              name = "postgres:17-alpine"

              # An adopted container's image is already on the box, and a scaffolded one needs a pull.
              # keep_locally stops a destroy from deleting an image other containers share.
              keep_locally = true
            }

            resource "docker_container" "rookery_pg" {
              name  = "rookery-pg"
              image = docker_image.rookery_pg.image_id

              restart = "unless-stopped"

              command = ["postgres"]

              networks_advanced {
                name = "rookery_default"
              }

              ports {
                internal = 5432
                external = 5433
                protocol = "tcp"
              }

              volumes {
                volume_name    = "rookery-pg-data"
                container_path = "/var/lib/postgresql/data"
                read_only      = false
              }

              env = sensitive([
                for key, value in merge(jsondecode(file("${path.module}/rookery-pg.config.json")), fileexists("${path.module}/rookery-pg.secrets.json") ? jsondecode(file("${path.module}/rookery-pg.secrets.json")) : {}) : "${key}=${value}"
              ])
            }

            """)
    }

    @Test("adopting adds the import block, so tofu binds to the container instead of creating one")
    func importBlockWhenAdopting() throws {
        let files = try HostProvider().declaration(
            for: ScaffoldRequest(
                stack: hostStack(), service: lanDNS(),
                containerID: "8f3c1a2b4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8"))
        let tf = try #require(files.first { $0.role == .declaration })

        #expect(tf.contents.hasSuffix("""

            import {
              to = docker_container.lan_dns
              id = "8f3c1a2b4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8"
            }

            """))
    }

    @Test("a privileged container with extra hosts carries both, and a bare service declares from its image")
    func privilegedAndExtraHosts() throws {
        var service = lanDNS()
        service.container?.privileged = true
        service.container?.extraHosts = ["opi:192.168.0.103", "malformed"]
        let files = try HostProvider().declaration(
            for: ScaffoldRequest(stack: hostStack(), service: service))
        let tf = try #require(files.first { $0.role == .declaration })

        #expect(tf.contents.contains("  privileged = true\n"))
        #expect(tf.contents.contains("""
              host {
                host = "opi"
                ip   = "192.168.0.103"
              }
            """))
        // An entry with no address names a host that resolves to nothing, so it is dropped.
        #expect(!tf.contents.contains("malformed"))

        // A scaffolded service knows only its image, and that is enough to declare a container.
        var bare = lanDNS()
        bare.container = nil
        let scaffolded = try HostProvider().declaration(
            for: ScaffoldRequest(stack: hostStack(), service: bare))
        let bareTF = try #require(scaffolded.first { $0.role == .declaration })
        #expect(bareTF.contents.contains("name = \"4km3/dnsmasq:latest\""))
        #expect(bareTF.contents.contains("restart = \"unless-stopped\""))
        #expect(!bareTF.contents.contains("network_mode"))
    }

    @Test("the backend declares the two things it needs, and answers for itself")
    func backendSurface() {
        let provider = HostProvider()
        #expect(provider.backend == .host)
        #expect(provider.authorable)
        #expect(provider.settings.map(\.key) == ["host", "ssh_key"])
        #expect(provider.imageVariableName(for: ScaffoldRequest(stack: hostStack(), service: lanDNS())) == nil)
        #expect(Providers.support(for: .host).backend == .host)
        #expect(Backend.host.isSelfHosted)
    }
}

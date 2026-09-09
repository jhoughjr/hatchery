import Foundation
import Testing

@testable import HatcheryKit

/// A `docker inspect` answer recorded off the opi on 2026-09-08, read only.
///
/// The fixtures are the real bytes rather than a hand-written sample, because the shape of that document is
/// the whole thing under test and a sample would only prove the sample.
func recordedInspection(_ name: String) throws -> Data {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    return try Data(contentsOf: fixtures.appendingPathComponent(name))
}

@Suite("Reading a container off the box")
struct ContainerInspectionTests {
    @Test("dnsmasq on the host network reads into the spec the box runs it with")
    func readsLANDNS() throws {
        let read = try ContainerInspection.decode(
            try recordedInspection("lan-dns.inspect.json"))

        #expect(read.id == "4af81f8ff62f65b98eddd6157dcf1d44ad01e4e3f048ba606ba86856287997b2")
        #expect(read.name == "lan-dns")
        #expect(read.image == "4km3/dnsmasq:latest")
        #expect(read.state == "running")
        #expect(read.running)
        #expect(read.health == nil)
        #expect(!read.hasHealthcheck)

        #expect(read.spec == ContainerSpec(
            image: "4km3/dnsmasq:latest",
            network: "host",
            mounts: [
                ContainerSpec.Mount(
                    source: "/home/jimmy/lan-dns/dnsmasq.conf", target: "/etc/dnsmasq.conf",
                    readOnly: true)
            ],
            ports: [],
            restart: "unless-stopped",
            command: nil,
            privileged: false,
            extraHosts: []))

        // The entrypoint is the image's own, and a declaration that named no command keeps it.
        #expect(read.environment == ["PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"])
    }

    @Test("a Postgres cluster on its own network reads its volume, its published port and its command")
    func readsRookeryPG() throws {
        let read = try ContainerInspection.decode(
            try recordedInspection("rookery-pg.inspect.json"))

        #expect(read.id == "67f94c78942b33493ab54043f3d8f65bb98006f6bdda18fb457ac383e12ad645")
        #expect(read.name == "rookery-pg")
        #expect(read.spec == ContainerSpec(
            image: "postgres:17-alpine",
            network: "rookery_default",
            mounts: [
                ContainerSpec.Mount(
                    source: "rookery-pg-data", target: "/var/lib/postgresql/data", readOnly: false)
            ],
            ports: [ContainerSpec.PortMap(host: 5433, container: 5432, protocol: "tcp")],
            restart: "unless-stopped",
            command: ["postgres"],
            privileged: false,
            extraHosts: []))

        #expect(read.environment["PGDATA"] == "/var/lib/postgresql/data")
        #expect(read.environment["PG_MAJOR"] == "17")
        #expect(read.environment.count == 8)
    }

    @Test("the declaration the box's own bytes produce is the one hatchery would have written")
    func declaresWhatItRead() throws {
        let read = try ContainerInspection.decode(
            try recordedInspection("rookery-pg.inspect.json"))
        let service = ServiceSpec(
            name: read.name, kind: .container, image: read.image,
            configFile: "rookery-pg.config.json", container: read.spec)
        let stack = StackSpec(
            name: "box", backend: .host, host: "jimmy@192.168.0.103",
            tofu: TofuBinding(directory: "/infra/box"))

        let files = try HostProvider().declaration(
            for: ScaffoldRequest(stack: stack, service: service, containerID: read.id))
        let tf = try #require(files.first)

        #expect(tf.contents.contains("volume_name    = \"rookery-pg-data\""))
        #expect(tf.contents.contains("external = 5433"))
        #expect(tf.contents.contains("name = \"rookery_default\""))
        #expect(tf.contents.contains("""
            import {
              to = docker_container.rookery_pg
              id = "67f94c78942b33493ab54043f3d8f65bb98006f6bdda18fb457ac383e12ad645"
            }
            """))
    }

    @Test("the sidecar records what the run adds to the image, and not what the image already set")
    func dropsTheImagesOwnEnvironment() throws {
        let read = try ContainerInspection.decode(
            try recordedInspection("rookery-pg.inspect.json"))
        let image = try ContainerInspection.imageEnvironment(
            try recordedInspection("postgres-17-alpine.image-env.json"))

        // Every one of the eight keys rookery-pg runs with is the image's own, so the sidecar is empty.
        #expect(read.environment.count == 8)
        #expect(image.count == 8)
        #expect(read.declaredEnvironment(against: image).isEmpty)

        // A -e flag that overrides the image's value is a declaration, and it stays.
        var overridden = read.environment
        overridden["PGDATA"] = "/mnt/pgdata"
        let run = ContainerInspection(
            id: read.id, name: read.name, image: read.image, state: read.state,
            running: read.running, environment: overridden, spec: read.spec)
        #expect(run.declaredEnvironment(against: image) == ["PGDATA": "/mnt/pgdata"])

        // A key the kind file's contract names stays, whatever the image says about it.
        let contract = EnvContract(required: ["PGDATA"], secret: ["PG_SHA256"])
        #expect(
            read.declaredEnvironment(against: image, contract: contract)
                == [
                    "PGDATA": "/var/lib/postgresql/data",
                    "PG_SHA256":
                        "078a03516dcdbdb705fecaf415ea3d13a956c589e46f09fed68a06fb00598c90",
                ])

        // A key the contract only ignores is the platform's, so it drops with the rest of the image's.
        let ignoring = EnvContract(ignored: ["PGDATA"], ignoredPrefixes: ["PG_"])
        #expect(read.declaredEnvironment(against: image, contract: ignoring).isEmpty)
    }

    @Test("an answer that is not the image's environment is refused")
    func refusesWhatIsNotAnImageEnvironment() {
        #expect(throws: ContainerInspectionError.self) {
            try ContainerInspection.imageEnvironment(Data("{}".utf8))
        }
        #expect(throws: ContainerInspectionError.self) {
            try ContainerInspection.imageEnvironment(Data("not json".utf8))
        }
    }

    @Test("a name dokku or buildx made is not a container this backend declares")
    func namesOtherDeclarationsOwn() {
        #expect(ContainerNames.isDokku("mwlab-2-paylab.web.1"))
        #expect(ContainerNames.isDokku("rookery.runner.1"))
        #expect(!ContainerNames.isDokku("lan-dns"))
        #expect(!ContainerNames.isDokku("mwstack-pg-dev"))
        #expect(!ContainerNames.isDokku("mwserver-temporal"))

        #expect(ContainerNames.isBuildkitBuilder("buildx_buildkit_mwserver-builder0"))
        #expect(!ContainerNames.isBuildkitBuilder("act_runner"))

        for name in ["lan-dns", "homeassistant", "act_runner", "mwserver-temporal", "rookery-pg"] {
            #expect(ContainerNames.isDeclarable(name), "\(name) should be declarable")
        }
        for name in ["coop.web.1", "buildx_buildkit_builder-51d814da0"] {
            #expect(!ContainerNames.isDeclarable(name), "\(name) should not be declarable")
        }
    }

    @Test("an answer with no container, and one that is not a container, are both refused")
    func refusesWhatIsNotAContainer() {
        #expect(throws: ContainerInspectionError.self) {
            try ContainerInspection.decode(Data("[]".utf8))
        }
        #expect(throws: ContainerInspectionError.self) {
            try ContainerInspection.decode(Data("not json".utf8))
        }
        #expect(throws: ContainerInspectionError.self) {
            try ContainerInspection.decode(Data("[{\"Id\":\"x\"}]".utf8))
        }
    }

    @Test("a value holding an equals sign keeps it, and the daemon's default network is left unnamed")
    func parsingEdges() {
        #expect(
            ContainerInspection.environment(["DATABASE_URL=postgres://u:p@h/db?a=b", "EMPTY="])
                == ["DATABASE_URL": "postgres://u:p@h/db?a=b", "EMPTY": ""])
        #expect(ContainerInspection.network("default") == nil)
        #expect(ContainerInspection.network("") == nil)
        #expect(ContainerInspection.network("bridge") == "bridge")
    }
}

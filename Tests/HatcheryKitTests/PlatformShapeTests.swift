import Foundation
import Testing

@testable import HatcheryKit

@Suite("Addresses on a platform that has no box network")
struct PlatformShapeTests {
    private let source = StackSpec(
        name: "mwlab", backend: .dokku, host: "dokku@192.168.0.103",
        services: [
            ServiceSpec(name: "mwlab", kind: .mwserver, image: "x", domains: ["mwlab.opi", "mwlab.jimmyhoughjr.net"], configFile: "a"),
            ServiceSpec(name: "paylab", kind: .paymentGateway, image: "x", domains: ["paylab.opi", "paylab.jimmyhoughjr.net"], configFile: "b"),
        ])
    private let siblingDomains = [
        "mwlab": ["mwcloud.jimmyhoughjr.net"], "paylab": ["mwcloud-paylab.jimmyhoughjr.net"],
    ]
    private let siblingNames = ["mwlab": "mwcloud", "paylab": "mwcloud-paylab"]

    @Test("a sibling's dokku address becomes its public domain, one app per service")
    func siblingByDomain() {
        let out = PlatformShape.rewrite(
            "http://paylab.web.1:8080", source: source, layout: .appPerService,
            siblingDomains: siblingDomains)
        #expect(out == .sibling("https://mwcloud-paylab.jimmyhoughjr.net"))
    }

    @Test("a sibling's dokku address becomes its component on the private network, in one app")
    func siblingByComponent() {
        let out = PlatformShape.rewrite(
            "http://paylab.web.1:8080", source: source, layout: .components,
            siblingDomains: siblingDomains, siblingNames: siblingNames)
        #expect(out == .sibling("http://mwcloud-paylab:8080"))
    }

    @Test("a box-local host with no sibling behind it is refused, and a public host is left alone")
    func boxLocalAndPublic() {
        #expect(
            PlatformShape.rewrite("mwserver-temporal:7233", source: source, layout: .appPerService, siblingDomains: [:])
                == .boxLocal(host: "mwserver-temporal"))
        #expect(PlatformShape.rewrite("https://api.stripe.com/v1", source: source, layout: .appPerService, siblingDomains: [:]) == nil)
        #expect(PlatformShape.rewrite("info", source: source, layout: .appPerService, siblingDomains: [:]) == nil)
        #expect(PlatformShape.rewrite("mwserver-dev", source: source, layout: .appPerService, siblingDomains: [:]) == nil)
    }

    @Test("a sibling with no public domain cannot be reached, and says so")
    func siblingWithoutDomain() {
        let out = PlatformShape.rewrite(
            "http://paylab.web.1:8080", source: source, layout: .appPerService,
            siblingDomains: ["paylab": []])
        #expect(out == .boxLocal(host: "paylab.web.1"))
    }

    @Test("box-local domains drop off a platform clone")
    func publicDomains() {
        #expect(PlatformShape.publicDomains(["mwcloud.opi", "mwcloud.jimmyhoughjr.net", "box"]) == ["mwcloud.jimmyhoughjr.net"])
    }

    @Test("a platform-bound clone rewrites siblings and refuses box-local hosts, a dokku clone does neither")
    func throughTheCloner() async throws {
        let config = [
            "APP_URL": "https://mwlab.jimmyhoughjr.net",
            "PAYMENT_GATEWAY_URL": "http://paylab.web.1:8080",
            "TEMPORAL_ADDRESS": "mwserver-temporal:7233",
        ]
        let service = source.services[0]
        let platform = try await StackCloner().plan(
            service: service, from: source, into: "mwcloud", environment: Environment(rawValue: "staging"),
            sourceConfig: config, domains: ["mwcloud.opi", "mwcloud.jimmyhoughjr.net"],
            targetBackend: .appPlatform, cluster: "mws-pg")
        let byKey = Dictionary(uniqueKeysWithValues: platform.keys.map { ($0.key, $0) })
        #expect(platform.domains == ["mwcloud.jimmyhoughjr.net"])
        #expect(byKey["PAYMENT_GATEWAY_URL"]?.value == "https://mwcloud-paylab.jimmyhoughjr.net")
        if case .refused(let reason)? = byKey["TEMPORAL_ADDRESS"]?.disposition {
            #expect(reason.contains("mwserver-temporal"))
        } else {
            Issue.record("TEMPORAL_ADDRESS should be refused on a platform clone")
        }

        let dokku = try await StackCloner().plan(
            service: service, from: source, into: "mwlab-2", environment: Environment(rawValue: "dev"),
            sourceConfig: config, domains: ["mwlab-2.opi"])
        let dokkuByKey = Dictionary(uniqueKeysWithValues: dokku.keys.map { ($0.key, $0) })
        #expect(dokku.domains == ["mwlab-2.opi"])
        #expect(dokkuByKey["PAYMENT_GATEWAY_URL"]?.value == "http://mwlab-2-paylab.web.1:8080")
        #expect(dokkuByKey["TEMPORAL_ADDRESS"]?.value == "mwserver-temporal:7233")
    }
}

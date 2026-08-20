import Testing

@testable import HatcheryKit

@Suite("What a plan will cost, said before the create")
struct PlatformCostTests {
    @Test("a platform clone prices its apps, notes free databases, and totals")
    func pricesPlatform() {
        let lines = PlatformCost.lines(
            backend: .appPlatform, services: 3, managedDatabases: 2, cluster: "mws-pg")
        #expect(lines.count == 3)
        #expect(lines[0].text == "3 app(s) at basic-xxs, $5/mo each: $15/mo")
        #expect(lines[1].text == "2 database(s) in the existing cluster mws-pg: no added charge")
        #expect(lines[2].monthlyUSD == 15)
        #expect(lines[2].text.hasPrefix("about $15/mo in total"))
    }

    @Test("a self-hosted clone bills nothing per app, and an unknown size is said to be unpriced")
    func dokkuAndUnknown() {
        #expect(PlatformCost.lines(backend: .dokku, services: 3).isEmpty)
        let unknown = PlatformCost.lines(backend: .appPlatform, services: 1, size: "mega-xl")
        #expect(unknown[0].text.contains("a size this table does not price"))
        #expect(unknown.last?.monthlyUSD == 0)
    }
}

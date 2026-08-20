import Foundation

/// One line of what a plan will cost per month, as the platform lists it.
public struct CostLine: Sendable, Equatable {
    public let text: String
    public let monthlyUSD: Double

    public init(text: String, monthlyUSD: Double) {
        self.text = text
        self.monthlyUSD = monthlyUSD
    }
}

/// What a platform bills for what a plan is about to create.
///
/// Money is a plan-visible consequence, the same as an unreachable database server: a
/// clone onto App Platform bills per app from the moment it exists, and the plan says so
/// before the create. The table is the platform's list price at the date it names, and
/// the console is the authority when they disagree. A self-hosted backend bills nothing
/// per app, so it gets no lines.
public enum PlatformCost {
    public static let tableDate = "2026-08"

    /// App Platform instance sizes, USD per instance per month.
    static let appPlatformSizes: [String: Double] = [
        "basic-xxs": 5, "basic-xs": 10, "basic-s": 20, "basic-m": 40,
        "professional-xs": 12, "professional-s": 25, "professional-m": 50,
        "professional-l": 100, "professional-xl": 200,
    ]

    /// The size the provider's declaration defaults to.
    public static let appPlatformDefaultSize = "basic-xxs"

    public static func lines(
        backend: Backend, services: Int, size: String = appPlatformDefaultSize,
        instances: Int = 1, managedDatabases: Int = 0, cluster: String? = nil
    ) -> [CostLine] {
        guard backend == .appPlatform, services > 0 else { return [] }
        var lines: [CostLine] = []
        if let each = appPlatformSizes[size] {
            let total = each * Double(services * instances)
            let count = instances == 1 ? "\(services) app(s)" : "\(services) app(s) × \(instances) instance(s)"
            lines.append(
                CostLine(
                    text: "\(count) at \(size), \(dollars(each))/mo each: \(dollars(total))/mo",
                    monthlyUSD: total))
        } else {
            lines.append(
                CostLine(
                    text: "\(services) app(s) at \(size), a size this table does not price",
                    monthlyUSD: 0))
        }
        if managedDatabases > 0 {
            let where_ = cluster.map { " in the existing cluster \($0)" } ?? " in the existing cluster"
            lines.append(
                CostLine(
                    text: "\(managedDatabases) database(s)\(where_): no added charge",
                    monthlyUSD: 0))
        }
        let total = lines.reduce(0) { $0 + $1.monthlyUSD }
        lines.append(
            CostLine(
                text: "about \(dollars(total))/mo in total, App Platform list prices as of "
                    + "\(tableDate); the console is the authority",
                monthlyUSD: total))
        return lines
    }

    static func dollars(_ amount: Double) -> String {
        amount == amount.rounded() ? "$\(Int(amount))" : String(format: "$%.2f", amount)
    }
}

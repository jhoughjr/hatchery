import Foundation

/// What will happen to one domain's reachability, said before anything is created.
///
/// A stack that runs but cannot be reached is rehearsing. These lines sit on the plan
/// screen beside the database lines, because a front door is as much a part of a clone as
/// its data — and a domain that will resolve nowhere deserves to say so before the create
/// click, not after the health poll.
public struct ExposurePlan: Sendable, Equatable {
    public let domain: String
    /// One sentence: what exposing this domain would do, or why nothing can be done.
    public let action: String
    /// False when the provider's grant is missing — the line still shows, the promise
    /// does not get made.
    public let actionable: Bool

    public init(domain: String, action: String, actionable: Bool) {
        self.domain = domain
        self.action = action
        self.actionable = actionable
    }
}

/// How a stack's domains become reachable — provider-shaped, because a Cloudflare tunnel,
/// a LAN resolver, and a platform's own domains are different machines with different
/// capabilities and different grants. Full design: docs/exposure-design.md.
public protocol ExposureProvider: Sendable {
    /// The name the `exposure` stack setting selects.
    var name: String { get }
    /// What would happen to each domain. Never acts; the plan screen is the audience.
    func plan(domains: [String], stack: StackSpec) async -> [ExposurePlan]
}

/// Today's reality, said out loud: nothing manages exposure until a provider is chosen.
public struct NoExposure: ExposureProvider {
    public init() {}
    public var name: String { "none" }

    public func plan(domains: [String], stack: StackSpec) async -> [ExposurePlan] {
        domains.map {
            ExposurePlan(
                domain: $0,
                action: "will not resolve anywhere — no exposure provider is configured "
                    + "for this stack (set `exposure` in its settings)",
                actionable: false)
        }
    }
}

/// Backends whose platform assigns and routes domains itself. The provider exists so the
/// plan screen stays uniform instead of special-casing cloud backends into silence.
public struct PlatformExposure: ExposureProvider {
    public init() {}
    public var name: String { "platform" }

    public func plan(domains: [String], stack: StackSpec) async -> [ExposurePlan] {
        domains.map {
            ExposurePlan(
                domain: $0,
                action: "routed by \(stack.backend.rawValue) — the platform owns its domains",
                actionable: true)
        }
    }
}

/// Resolves the provider a stack selected.
public enum Exposure {
    /// The `exposure` stack setting; absent means platform-managed backends expose
    /// themselves and everything else honestly does nothing.
    public static func provider(for stack: StackSpec) -> ExposureProvider {
        let chosen = stack.settings?["exposure"]
        switch (chosen, stack.backend) {
        case ("platform", _):
            return PlatformExposure()
        case ("none", _), (nil, .dokku):
            return NoExposure()
        case (nil, _):
            // App Platform, Cloud Run, App Runner: the platform routes what it creates.
            return PlatformExposure()
        default:
            // A provider this build does not know yet (cloudflare-local and friends land
            // in their own slices) reads as none rather than as a crash.
            return NoExposure()
        }
    }
}

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

/// A provider that acts, not only plans. `none` and `platform` never conform: nothing to do
/// is a fact, not a failure.
///
/// Acting methods narrate instead of throwing — by the time a door is being opened the
/// stack is already live, and a failed grant belongs in the job transcript as a sentence
/// naming the fix, not as a dead clone.
public protocol ActingExposureProvider: ExposureProvider {
    func expose(
        domains: [String], stack: StackSpec,
        onProgress: @Sendable (String) -> Void) async
    func withdraw(
        domains: [String], stack: StackSpec,
        onProgress: @Sendable (String) -> Void) async
}

/// The lab's shape: a locally-managed cloudflared whose ingress is root-owned, driven
/// through the `hatchery-expose` wrapper behind one readable sudoers line. The wrapper is
/// the security boundary; this type only speaks its three verbs over the admin channel.
/// Install: docs/exposure-design.md.
public struct CloudflareLocalExposure: ActingExposureProvider {
    private let run: CommandRunner

    public init(run: @escaping CommandRunner = ShellRunner.live) {
        self.run = run
    }

    public var name: String { "cloudflare-local" }

    /// The ssh target that may run the wrapper — its own setting, falling back to the
    /// database admin: on this estate they are the same box and the same account.
    static func admin(for stack: StackSpec) -> String? {
        let chosen = stack.settings?["exposure_admin"] ?? stack.settings?["db_admin"]
        return (chosen?.isEmpty ?? true) ? nil : chosen
    }

    static func command(_ admin: String, verb: String, host: String? = nil) -> [String] {
        var argv = [
            "ssh", "-o", "BatchMode=yes", admin,
            "sudo", "-n", "/usr/local/bin/hatchery-expose", verb,
        ]
        if let host { argv.append(host) }
        return argv
    }

    static func grantHint(_ admin: String) -> String {
        "install Scripts/hatchery-expose on \(admin)'s box and grant it with one sudoers "
            + "line (docs/exposure-design.md)"
    }

    public func plan(domains: [String], stack: StackSpec) async -> [ExposurePlan] {
        guard let admin = Self.admin(for: stack) else {
            return domains.map {
                ExposurePlan(
                    domain: $0,
                    action: "cloudflare-local is selected but no admin channel is set — "
                        + "set exposure_admin (or db_admin) in the stack's settings",
                    actionable: false)
            }
        }
        return domains.map {
            ExposurePlan(
                domain: $0,
                action: "tunnel ingress + DNS via hatchery-expose on \(admin)",
                actionable: true)
        }
    }

    public func expose(
        domains: [String], stack: StackSpec,
        onProgress: @Sendable (String) -> Void
    ) async {
        await act(verb: "add", domains: domains, stack: stack, onProgress: onProgress)
    }

    public func withdraw(
        domains: [String], stack: StackSpec,
        onProgress: @Sendable (String) -> Void
    ) async {
        await act(verb: "remove", domains: domains, stack: stack, onProgress: onProgress)
    }

    private func act(
        verb: String, domains: [String], stack: StackSpec,
        onProgress: @Sendable (String) -> Void
    ) async {
        guard let admin = Self.admin(for: stack) else {
            onProgress("no admin channel for cloudflare-local — \(Self.grantHint("the admin"))")
            return
        }
        for domain in domains {
            do {
                let output = try await run(Self.command(admin, verb: verb, host: domain))
                for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onProgress(trimmed) }
                }
            } catch {
                onProgress("could not \(verb) \(domain): \(error) — \(Self.grantHint(admin))")
            }
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
        case ("cloudflare-local", _):
            return CloudflareLocalExposure()
        case ("none", _), (nil, .dokku):
            return NoExposure()
        case (nil, _):
            // App Platform, Cloud Run, App Runner: the platform routes what it creates.
            return PlatformExposure()
        default:
            // A provider this build does not know yet (cloudflare-api, lan-dns) reads as
            // none rather than as a crash.
            return NoExposure()
        }
    }
}

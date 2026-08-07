import Foundation
import Testing

@testable import HatcheryKit

private func devStack() -> StackSpec {
    StackSpec(
        name: "mwlab",
        backend: .dokku,
        environment: .dev,
        host: "dokku@192.168.0.103",
        tofu: TofuBinding(directory: "/infra/mwserver-tf"),
        services: [
            ServiceSpec(
                name: "mwlab", kind: .mwserver, image: "mwserver2:arm64-abc",
                domains: ["mwlab.opi"], configFile: "mwlab.config.json",
                imageVariable: "mwlab_image"),
            ServiceSpec(
                name: "paylab", kind: .paymentGateway, image: "pay:arm64-def",
                domains: ["paylab.opi", "paylab.jimmyhoughjr.net"],
                configFile: "paylab.config.json", imageVariable: "paylab_image"),
        ]
    )
}

@Suite("Rewriting the environment out of a value")
struct CloneEnvironmentTests {
    /// mwlab carries TEMPORAL_NAMESPACE=mwserver-dev. Copying that verbatim puts the staging
    /// stack in the dev namespace — not an error, and not what anyone meant.
    @Test("follows the environment when the clone lands elsewhere")
    func rewritesEnvironment() {
        #expect(
            StackCloner.rewrite("mwserver-dev", from: devStack(), to: "mwlab-2", environment: .staging)
                == "mwserver-staging")
        #expect(
            StackCloner.rewrite("mwstack-pg-dev", from: devStack(), to: "mwlab-2", environment: .staging)
                == "mwstack-pg-staging")
    }

    /// A clone that stays in the same environment should not have its values rewritten out from
    /// under it.
    @Test("leaves the environment alone when it does not change")
    func sameEnvironment() {
        #expect(
            StackCloner.rewrite("mwserver-dev", from: devStack(), to: "mwlab-2", environment: .dev)
                == nil)
    }

    /// Omitting the environment is how domains were rewritten before this existed, and it has to
    /// keep working — stack and service names still substitute.
    @Test("still substitutes names with no environment given")
    func namesWithoutEnvironment() {
        #expect(
            StackCloner.rewrite("paylab.opi", from: devStack(), to: "mwlab-2")
                == "mwlab-2-paylab.opi")
    }

    /// The bug this fixes: a sibling service's domain contains no stack name, so a plain
    /// stack-name substitution left it untouched — and a clone claiming production's domain is
    /// not a clone, it is a collision.
    @Test("rewrites a sibling service's domain")
    func siblingDomain() {
        for domain in ["paylab.opi", "paylab.jimmyhoughjr.net"] {
            let rewritten = StackCloner.rewrite(
                domain, from: devStack(), to: "mwlab-2", environment: .staging)
            #expect(rewritten != nil, "\(domain) must not survive a clone unchanged")
            #expect(rewritten?.contains("mwlab-2-paylab") == true)
        }
    }
}

import Foundation

/// Whether applying would change the code a Cloud Run service is running.
///
/// The service's latest ready revision reports the digest it was built from, and
/// Artifact Registry reports the digest its tag points at now. Both answer through
/// gcloud. A Docker Hub image answers through Hub's tag API as it does for App Platform.
/// A registry this does not know, a service with no ready revision, and a missing gcloud
/// are each said to be not checkable rather than silently fine.
public struct CloudRunDrift: Sendable {
    private let run: CommandRunner

    public init(run: @escaping CommandRunner = ShellRunner.live) {
        self.run = run
    }

    /// One sentence per service whose next apply would, or might, change its code.
    public func check(stack: StackSpec) async -> [String] {
        guard stack.backend == .cloudRun else { return [] }
        guard (try? await run(["sh", "-c", "command -v gcloud"])) != nil else {
            return stack.services.map { "\($0.name): drift not checkable — gcloud is not on this machine" }
        }
        let scope = (stack.settings?["project"]).map { ["--project", $0] } ?? []
        let region = (stack.settings?["region"]).map { ["--region", $0] } ?? []
        var lines: [String] = []
        for service in stack.services {
            guard let running = await deployedDigest(of: service.name, scope: scope + region) else {
                lines.append(
                    "\(service.name): drift not checkable — Cloud Run reports no ready revision "
                        + "for a service by that name")
                continue
            }
            let reference = ImageReference(service.image)
            guard let registry = await registryDigest(of: reference, image: service.image, scope: scope)
            else {
                lines.append(
                    "\(service.name): registry drift not checkable — \(reference.registryName) "
                        + "did not answer for \(reference.tagLabel)")
                continue
            }
            if AppPlatformDrift.hash(running) != AppPlatformDrift.hash(registry) {
                lines.append(
                    "\(service.name): the registry's \(reference.tagLabel) has moved past what "
                        + "Cloud Run deployed — applying pulls and runs new code")
            }
        }
        return lines
    }

    /// The digest the service's latest ready revision was built from.
    func deployedDigest(of service: String, scope: [String]) async -> String? {
        guard let revision = await value(
            ["gcloud", "run", "services", "describe", service, "--format",
             "value(status.latestReadyRevisionName)"] + scope),
            !revision.isEmpty
        else { return nil }
        let digest = await value(
            ["gcloud", "run", "revisions", "describe", revision, "--format",
             "value(status.imageDigest)"] + scope)
        return (digest?.isEmpty == false) ? digest : nil
    }

    func registryDigest(of reference: ImageReference, image: String, scope: [String]) async -> String? {
        switch reference.registry {
        case .unknown(let host) where host.hasSuffix("-docker.pkg.dev") || host == "gcr.io" || host.hasSuffix(".gcr.io"):
            let digest = await value(
                ["gcloud", "artifacts", "docker", "images", "describe", image, "--format",
                 "value(image_summary.digest)"] + scope)
            return (digest?.isEmpty == false) ? digest : nil
        case .dockerHub:
            return await AppPlatformDrift(run: run).registryDigest(of: reference, token: "")
        case .docr, .unknown:
            return nil
        }
    }

    private func value(_ argv: [String]) async -> String? {
        guard let data = try? await run(argv) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

/// Whether applying would change the code a service is running, said before the apply.
///
/// A mutable tag makes "apply" able to ship code silently: the declaration never moves,
/// the registry does, and dokku pulls fresh on every deploy — which is how one tag ran
/// three different revs here in a single day. This asks the questions that are actually
/// answerable, and says plainly which ones are not:
///
/// - **registry moved**: the tag's digest at the registry differs from the image the box
///   last pulled. Needs the `hatchery-inspect` grant (root's docker holds the pull
///   credentials); without it the answer is honestly unknown, not silently fine.
/// - **local tag moved**: the box's copy of the tag is newer than the image the running
///   container was derived from — a redeploy would pick it up.
public struct ImageDrift: Sendable {
    private let run: CommandRunner

    public init(run: @escaping CommandRunner = ShellRunner.live) {
        self.run = run
    }

    /// One sentence per service whose next apply would (or might) change its code.
    /// Empty when everything checkable is in sync.
    public func check(stack: StackSpec) async -> [String] {
        // The platform answers its own question, through its API rather than a box.
        if stack.backend == .appPlatform {
            return await AppPlatformDrift(run: run).check(stack: stack)
        }
        guard stack.backend == .dokku, let host = stack.hostAddress else { return [] }
        let admin = stack.settings?["exposure_admin"] ?? stack.settings?["db_admin"]

        var lines: [String] = []
        for service in stack.services {
            // Without an admin channel every question here is unanswerable — say so once
            // per service instead of silently skipping, because "no warning" must never
            // be mistakable for "no drift".
            guard admin != nil else {
                lines.append(
                    "\(service.name): drift not checkable — docker and the pull credentials "
                        + "are root's; set db_admin and install Scripts/hatchery-inspect "
                        + "with its sudoers grant to see whether a deploy would ship new code")
                continue
            }

            // The image the box holds for this tag, and when it was made.
            guard
                let localDigest = await output(
                    on: "\(DokkuProvider.sshUser)@\(host)", admin: admin,
                    docker: "docker image inspect '\(service.image)' --format '{{index .RepoDigests 0}}'")
            else { continue }

            // What the running container was derived from, by age: the derived image is
            // built at deploy, so a base tag created after it means a pending change.
            let derivedCreated = await output(
                on: "\(DokkuProvider.sshUser)@\(host)", admin: admin,
                docker: "docker inspect '\(service.name).web.1' --format '{{.Image}}' | "
                    + "xargs -I{} docker image inspect {} --format '{{.Created}}'")
            let tagCreated = await output(
                on: "\(DokkuProvider.sshUser)@\(host)", admin: admin,
                docker: "docker image inspect '\(service.image)' --format '{{.Created}}'")
            if let derivedCreated, let tagCreated, tagCreated > derivedCreated {
                lines.append(
                    "\(service.name): the box's \(tag(of: service.image)) is newer than the "
                        + "running container — applying redeploys onto the newer build")
            }

            // What the registry would hand a deploy right now — root's question.
            guard let admin else { continue }
            let registryDigest = try? await runCommand([
                "ssh", "-o", "BatchMode=yes", admin,
                "sudo", "-n", "/usr/local/bin/hatchery-inspect", "digest", service.image,
            ])
            guard let registryDigest, !registryDigest.isEmpty else {
                lines.append(
                    "\(service.name): registry drift not checkable — hatchery-inspect did "
                        + "not answer on \(admin) (install Scripts/hatchery-inspect + its "
                        + "sudoers grant)")
                continue
            }
            let localHash = localDigest.split(separator: "@").last.map(String.init) ?? localDigest
            if localHash != registryDigest {
                lines.append(
                    "\(service.name): the registry's \(tag(of: service.image)) has moved past "
                        + "the box's copy — applying pulls and runs new code")
            }
        }
        return lines
    }

    private func tag(of image: String) -> String {
        image.split(separator: ":").last.map { "tag \($0)" } ?? "tag"
    }

    /// Docker read-only queries go through the admin channel when there is one — the
    /// dokku account cannot run docker — and are skipped without complaint when not:
    /// the registry line already carries the actionable absence.
    private func output(on dokkuTarget: String, admin: String?, docker: String) async -> String? {
        guard let admin else { return nil }
        return try? await runCommand([
            "ssh", "-o", "BatchMode=yes", admin, "sh", "-c",
            DatabaseProvisioner.shellQuoted(docker),
        ])
    }

    private func runCommand(_ argv: [String]) async throws -> String {
        let data = try await run(argv)
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

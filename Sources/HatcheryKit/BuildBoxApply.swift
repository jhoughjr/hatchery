import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A label change on a build box: the plan, the write on the box, the restart, and the forge's own answer after it.
///
/// Where a build runs is set by the labels its runner declares, so moving a build is a label change and not a commit.
/// Jimmy ruled on 2026-09-25 (rookery#17) that the change belongs to a house tool: the board reads, hatchery writes.
extension BuildBox {
    /// A label is a name, and an optional target after the first colon, such as `macos:host` or `linux:docker://img:tag`.
    static let labelCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:/@"))

    /// The labels after adding and removing names, where an added bare name takes the target every current label shares.
    ///
    /// A runner whose labels name different targets cannot say which one a bare name means, so it must be given in full.
    public static func relabel(_ current: [String], adding: [String], removing: [String]) throws -> [String] {
        for label in adding + removing where label.isEmpty || label.unicodeScalars.contains(where: { !self.labelCharacters.contains($0) }) {
            throw Trouble.unreadable(service: "label", what: "\(label) is not a label: use letters, digits and . _ - : / @")
        }
        let name: (String) -> String = { $0.split(separator: ":", maxSplits: 1).first.map(String.init) ?? $0 }
        let drop = Set(removing.map(name))
        var labels = current.filter { !drop.contains(name($0)) }
        let targets = Set(current.compactMap { label in label.firstIndex(of: ":").map { String(label[label.index(after: $0)...]) } })
        for label in adding where !labels.map(name).contains(name(label)) {
            if label.contains(":") {
                labels.append(label)
            } else if targets.count == 1, let target = targets.first {
                labels.append(label + ":" + target)
            } else {
                throw Trouble.unreadable(
                    service: "label", what: "this runner's labels name more than one target, so give \(label) in full, as name:target")
            }
        }
        guard !labels.isEmpty else { throw Trouble.unreadable(service: "label", what: "a runner with no labels takes no job") }
        return labels
    }

    /// The program that rewrites the labels list of a runner config, run by `python3` on the box.
    ///
    /// Only the list under `runner:` / `labels:` changes. A comment above a label stays with that label, and a kept
    /// label keeps its own line. The file is copied to `<config>.bak-hatchery` first and replaced in one rename.
    /// It prints `changed` or `unchanged`.
    static let rewriteProgram = #"""
    import base64, json, os, shutil, subprocess, sys
    where, target, path, wanted = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(base64.b64decode(sys.argv[4]))
    def read():
        if where == "docker":
            return subprocess.run(["docker", "exec", target, "cat", path], check=True, capture_output=True, text=True).stdout
        return open(path).read()
    def write(text):
        if where == "docker":
            script = "cp '%s' '%s.bak-hatchery' && cat > '%s.new' && mv '%s.new' '%s'" % (path, path, path, path, path)
            subprocess.run(["docker", "exec", "-i", target, "sh", "-c", script], input=text, check=True, text=True)
        else:
            shutil.copy2(path, path + ".bak-hatchery")
            with open(path + ".new", "w") as out:
                out.write(text)
            os.replace(path + ".new", path)
    text = read()
    lines = text.split("\n")
    start = next(n for n, l in enumerate(lines) if l.rstrip() == "runner:")
    head = next(n for n in range(start + 1, len(lines)) if lines[n].strip() == "labels:")
    indent = len(lines[head]) - len(lines[head].lstrip())
    end = head + 1
    while end < len(lines):
        line = lines[end]
        if line.strip() == "" or len(line) - len(line.lstrip()) <= indent:
            break
        end += 1
    groups, pending, item = {}, [], None
    for line in lines[head + 1:end]:
        bare = line.strip()
        if bare.startswith("#"):
            pending.append(line)
        elif bare.startswith("- "):
            item = item or line[:len(line) - len(line.lstrip())]
            groups[bare[2:].strip().strip('"').strip("'")] = pending + [line]
            pending = []
    item = item or " " * (indent + 2)
    body = []
    for label in wanted:
        body += groups.get(label, ['%s- "%s"' % (item, label)])
    result = "\n".join(lines[:head + 1] + body + pending + lines[end:])
    if result != text:
        write(result)
    print("changed" if result != text else "unchanged")
    """#

    /// The command that rewrites a runner's labels on its box, with the program and the labels carried as base64.
    ///
    /// The exit code is kept in `rc` and not `status`, because `status` is read only in zsh, which is a Mac's login shell.
    /// On 2026-09-25 that name failed the command after the rewrite and before the restart, and the mini's config
    /// named a label its runner had not declared.
    static func rewriteCommand(for service: ServiceSpec, config: String, labels: [String]) throws -> String {
        let program = Data(self.rewriteProgram.utf8).base64EncodedString()
        let wanted = try JSONEncoder().encode(labels).base64EncodedString()
        let where_ = service.container != nil ? "docker" : "file"
        return "echo \(program) | base64 -d > /tmp/hatchery-relabel.py && python3 /tmp/hatchery-relabel.py "
            + "\(where_) '\(service.name)' '\(config)' \(wanted); rc=$?; rm -f /tmp/hatchery-relabel.py; exit $rc"
    }

    /// The command that restarts a runner so it declares its labels to the forge again.
    static func restartCommand(for service: ServiceSpec, platform: HostPlatform) -> String {
        if service.container != nil { return "docker restart '\(service.name)'" }
        let label = HostProvider.jobLabel(for: service, platform: platform)
        switch platform {
        case .darwin: return "launchctl kickstart -k gui/$(id -u)/\(label)"
        default: return "systemctl --user restart '\(label)'"
        }
    }

    /// Rewrites a runner's labels on its box and restarts it. Returns whether the config changed.
    public static func apply(
        _ service: ServiceSpec, in stack: StackSpec, config: String, labels: [String],
        using run: CommandRunner = ShellRunner.live
    ) async throws -> Bool {
        guard let host = stack.host, !host.isEmpty else { throw Trouble.noHost(stack: stack.name) }
        guard !config.contains("'") else { throw Trouble.unreadable(service: service.name, what: "the config path has a quote in it") }
        let ssh = { (command: String) in ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command] }
        let said = String(decoding: try await run(ssh(try self.rewriteCommand(for: service, config: config, labels: labels))), as: UTF8.self)
        _ = try await run(ssh(self.restartCommand(for: service, platform: stack.platform)))
        return said.contains("changed") && !said.contains("unchanged")
    }
}

/// The forge's own list of runners, which is the only place a runner's registration says what it declared last.
public enum ForgeRunners {
    public struct Runner: Sendable, Equatable {
        public let id: Int
        public let name: String
        /// `idle`, `active` or `offline`.
        public let status: String
        public let labels: [String]
    }

    public typealias Fetch = @Sendable () async throws -> [Runner]

    /// The runners on the house forge, read with the token git's credential helper holds for it.
    public static let live: Fetch = {
        let base = ProcessInfo.processInfo.environment["HOUSE_FORGE"] ?? "https://forgejo.jimmyhoughjr.net"
        let host = URL(string: base)?.host ?? "forgejo.jimmyhoughjr.net"
        var request = URLRequest(url: URL(string: base + "/api/v1/admin/actions/runners?limit=50")!)
        request.setValue("token " + (try ForgeSecrets.gitCredential(host: host)), forHTTPHeaderField: "Authorization")
        // The edge refuses a client that names no agent.
        request.setValue("hatchery-box-runner/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw BuildBox.Trouble.unreadable(service: "forge", what: "the forge answered \(status) for its runner list")
        }
        return ForgeRunners.parse(data)
    }

    static func parse(_ data: Data) -> [Runner] {
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = (row["id"] as? NSNumber)?.intValue, let name = row["name"] as? String else { return nil }
            return Runner(
                id: id, name: name, status: (row["status"] as? String ?? "unknown").lowercased(),
                labels: row["labels"] as? [String] ?? [])
        }
    }

    /// The registration by this name that is not offline, or the newest one when every one is.
    public static func current(_ name: String, in runners: [Runner]) -> Runner? {
        let named = runners.filter { $0.name == name }
        return named.first { $0.status != "offline" } ?? named.max { $0.id < $1.id }
    }
}

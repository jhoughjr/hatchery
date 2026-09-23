import Foundation

/// The order a box brings its dokku apps up in, from each service's `after` list, asserted at boot.
///
/// A reset on 2026-09-09 and two on 2026-09-14 left the opi's sites down until a person ran the fixes by hand, in order.
/// Vault came up with a stale proxy, and forgejo and rookery then failed their boot against it.
/// The order is a declaration and the fixes are assertions, so the box converges on its own and a second run changes nothing.
public enum BootOrder {
    /// One dokku app, as the boot order needs it.
    public struct App: Sendable, Equatable {
        public let name: String
        public let domains: [String]
        /// The code the proxy gives for the root on port 80, when one is declared.
        public let expectedStatus: String?
        /// The apps that must be serving before this one is started.
        public let after: [String]

        public init(name: String, domains: [String], expectedStatus: String? = nil, after: [String] = []) {
            self.name = name
            self.domains = domains
            self.expectedStatus = expectedStatus
            self.after = after
        }
    }

    /// A boot order that cannot be built.
    ///
    /// - `unknown`: a service names an app in `after` that no manifest declares
    /// - `cycle`: the `after` lists loop, so no app can come first
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknown(service: String, after: String)
        case cycle([String])

        public var description: String {
            switch self {
            case .unknown(let service, let after):
                return "\(service) is declared after \(after), and no manifest declares \(after)"
            case .cycle(let names):
                return "the after lists loop: \(names.joined(separator: " -> "))"
            }
        }
    }

    /// The command that reaches dokku on the box itself.
    public static let localDokku = "ssh -o BatchMode=yes dokku@localhost"
    /// How long a fix waits for its app to serve, in five-second steps.
    ///
    /// Three minutes covers a rookery boot on the opi, which waits up to 94 seconds on vault before it gives up.
    public static let settleSteps = 36

    /// Where the rendered recipe and its unit live on the box, under the account that runs it.
    public static let scriptPath = "$HOME/.local/share/hatchery/boot-order.sh"
    public static let unitName = "hatchery-boot-order.service"
    public static let unitPath = "$HOME/.config/systemd/user/hatchery-boot-order.service"

    /// Every dokku app the manifests declare.
    public static func apps(from manifests: [StackManifest]) -> [App] {
        let stacks: [StackSpec] = manifests.flatMap { $0.stacks }.filter { $0.backend == .dokku }
        let services: [ServiceSpec] = stacks.flatMap { $0.services }
        return services.map { service in
            App(
                name: service.name,
                domains: service.domains,
                expectedStatus: service.expectedStatus,
                after: service.after ?? [])
        }
    }

    /// The apps that take part in an order, each one after everything it names.
    ///
    /// An app with no `after` list and that no other app names is left out, because the reconcile already starts it in any order.
    /// Apps that do not depend on each other keep the order of their names, so the same manifests always give the same recipe.
    public static func ordered(_ apps: [App]) throws -> [App] {
        let byName = Dictionary(apps.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for app in apps {
            for name in app.after where byName[name] == nil {
                throw Failure.unknown(service: app.name, after: name)
            }
        }
        let named = Set(apps.flatMap(\.after))
        let taking = apps.filter { !$0.after.isEmpty || named.contains($0.name) }.sorted { $0.name < $1.name }

        var placed: [App] = []
        var done = Set<String>()
        func place(_ app: App, path: [String]) throws {
            guard !done.contains(app.name) else { return }
            if path.contains(app.name) {
                throw Failure.cycle(Array(path.drop { $0 != app.name }) + [app.name])
            }
            for name in app.after.sorted() {
                if let dependency = byName[name] {
                    try place(dependency, path: path + [app.name])
                }
            }
            done.insert(app.name)
            placed.append(app)
        }
        for app in taking {
            try place(app, path: [])
        }
        return placed
    }
}

// MARK: - Assertions

extension BootOrder {
    /// One assertion for each app, in order: the app is serving, or it is started, its proxy is rebuilt, and it gets time to settle.
    ///
    /// An app serves when local nginx gives the declared code for each domain on port 80.
    /// A 301 or a 308 there is nginx's own redirect, which answers even when the app behind it is down, so the https root must also answer something other than 000 or a 5xx.
    public static func assertions(for ordered: [App], dokku: String = BootOrder.localDokku) -> [BoxAssertion] {
        ordered.map { app in
            let check = self.serving(app)
            let settle = "i=0; while [ $i -lt \(self.settleSteps) ]; do "
                + "sh -c \(DatabaseProvisioner.shellQuoted(check)) && exit 0; i=$((i+1)); sleep 5; done; exit 0"
            let waits = app.after.isEmpty ? "" : " after \(app.after.sorted().joined(separator: ", "))"
            return BoxAssertion(
                name: "\(app.name) is serving\(waits)",
                check: check,
                // A running app with a stale proxy is the usual case, so a start that refuses does not stop the rebuild.
                // The check after the fixes is what decides.
                fix: [
                    "\(dokku) ps:start \(app.name) || true",
                    "\(dokku) proxy:build-config \(app.name)",
                    settle,
                ],
                remedy: "\(app.name) does not serve after a start and a proxy rebuild. Read `dokku logs \(app.name)`")
        }
    }

    /// The shell check that an app serves on every domain it declares.
    static func serving(_ app: App) -> String {
        let domains = app.domains.map { domain -> String in
            let expected = app.expectedStatus.map { "[ \"$code\" = \($0) ]" } ?? "case \"$code\" in 2??|3??) true;; *) false;; esac"
            return "code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H 'Host: \(domain)' http://127.0.0.1/); "
                + "\(expected) || exit 1; "
                + "case \"$code\" in 301|308) "
                + "tls=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' --resolve '\(domain):443:127.0.0.1' 'https://\(domain)/'); "
                + "case \"$tls\" in 000|5??) exit 1;; esac;; esac"
        }
        return domains.isEmpty ? "false" : domains.joined(separator: "; ")
    }
}

// MARK: - Boot

extension BootOrder {
    /// The assertions as a script the box runs at boot, when no operator machine may be awake to run them over ssh.
    ///
    /// It keeps the runner's rules: a check that holds skips its fixes, a fix stops at its first failure, and a failed assertion stops the run with exit 1.
    public static func script(_ assertions: [BoxAssertion]) -> String {
        let steps = assertions.map { assertion -> String in
            let name = DatabaseProvisioner.shellQuoted(assertion.name)
            let check = "sh -c \(DatabaseProvisioner.shellQuoted(assertion.check))"
            let fixes = assertion.fix.map { "sh -c \(DatabaseProvisioner.shellQuoted($0))" }.joined(separator: " && ")
            return """
            if \(check); then
              echo "hold   "\(name)
            elif \(fixes.isEmpty ? "false" : fixes) && \(check); then
              echo "fixed  "\(name)
            else
              echo "FAILED "\(name)" - "\(DatabaseProvisioner.shellQuoted(assertion.remedy))
              exit 1
            fi
            """
        }
        return "#!/bin/sh\n# Written by hatchery box order. A second run changes nothing.\n" + steps.joined(separator: "\n") + "\n"
    }

    /// The user unit that runs the script at boot, and again a minute after a failure, for up to half an hour.
    ///
    /// A user unit needs no root, and the account's manager starts at boot when lingering is on.
    public static func unit() -> String {
        """
        [Unit]
        Description=hatchery boot order: bring the dokku apps up after the apps they need
        StartLimitIntervalSec=1800
        StartLimitBurst=30

        [Service]
        Type=oneshot
        ExecStart=/bin/sh %h/.local/share/hatchery/boot-order.sh
        Restart=on-failure
        RestartSec=60

        [Install]
        WantedBy=default.target

        """
    }

    /// The assertions that put the script and the unit on the box and enable the unit.
    ///
    /// Each file is written only when its checksum differs, so an unchanged order installs nothing.
    public static func installAssertions(script: String) -> [BoxAssertion] {
        func file(_ path: String, _ content: String, _ name: String) -> BoxAssertion {
            let encoded = Data(content.utf8).base64EncodedString()
            return BoxAssertion(
                name: name,
                check: "[ \"$(sha256sum \"\(path)\" 2>/dev/null | cut -c1-64)\" = \(SHA256.hex(content)) ]",
                fix: ["mkdir -p \"$(dirname \"\(path)\")\" && echo \(encoded) | base64 -d > \"\(path)\""],
                remedy: "the account cannot write \(path)")
        }
        return [
            BoxAssertion(
                name: "lingering is on, so the account's units start at boot",
                check: "loginctl show-user \"$(id -un)\" -p Linger | grep -q yes",
                remedy: "sudo loginctl enable-linger \"$(id -un)\""),
            file(self.scriptPath, script, "the boot order script is current"),
            file(self.unitPath, self.unit(), "the boot order unit is current"),
            BoxAssertion(
                name: "the boot order unit is enabled",
                check: "systemctl --user is-enabled \(self.unitName) >/dev/null 2>&1 && "
                    + "[ \"$(systemctl --user show \(self.unitName) -p NeedDaemonReload --value)\" = no ]",
                fix: ["systemctl --user daemon-reload && systemctl --user enable \(self.unitName)"],
                remedy: "systemctl --user enable \(self.unitName)"),
        ]
    }
}

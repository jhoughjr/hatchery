import Foundation

/// One file `state init` would write.
public struct StateFile: Sendable, Equatable {
    public let path: String
    public let contents: String
    public let executable: Bool
    /// Files that must never be rewritten once they exist. Replacing `.age-recipient` orphans
    /// every archive encrypted to the old key — the plaintext is still there, but the backup
    /// stops opening, which is worse than having none because it looks like one.
    public let preserveExisting: Bool

    public init(path: String, contents: String, executable: Bool = false, preserveExisting: Bool = false) {
        self.path = path
        self.contents = contents
        self.executable = executable
        self.preserveExisting = preserveExisting
    }
}

/// What to set up, and where.
public struct StateInitRequest: Sendable, Equatable {
    /// Directory that will hold the declarations and the sealed archive.
    public var directory: String
    /// Where the age private key lives. Deliberately outside `directory`: the key that opens
    /// the archive must not sit in the repository the archive is committed to.
    public var identityPath: String
    /// `owner/name` on GitHub, or nil to set up locally with no remote.
    public var remote: String?

    public init(directory: String, identityPath: String? = nil, remote: String? = nil) {
        self.directory = directory
        let name = URL(fileURLWithPath: Paths.expanded(directory)).lastPathComponent
        self.identityPath = identityPath ?? "~/.config/age/\(name.isEmpty ? "state" : name).txt"
        self.remote = remote
    }
}

/// What `state init` will do, worked out before anything is written.
public struct StateInitPlan: Sendable, Equatable {
    public let directory: String
    public let identityPath: String
    public let remote: String?
    /// True when the identity already exists and will be reused rather than generated.
    public let reusesIdentity: Bool
    public let files: [StateFile]
    /// Things the person has to know, not things hatchery can fix.
    public let warnings: [String]

    /// Files that would be skipped because they already exist and must not be replaced.
    public func preserved(existing: (String) -> Bool) -> [String] {
        files.filter { $0.preserveExisting && existing($0.path) }.map(\.path)
    }
}

/// Turns a state directory into one that backs itself up.
///
/// This existed only as a set of steps someone performed by hand once, which is the same reason
/// sealing did not happen: an unrepeatable setup is one nobody repeats. Everything here is
/// parameterised — where the directory is, where the key lives, which repository it pushes to.
public enum StateInitPlanner {
    /// The identity is the single point of failure and saying so once, loudly, is the only
    /// protection there is. It is never printed, logged, or sent to the browser.
    public static let identityWarning =
        "The private key is the only thing that can open this backup. "
        + "Copy it to a password manager now — if it is lost, the archive is unreadable, "
        + "including by you."

    public static func plan(
        _ request: StateInitRequest,
        identityExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> StateInitPlan {
        let directory = Paths.expanded(request.directory)
        let identity = Paths.expanded(request.identityPath)
        let reuses = identityExists(identity)

        var warnings = [identityWarning]
        if reuses {
            warnings.insert(
                "Reusing the existing key at \(request.identityPath). "
                    + "Generating a new one would leave any existing archive unopenable.",
                at: 0)
        }
        if let remote = request.remote, !remote.contains("/") {
            warnings.append("'\(remote)' is not owner/name; the remote will not be created.")
        }
        // The archive is committed. A public repository would publish it, and age is strong but
        // the blast radius of a mistake here is every credential the stack has.
        if request.remote != nil {
            warnings.append("The repository is created private. Keep it that way — the archive is committed to it.")
        }

        return StateInitPlan(
            directory: directory,
            identityPath: identity,
            remote: request.remote,
            reusesIdentity: reuses,
            files: files(identityPath: identity),
            warnings: warnings
        )
    }

    /// The scaffolded files. `.age-recipient` is written separately, because its contents come
    /// from the key rather than from here.
    public static func files(identityPath: String) -> [StateFile] {
        [
            StateFile(path: ".gitignore", contents: gitignore, preserveExisting: true),
            StateFile(path: SealedState.scriptName, contents: sealScript, executable: true),
            StateFile(
                path: "unseal.sh", contents: unsealScript(identityPath: identityPath),
                executable: true),
            StateFile(path: "README.md", contents: readme, preserveExisting: true),
        ]
    }

    public static let gitignore = """
        # Provider binaries. Re-downloadable with `tofu init`; the lock file stays committed.
        **/.terraform/

        # Plaintext secrets.
        #
        # These files stay on disk because tofu reads them directly — the dokku provider cannot
        # take variables in a config map (aliksend/terraform-provider-dokku#94), so the config
        # has to be a file it can read. What version control stores is secrets.tar.age, produced
        # by ./seal.sh.
        #
        # If you add a new kind of secret file, add it here AND to the find in seal.sh, or it
        # will be both uncommitted and unbacked-up.
        *.config.json
        *.tfvars
        *.tfvars.json
        terraform.tfstate
        terraform.tfstate.*
        crash.log

        # The identity that opens secrets.tar.age must never live in the repo it protects.
        *.key
        age-identity*
        *-identity.txt

        """

    public static let sealScript = """
        #!/usr/bin/env bash
        # Encrypt the files that hold secrets into a single committed blob.
        #
        # The plaintext copies stay where they are — tofu reads them directly and must keep
        # working — so they are gitignored and this bundle is what version control stores.
        #
        # Written by `hatchery state init`. hatchery re-runs this after anything that writes a
        # secret; run it by hand any time with `hatchery state seal`.
        #
        # Usage: ./seal.sh
        set -euo pipefail

        DIR="$(cd "$(dirname "$0")" && pwd)"
        RECIPIENT_FILE="${DIR}/.age-recipient"

        if [ ! -f "${RECIPIENT_FILE}" ]; then
            echo "error: ${RECIPIENT_FILE} is missing; it names the key this repo encrypts to" >&2
            exit 1
        fi
        RECIPIENT="$(cat "${RECIPIENT_FILE}")"

        cd "${DIR}"

        # Every file that carries a secret value. Config maps hold real credentials; tfstate
        # holds every value the provider has ever seen, in cleartext, including the config maps.
        # Collected with a read loop rather than `mapfile`, which needs bash 4; macOS ships 3.2.
        SECRETS=()
        while IFS= read -r line; do
            [ -n "${line}" ] && SECRETS+=("${line}")
        done < <(find . \\
            -path ./.terraform -prune -o \\
            -path ./.git -prune -o \\
            \\( -name '*.config.json' -o -name 'terraform.tfstate' -o -name 'terraform.tfstate.backup' \\) \\
            -type f -print | sed 's|^\\./||' | sort)

        if [ ${#SECRETS[@]} -eq 0 ]; then
            echo "nothing to seal" >&2
            exit 1
        fi

        printf 'sealing %d file(s):\\n' "${#SECRETS[@]}"
        printf '  %s\\n' "${SECRETS[@]}"

        tar -cf - "${SECRETS[@]}" | age -r "${RECIPIENT}" -o secrets.tar.age

        # A manifest of what is inside, so a restore can be checked without decrypting first.
        {
            echo "# Sealed $(date -u +%Y-%m-%dT%H:%M:%SZ) — contents of secrets.tar.age"
            for f in "${SECRETS[@]}"; do
                echo "$(shasum -a 256 "$f" | cut -d' ' -f1)  $f"
            done
        } > secrets.manifest

        echo "wrote secrets.tar.age ($(wc -c < secrets.tar.age | tr -d ' ') bytes) and secrets.manifest"

        """

    public static let unsealScript = """
        #!/usr/bin/env bash
        # Restore the plaintext secret files from the committed bundle.
        #
        # This is what a fresh machine runs after cloning: the .tf files arrive in the clone, the
        # secrets arrive from secrets.tar.age, and tofu works again.
        #
        # Usage: ./unseal.sh [--check]
        #   --check  verify the bundle against secrets.manifest without writing anything
        set -euo pipefail

        DIR="$(cd "$(dirname "$0")" && pwd)"
        KEY="${AGE_IDENTITY:-__IDENTITY__}"

        cd "${DIR}"

        if [ ! -f secrets.tar.age ]; then
            echo "error: secrets.tar.age is missing" >&2
            exit 1
        fi
        if [ ! -f "${KEY}" ]; then
            echo "error: no age identity at ${KEY}" >&2
            echo "       set AGE_IDENTITY, or restore the key from wherever you kept it." >&2
            echo "       Without that key this bundle cannot be opened by anyone, including you." >&2
            exit 1
        fi

        if [ "${1:-}" = "--check" ]; then
            # Decrypt to a scratch directory and compare against the manifest, so a restore can
            # be trusted before it overwrites anything.
            scratch="$(mktemp -d)"
            trap 'rm -rf "${scratch}"' EXIT
            age -d -i "${KEY}" secrets.tar.age | tar -xf - -C "${scratch}"

            status=0
            while read -r sum path; do
                case "${sum}" in \\#*) continue ;; esac
                [ -z "${path:-}" ] && continue
                if [ ! -f "${scratch}/${path}" ]; then
                    echo "MISSING  ${path}"
                    status=1
                elif [ "$(shasum -a 256 "${scratch}/${path}" | cut -d' ' -f1)" != "${sum}" ]; then
                    echo "DIFFERS  ${path}"
                    status=1
                else
                    echo "ok       ${path}"
                fi
            done < secrets.manifest
            exit "${status}"
        fi

        age -d -i "${KEY}" secrets.tar.age | tar -xf - -C "${DIR}"
        echo "restored plaintext secrets into ${DIR}"

        """

    public static let readme = """
        # Infrastructure state

        Declarations, tofu state and the encrypted copy of every secret they need.

        Set up by `hatchery state init`. hatchery re-seals this directory after anything that
        writes a secret, so `secrets.tar.age` should always match what is on disk. Check it with:

            hatchery state status

        ## On a fresh machine

            git clone <this repo>
            # restore the age identity from your password manager, then:
            ./unseal.sh

        ## The key

        The archive is encrypted to the key named in `.age-recipient`. The matching private key
        is deliberately not in this repository. If it is lost the archive cannot be opened by
        anyone, including you — so it belongs in a password manager, not only on one laptop.

        """

    /// `unseal.sh` needs the identity path baked in, since it runs without hatchery.
    public static func unsealScript(identityPath: String) -> String {
        unsealScript.replacingOccurrences(of: "__IDENTITY__", with: identityPath)
    }
}

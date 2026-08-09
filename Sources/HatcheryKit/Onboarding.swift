import Foundation

/// One thing to do to a box before hatchery can manage it.
public struct SetupStep: Sendable, Equatable, Codable {
    public let title: String
    /// Why this step exists, rather than only what it does.
    public let why: String
    /// Where the command runs: `box` for a shell on the machine, `here` for this one.
    public let on: String
    public let commands: [String]
    /// How to tell it worked.
    public let verify: String?

    public init(title: String, why: String, on: String, commands: [String], verify: String? = nil) {
        self.title = title
        self.why = why
        self.on = on
        self.commands = commands
        self.verify = verify
    }
}

/// Getting a machine to the point where hatchery can manage stacks on it.
///
/// `doctor` can tell you dokku is not answering; it cannot tell you how to put dokku there. This
/// is that missing half. It is deliberately a checklist rather than a script: these steps touch
/// a machine's package manager, its firewall and its SSH configuration, and running that blind
/// from a dashboard is not a thing hatchery should do on your behalf.
public enum Onboarding {
    /// The dokku version the lab is known to work against, for reference rather than pinning.
    public static let knownGoodDokku = "0.38.19"

    /// Getting an AWS account to the point hatchery can author an App Runner service into it.
    ///
    /// Two of these are once-per-account rather than once-per-stack, and saying which is which
    /// matters: the access role in particular is the step people repeat unnecessarily and then
    /// wonder why they have four of them.
    public static var awsSteps: [SetupStep] {
        [
            SetupStep(
                title: "Install the AWS CLI and sign in",
                why: """
                    hatchery does not hold AWS credentials. It shells out to the CLI and to tofu, \
                    both of which read whatever your profile, environment or SSO session already \
                    provides — so there is nothing for hatchery to store or leak.
                    """,
                on: "here",
                commands: InstallHint.commands(for: "awscli") + [
                    "aws configure          # or: aws sso login --profile <name>",
                    "aws configure set region us-east-1",
                ],
                verify: "aws sts get-caller-identity"),

            SetupStep(
                title: "Create the App Runner ECR access role (once per account)",
                why: """
                    App Runner pulls the image itself, so it needs a role it can assume to read \
                    ECR. This is per account, not per service — every stack in the account shares \
                    one. Its ARN goes in apprunner_access_role_arn, which hatchery leaves blank \
                    for you to fill.
                    """,
                on: "here",
                commands: [
                    "aws iam create-role --role-name AppRunnerECRAccess \\",
                    "  --assume-role-policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"build.apprunner.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}'",
                    "aws iam attach-role-policy --role-name AppRunnerECRAccess \\",
                    "  --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess",
                ],
                verify: "aws iam get-role --role-name AppRunnerECRAccess --query Role.Arn"),

            SetupStep(
                title: "Create an ECR repository and push an image",
                why: """
                    App Runner deploys an image; it does not build one. The repository URI and \
                    tag are what you give hatchery as the image, the same way a dokku stack takes \
                    a tag already built on the box.
                    """,
                on: "here",
                commands: [
                    "aws ecr create-repository --repository-name <service>",
                    "aws ecr get-login-password | docker login --username AWS --password-stdin \\",
                    "  <account>.dkr.ecr.<region>.amazonaws.com",
                    "docker push <account>.dkr.ecr.<region>.amazonaws.com/<service>:<tag>",
                ],
                verify: "aws ecr describe-images --repository-name <service>"),

            SetupStep(
                title: "Point hatchery at it",
                why: """
                    Everything above is the account. This is the part hatchery does: check what \
                    it needs, write the tofu, and create the stack.
                    """,
                on: "here",
                commands: [
                    "hatchery doctor --backend aws",
                    "hatchery stack new <name> --backend aws --tofu-dir ~/infra-state/<name>",
                ],
                verify: "hatchery status"),
        ]
    }

    /// Getting a DigitalOcean account ready for an App Platform app.
    public static var cloudRunSteps: [SetupStep] {
        [
            SetupStep(
                title: "Install the gcloud SDK and sign in",
                why: """
                    hatchery holds no Google credentials. Both tofu and gcloud read the \
                    application-default credentials you create here, so there is nothing for \
                    hatchery to store, and revoking access is done in one place rather than two.
                    """,
                on: "here",
                commands: InstallHint.commands(for: "gcloud") + [
                    "gcloud auth login",
                    "gcloud auth application-default login   # what tofu actually reads",
                    "gcloud config set project <project-id>",
                ],
                verify: "gcloud auth list --filter=status:ACTIVE"),

            SetupStep(
                title: "Enable the APIs, once per project",
                why: """
                    A fresh project has Cloud Run and Artifact Registry switched off, and the \
                    first apply fails with a permission error that names an API rather than the \
                    thing you were doing. Enabling them first turns that into nothing at all.
                    """,
                on: "here",
                commands: [
                    "gcloud services enable run.googleapis.com",
                    "gcloud services enable artifactregistry.googleapis.com",
                ],
                verify: "gcloud services list --enabled | grep run"),

            SetupStep(
                title: "Create a repository and push an image",
                why: """
                    Cloud Run deploys an image; it does not build one. The full image path is \
                    what you give hatchery, the same way a dokku stack takes a tag already built \
                    on the box.
                    """,
                on: "here",
                commands: [
                    "gcloud artifacts repositories create <repo> --repository-format=docker --location=<region>",
                    "gcloud auth configure-docker <region>-docker.pkg.dev",
                    "docker push <region>-docker.pkg.dev/<project>/<repo>/<service>:<tag>",
                ],
                verify: "gcloud artifacts docker images list <region>-docker.pkg.dev/<project>/<repo>"),

            SetupStep(
                title: "Point hatchery at it",
                why: """
                    Everything above is the project. This is the part hatchery does: check what \
                    it needs, write the tofu, and create the stack.
                    """,
                on: "here",
                commands: [
                    "hatchery doctor --backend cloudRun",
                    "hatchery stack new <name> --backend cloudRun --tofu-dir ~/infra-state/<name>",
                ],
                verify: "hatchery status"),
        ]
    }

    /// Getting a DigitalOcean account ready for an App Platform app.
    public static var appPlatformSteps: [SetupStep] {
        [
            SetupStep(
                title: "Create an API token",
                why: """
                    The tofu provider reads DIGITALOCEAN_TOKEN from the environment; hatchery \
                    never stores it. It needs write scope, because creating an app is a write. \
                    A read-only token fails at apply with a permission error that does not \
                    mention its own scope.
                    """,
                on: "here",
                commands: [
                    "# Create one at cloud.digitalocean.com/account/api/tokens (write scope)",
                    "export DIGITALOCEAN_TOKEN=dop_v1_...",
                    "# add it to your shell profile so tofu sees it in new terminals",
                ],
                verify: "hatchery doctor --backend appPlatform"),

            SetupStep(
                title: "Make the image reachable",
                why: """
                    App Platform pulls the image itself. A public Docker Hub repository needs \
                    nothing; a private one or DOCR needs the registry integrated with the \
                    account first, or the app deploys and then cannot pull.
                    """,
                on: "here",
                commands: [
                    "# public Docker Hub: nothing to do",
                    "# DOCR: doctl registry create <name> && doctl registry login",
                    "# then set <service>_registry_type to DOCR in variables.tf",
                ],
                verify: "doctl registry get   # only if using DOCR"),

            SetupStep(
                title: "Point hatchery at it",
                why: """
                    hatchery can create an App Platform app — `digitalocean_app` takes an image, \
                    an environment, a port and a health check. What it cannot do is read one \
                    back: every SECRET value returns as EV[...] ciphertext, so `config audit` \
                    and `config sync` refuse for this backend rather than reporting drift they \
                    cannot see.
                    """,
                on: "here",
                commands: [
                    "hatchery doctor --backend appPlatform",
                    "hatchery stack new <name> --backend appPlatform --tofu-dir ~/infra-state/<name>",
                ],
                verify: "hatchery status"),
        ]
    }

    public static var dokkuSteps: [SetupStep] {
        [
            SetupStep(
                title: "Start from a fresh Linux box",
                why: """
                    Dokku takes over ports 80 and 443 and installs its own nginx. Putting it on a \
                    machine that already serves something means the two fight over the same ports.
                    """,
                on: "box",
                commands: [
                    "# Debian or Ubuntu, with a user that can sudo",
                    "sudo apt update && sudo apt upgrade -y",
                ],
                verify: "cat /etc/os-release"),

            SetupStep(
                title: "Install dokku",
                why: """
                    The bootstrap script installs docker, nginx and dokku itself. Check the \
                    current version at dokku.com rather than trusting a tag written here — this \
                    lab runs \(knownGoodDokku).
                    """,
                on: "box",
                commands: [
                    "wget -NP . https://dokku.com/bootstrap.sh",
                    "sudo DOKKU_TAG=v\(knownGoodDokku) bash bootstrap.sh",
                ],
                verify: "dokku version"),

            SetupStep(
                title: "Authorize your SSH key for the dokku user",
                why: """
                    This is what makes `ssh dokku@box <command>` work, and it is the single \
                    thing hatchery depends on. The `dokku` account is not a shell account: it \
                    turns an SSH command into a dokku command. Without the key, every hatchery \
                    action fails with 'Permission denied (publickey)'.
                    """,
                on: "box",
                commands: [
                    "# copy your public key to the box first, then:",
                    "sudo dokku ssh-keys:add <a-name-for-this-key> < /path/to/id_rsa.pub",
                ],
                verify: "ssh dokku@<box> version    # run this from your machine"),

            SetupStep(
                title: "Create a shared docker network, if services need a database",
                why: """
                    Dokku apps get their own network. A service and the postgres it talks to \
                    have to share one, or the app starts and then cannot resolve its database \
                    host. The lab calls this network macworkstack-infra_default.
                    """,
                on: "box",
                commands: ["dokku network:create <network-name>"],
                verify: "dokku network:list"),

            SetupStep(
                title: "Provision the database and its roles",
                why: """
                    hatchery never invents database credentials, because the role has to exist \
                    before the service does — a minted password would produce a service that \
                    cannot connect. Create the database and role first, then give hatchery the \
                    values when it asks.
                    """,
                on: "box",
                commands: [
                    "# the lab runs postgres as a plain dokku app on the shared network,",
                    "# not the postgres plugin. Either works; hatchery only needs the values.",
                    "createdb <db> && createuser <user>",
                ],
                verify: nil),

            SetupStep(
                title: "Optional: grant hatchery the tunnel, one readable line",
                why: """
                    With a locally-managed Cloudflare tunnel, exposing a stack means editing \
                    a root-owned ingress file. hatchery never gets root: it gets exactly one \
                    wrapper with three verbs — add, remove, list — and the sudoers line below \
                    is the whole grant. Set the stack's `exposure` to cloudflare-local and \
                    every clone opens its own front door. Full design: docs/exposure-design.md.
                    """,
                on: "box",
                commands: [
                    "sudo cp Scripts/hatchery-expose /usr/local/bin/hatchery-expose",
                    "sudo chmod 755 /usr/local/bin/hatchery-expose",
                    "echo '<admin-user> ALL=(root) NOPASSWD: /usr/local/bin/hatchery-expose' | sudo tee /etc/sudoers.d/hatchery-expose",
                ],
                verify: "sudo -n hatchery-expose list    # as the admin user"),

            SetupStep(
                title: "Optional: install roost's telemetry collector",
                why: """
                    roost configures boxes and already ships a per-node reporter — load, memory, \
                    disk, power — with launchd and systemd installers. hatchery does not collect \
                    host telemetry and should not: a second set of reporters on the same box \
                    would be two answers to one question. Install roost's, and its boards have \
                    the machine while hatchery has the stacks on it.
                    """,
                on: "here",
                commands: ["roost doctor", "bin/install-node-report.sh   # from the roost repo"],
                verify: "roost fleet"),

            SetupStep(
                title: "Point hatchery at it",
                why: """
                    Everything above is the box. This is the part hatchery does: check the \
                    prerequisites, write the tofu, and create the stack.
                    """,
                on: "here",
                commands: [
                    "hatchery doctor --host dokku@<box>",
                    "hatchery stack new <name> --host dokku@<box> --tofu-dir ~/infra-state/<name>",
                ],
                verify: "hatchery status"),
        ]
    }
}

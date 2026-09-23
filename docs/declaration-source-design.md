# The declaration is the source, and tofu is one output

This design makes the hatchery manifest and the kind files the one description of a stack.
Tofu files become generated output, and nobody edits them by hand.
An audit compares the declaration, the tofu files and the box, and it stops an apply when they disagree.

Status: proposed on 2026-09-16, with Jimmy's decisions on the same day. Not started.

## Why now

On 2026-09-16 we read a full `tofu plan` for the `estate` and `sites` stacks for the first time.
The plan wanted to change the running apps in four ways that nobody intended.

| Drift | Apps | What an apply would do |
|---|---|---|
| A storage mount is not in the `.tf` file | 9 | Unmount the data, for example vault's `/data` and rookery's `/data` |
| The `.tf` file declares port 8080, and the app runs on 80 | 12, vault among them | Pin the wrong port, so each app answers 502 and sign-in stops for every app |
| A post-deploy network is not in the `.tf` file | rookery | Detach rookery from `rookery_default`, where its Postgres is |
| The `https:443` mapping of an app with a certificate is not in the `.tf` file | vault | Send every request to a port that nothing serves |

The last drift caused a real outage of about five minutes.
A `ports:set vault http:80:80` removed the https mapping, and vault answered 502 until we set `http:80:80 https:443:80`.

No apply had run on these stacks, so the other drifts did no damage.
We fixed each drift in hatchery (`fed9fce`, `8a2492c`, `d43fd53`, `a98a983`) and regenerated all 19 declarations.

Each fix closed one instance.
The cause is still there: a stack has two descriptions that people maintain by hand, and nothing compares them.

- The kind file for rookery described its storage in detail, and hatchery read that section nowhere.
- The kind files for vault, pulse and docs said port 8080, and the apps listened on 80.
- The `.tf` files held what `box adopt` measured once, and the box then changed.

## The decision

The manifest and the kind files are the declaration.
Hatchery renders the `.tf` files from the declaration.
Tofu applies what hatchery renders.

We keep tofu as the tool that applies changes.
We do not use tofu as the description, for these reasons:

1. **The facts that matter most are not tofu facts.**
   The boot order in `after`, the status a probe expects, the reason for a mount, and what vault requires of a person,
   are all in the manifest and the kind files.
   HCL has no place for them.
2. **The dokku provider is a weak authority.** Version 1.0.24 is tested up to dokku 0.34.7, and the box runs 0.38.19.
   The provider clears every attribute that a declaration leaves out, and it cannot take variables in `config`.
3. **Some services do not suit tofu.**
   Launchd and systemd jobs, and the `forge` stack, which has no tofu binding, already work through hatchery without a provider.
4. **A person reads a kind file more easily than HCL.**
   This supports the plan to package the estate as a skill that other people can stand up and operate.

## The model

Three layers, and each layer has one owner.

1. **Declaration.** The manifest entry and the kind file. A person edits these. They say what the service must be.
2. **Measurement.** What the box runs:
   `ports:report` (set and detected), `network:report` (both phases), `storage:report`, `certs:report`, `domains:report`.
   `box adopt` reads these today.
3. **Rendering.** The `.tf` files. Hatchery writes them from layer 1. Nobody edits them.

The rules:

- A rendered `.tf` file starts with a header line that says hatchery generated it and names the command that regenerates it.
- The rendering reads only the declaration. It never reads the box.
- `box adopt` writes measurement into the declaration once, when a service joins a stack.
  After that, a difference between the box and the declaration is a finding, not a silent update.
- An https mapping is legal in a declaration only when the service entry says the deployment holds a certificate.
- A kind with `tls: required` is legal in a stack only when the service entry holds a certificate.

## The work

Four phases.
Each phase ships alone and leaves the estate safer than before.
Do them in order.

### Phase 1: the audit compares all three layers

Extend `DeclarationAudit` and `hatchery config audit`.
The audit already has `port-map-drift`, which compares the kind file with the box.

Add these finding codes:

- `storage-drift`: a mount on the box, the declaration or the `.tf` file is missing from another layer.
- `network-drift`: a network phase differs between the layers.
- `port-map-drift`: extend the existing code to every mapping, not only http, and to the `.tf` file.
- `certificate-drift`: the box has SSL enabled and the declaration does not say so, or the reverse.
- `domain-drift`: a domain differs between the layers.
- `render-drift`: the `.tf` file on disk differs from what the renderer writes for the same declaration.

Acceptance:

- With the fake executor, each code has a test that produces it and a test that proves a clean service produces nothing.
- Run read-only against the opi, the audit reports zero findings for `estate` and `sites` as committed at `afa4c83`.
- Remove the `storage` block from a copy of `estate/vault.tf` in a temporary directory. The audit reports `storage-drift` for vault.
- `hatchery config audit` exits with a non-zero status when any finding exists.

### Phase 2: the declaration carries storage, networks, ports and TLS

The kind file gains fields that the renderer uses, so it stops being documentation only.

- `storage` stays in its present shape. The renderer reads it.
- `networks`: `postCreate` and `postDeploy`, each optional.
- `ports`: a list of `scheme`, `host` and `container`.
  The present `port` field stays as a short form for one http mapping.
- `tls`: `required`, `optional` or `none`. This is a fact about the software.
  A server that refuses plain HTTP is `required`. vault serves plain HTTP behind nginx, so vault is `optional`.

The service entry in the manifest gains one field, because a certificate belongs to one deployment.

- `certificate`: the hostnames the deployment's certificate covers, or absent.
  vault on the opi holds one for `vault`, `s3` and `forgejo`, because the LAN resolver sends Macs on the LAN to the box directly.
  A vault behind Cloudflare only needs none.

Acceptance:

- A service with an https port and no `certificate` fails validation with a message that names the risk.
- A service whose kind says `tls: required` and that has no `certificate` fails validation.
- Every kind file in `~/infra-state/estate/kinds` and `~/infra-state/sites/kinds` loads, and each one round-trips through the loader unchanged.
- `box adopt` fills the new fields from measurement for a new service.

### Phase 3: hatchery renders every `.tf` file

Add `hatchery render <stack>` and `hatchery render <stack> --check`.

- `render` writes every dokku `.tf` file of the stack from the declaration, with the generated header.
- The scope is the `estate` and `sites` stacks.
  The lab stacks `mwserver-tf` and `mwlab-2` are out of scope, because they may be taken down and rebuilt.
- `--check` writes nothing. It exits with a non-zero status and names each file that differs.
- `box adopt --replace` and `service new` call the same renderer, so there is one code path that writes HCL.

Acceptance:

- For `estate` and `sites` at `afa4c83`, `render --check` reports no difference.
  Where the only difference is the new header, the phase commits the regenerated files once and `--check` then passes.
- A test renders each backend's declaration from a fixture manifest and compares the text byte for byte.
- A forge CI job in `infra-state` runs `render --check` on every push.
  The job runs only `render --check`. It holds no SSH key and never reads the box.
- The box audit from phase 1 runs in two places, and CI is not one of them:
  hatchery publishes its findings to pulse on its present schedule, and the phase 4 guard runs it before an apply.

### Phase 4: an apply refuses a drifted stack

`hatchery deploy --apply` and any hatchery path that runs `tofu apply` run the audit and `render --check` first.
Either failure stops the apply and prints the findings.

The guard also reads the plan.
It refuses a plan that removes a storage mount, clears a network phase, or removes a port mapping, unless the declaration changed in the same commit.

Acceptance:

- With a fake tofu that prints a plan with `- storage`, the guard refuses and names the app and the mount.
- With a fake tofu that prints only the import fill-in (`+ checks`, `+ config`, `+ deploy`, `+ ports` that match the box), the guard allows the apply.

## What this does not do

- It does not replace tofu or the dokku provider.
- It does not move jobs, the `forge` stack or bare containers into tofu.
- It does not change MWServer or its lab stacks `mwserver-tf` and `mwlab-2`.
  They were authored with `service new` and they are clean, and they may be taken down and rebuilt.
- It does not apply anything to the estate.

## Rules for a team that builds this

A rookery team can build phases 1 to 3 without access to anything live except read-only box queries.

- Work on a branch of `jimmy/hatchery` on the forge. One branch per phase.
- Invoke the `house-style` skill before you write code or prose, and give this instruction to every sub-agent.
- Tests use the fake command executor that `AdoptTests` uses. A test never opens an SSH connection.
- Read-only commands against `dokku@192.168.0.103` are allowed for acceptance:
  `ports:report`, `network:report`, `storage:report`, `certs:report`, `domains:report`, `apps:list`.
- Never write to `~/infra-state`. Copy files to a temporary directory for tests.
- Each phase returns the branch name, the test count before and after, and the output of each acceptance check.

### Gates

The gates below are the rules that a person or a check must pass before an action.
Rookery reads this block when it opens the assignment, after its gates feature lands. The format is `docs/spec-gates.md` in `jimmy/rookery`.
Until then, a seat reads the block as rules and a person enforces it.

- `before` names what the gate stops: command patterns, `write <path>`, or `milestone <name>`.
- `refuse` stops the action with no approval possible, and gives the reason.
- `check` is a command that must exit with status 0. Rookery runs it before it asks anyone.
- `requires` lists what the approver confirms. The approver reads each line and rules on it.
- `approver` is a person, or `review` for a review seat.

```gates
- before: tofu apply | tofu import | ports:set | ports:clear | git:from-image | config:set
  refuse: "These change the box. The 2026-09-16 vault outage came from one ports:set."

- before: write ~/infra-state
  refuse: "Tests copy the files to a temporary directory."

- before: milestone ready-to-merge
  phase: 1, 2, 3
  approver: review
  check: swift test
  requires:
    - "No test opens an SSH connection."
    - "The report gives the branch, the test count before and after, and each acceptance output."

- before: milestone ready-to-merge
  phase: 4
  approver: jimmy
  check: swift test
  requires:
    - "The guard refuses the storage, network and port plans in the acceptance tests."
    - "The guard allows a plan that only fills in imported attributes."
    - "The report gives the branch, the test count before and after, and each acceptance output."
```

## Decisions

Jimmy ruled on these on 2026-09-16.

1. **TLS is both a kind fact and a deployment fact.**
   The kind says whether the software needs TLS, and the service entry says whether the deployment holds a certificate.
2. **Render covers `estate` and `sites` only.** The lab stacks stay as they are, because they may be taken down and rebuilt.
3. **CI runs only `render --check`.** The box audit publishes to pulse and runs in the apply guard.
4. **`requires` lines are free text for now.** A person or a review seat reads them. A criterion that a named role judges is a later step.

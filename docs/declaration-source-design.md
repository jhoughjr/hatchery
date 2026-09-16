# The declaration is the source, and tofu is one output

This design makes the hatchery manifest and the kind files the one description of a stack.
Tofu files become generated output, and nobody edits them by hand.
An audit compares the declaration, the tofu files and the box, and it stops an apply when they disagree.

Status: proposed on 2026-09-16. Not started.

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
- An https mapping is legal in a declaration only when the kind or the service says the app holds a certificate.

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

### Phase 2: the kind file declares storage, networks, ports and certificates

The kind file gains fields that the renderer uses, so it stops being documentation only.

- `storage` stays in its present shape. The renderer reads it.
- `networks`: `postCreate` and `postDeploy`, each optional.
- `ports`: a list of `scheme`, `host` and `container`. The present `port` field stays as a short form for one http mapping.
- `certificate`: true when the app holds a certificate.

Acceptance:

- A kind file with an https port and no `certificate: true` fails `hatchery kind add` with a message that names the risk.
- Every kind file in `~/infra-state/estate/kinds` and `~/infra-state/sites/kinds` loads, and each one round-trips through the loader unchanged.
- `box adopt` fills the new fields from measurement for a new service.

### Phase 3: hatchery renders every `.tf` file

Add `hatchery render <stack>` and `hatchery render <stack> --check`.

- `render` writes every dokku `.tf` file of the stack from the declaration, with the generated header.
- `--check` writes nothing. It exits with a non-zero status and names each file that differs.
- `box adopt --replace` and `service new` call the same renderer, so there is one code path that writes HCL.

Acceptance:

- For `estate` and `sites` at `afa4c83`, `render --check` reports no difference.
  Where the only difference is the new header, the phase commits the regenerated files once and `--check` then passes.
- A test renders each backend's declaration from a fixture manifest and compares the text byte for byte.
- A forge CI job in `infra-state` runs `render --check` on every push.

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
  They were authored with `service new` and they are clean.
  Phase 3 renders them only after Jimmy approves.
- It does not apply anything to the estate.

## Rules for a team that builds this

A rookery team can build phases 1 to 3 without access to anything live except read-only box queries.

- Work on a branch of `jimmy/hatchery` on the forge. One branch per phase. Merge only after review.
- Invoke the `house-style` skill before you write code or prose, and give this instruction to every sub-agent.
- Tests use the fake command executor that `AdoptTests` uses. A test never opens an SSH connection.
- Read-only commands against `dokku@192.168.0.103` are allowed for acceptance:
  `ports:report`, `network:report`, `storage:report`, `certs:report`, `domains:report`, `apps:list`.
- Never run `tofu apply`, `tofu import`, `ports:set`, `ports:clear`, `git:from-image`, `config:set`, or any command that changes the box.
  The 2026-09-16 outage came from one `ports:set`.
- Never write to `~/infra-state`. Copy files to a temporary directory for tests.
- Phase 4 changes the path that applies to the estate. Jimmy reviews it before it merges.
- Each phase returns the branch name, the test count before and after, and the output of each acceptance check.

## Open questions for Jimmy

1. Should `certificate` in phase 2 be a kind fact or a service fact? A kind describes an image, and a certificate belongs to one deployment of it.
2. Should phase 3 render the lab stacks `mwserver-tf` and `mwlab-2`, or leave them as `service new` wrote them?
3. Should the forge CI job in phase 3 also run the phase 1 audit against the box, or only `render --check`, which needs no box access?

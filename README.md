# hatchery

Configure, deploy and monitor MWServer stacks — self-hosted or cloud.

MWServer is the first target, but nothing in the model is MWServer-specific: service
kinds and their environment contracts are data, so other services drop in without
changing the core.

## Status

Early, but the loop closes: configure, deploy, monitor, all against the live lab.

Working today:

```sh
hatchery config validate <config.json> --service mwserver --backend dokku
hatchery stack list --manifest hatchery.json
hatchery status --manifest hatchery.json
hatchery config audit --manifest hatchery.json
hatchery config sync <stack> --manifest hatchery.json
hatchery service new <stack> <name> --kind <kind> --domain <d> --image <ref>
hatchery deploy <stack> <service> --image <ref>
hatchery up|down|restart <stack>
hatchery serve
```

### Finding the manifest

A manifest lives next to the config files it names, because `configFile` resolves relative to
the manifest's own directory — which is rarely the directory you are standing in. So a command
with no `--manifest` looks in three places, in order:

1. `./hatchery.json`
2. `$HATCHERY_MANIFEST`
3. `~/.config/hatchery/hatchery.json`

An explicitly passed `--manifest` is used exactly as given and never falls back, because
second-guessing it would hide a typo. Finding nothing lists everywhere it looked.

## From nothing to something

There was no path from an empty directory to a running service without writing HCL yourself —
`service new` could only add to a configuration that already existed, and the lab's own was
written by hand. `stack new` closes that:

```sh
hatchery stack new newlab --host dokku@192.168.0.103 --tofu-dir ~/infra-state/newlab
hatchery service new newlab paylab2 --kind payment-gateway \
  --domain paylab2.opi --image payment-gateway:arm64-6be9967
hatchery config set newlab paylab2 DATABASE_HOST=... DATABASE_USER=... DATABASE_PASSWORD=...
```

It writes `versions.tf`, `providers.tf` and `variables.tf`, runs `tofu init`, and records the
stack in a manifest beside them. An existing configuration is never written over.

The same three steps are a wizard in the browser, which is the point: the dashboard now starts
from an empty state offering to create a stack, and walks through service and secrets without
you touching a file. `hatchery serve` no longer needs a manifest to start — requiring one would
mean needing a manifest to reach the tool that writes your first manifest.

A key hatchery cannot supply is **left out of the config entirely** rather than written as `""`.
The dokku provider rejects a zero-length config value outright (`string length must be at least
1`), so an empty placeholder makes a brand-new stack fail to plan at the worst possible moment.

## The dashboard

`hatchery serve` puts the same operations behind a browser:

```
$ hatchery serve
hatchery serving http://127.0.0.1:7878
  bound to loopback — not reachable from the LAN
  from elsewhere: ssh -L 7878:localhost:7878 <this-host>
```

One self-contained page, no build step, no asset pipeline — the markup is a string in the
binary, so the page cannot drift from the code serving it. It polls status every ten seconds
and follows the browser's light or dark theme.

### It does not run inside what it manages

hatchery manages deployments, so it deliberately is not one. Running it as an app on the box it
administers means a restart of that stack kills the tool mid-action, and the moment you most
need it — box wedged, apps down — is exactly when it would not be there. It is a local process.
There is no Dockerfile here on purpose.

### Confirmation is enforced on the server

The browser dialog that asks you to type a service's name is a convenience. It is not the
control, because anything can post to the endpoint. So every mutating request carries the name
of what it is about to change, and the server refuses a mismatch:

```
$ curl -XPOST localhost:7878/api/lifecycle -d '{"stack":"mwlab","service":"mwlab","action":"restart","confirm":"wrong"}'
{"error":"confirmation did not match; expected 'mwlab' to change it"}
```

Applying a deploy to a **production** stack is refused outright and stays on the CLI. The
browser is the wrong place for the one action with no undo.

### Binding and tokens

The default bind is `127.0.0.1`, which nothing off the machine can reach, so no token is needed
to get started. Binding anything else **requires** `--token` and is refused without one — this
process holds SSH access to every stack it manages, so an open port is an open shell by proxy.

```sh
hatchery serve                                   # loopback, no token
hatchery serve --bind 0.0.0.0 --token "$(openssl rand -base64 24)"
```

The token is compared without an early exit, so how long the check takes says nothing about how
much of it matched.

`service new` authors a service that does not exist yet — the declaration, its image variable,
its config, and its manifest entry:

```
  write paylab2.tf
  append to variables.tf
  write paylab2.config.json
    APP_URL                  composed
    DATABASE_DB              composed
    DATABASE_PASSWORD        NEEDS VALUE
    GATEWAY_ADMIN_TOKEN      minted (32 bytes)
    KEYPAIR_JWKS             minted (RSA-2048, RS512)

  3 key(s) need values before this will boot:
    DATABASE_PASSWORD — the database role already exists; a new password would not connect
```

### Where secrets come from

Until now they came from nowhere: the values were set by hand on the box once, and everything
since — `pull-mwlab-config.sh`, then `config sync` — copied them back down. That works for a
service that already runs and has nothing to say about one that does not.

So each declared key gets an origin, and the distinction is the whole point:

| Origin | Meaning |
| --- | --- |
| `minted` | hatchery generated it; nothing else has a claim on the value |
| `shared` | copied from a sibling, because the value has to match across the stack |
| `composed` | derived from what the manifest already declares |
| `NEEDS VALUE` | only a person or a third party has it |

Three rules, each from the lab rather than from a preference. A **signing key is shared** when
the stack already has one — the services verify each other's tokens, so a fresh key is a key
nothing accepts — and minted only when there is no sibling to share with. **Database credentials
are never invented**, because the role exists before the service does; a minted password produces
a service that cannot connect. **Third-party credentials are never invented**, and saying so is
more useful than a placeholder that looks filled in.

`KEYPAIR_JWKS` is minted as RSA-2048/RS512 rather than an elliptic curve, because that is what
the live keys are. CryptoKit has no RSA, so hatchery shells out to `openssl` and reads the
PKCS#1 structure directly — nine DER integers that are exactly a private RSA JWK's fields.

Not everything is an environment variable. Stripe credentials for the lab live in the database,
so the origins above cover the config half of the problem and not the whole of it.

`config audit` checks what each service is *running with* rather than what a file claims:

```
mwlab  [dokku]
  mwlab: 21 keys, 0 error(s), 0 warning(s)
  paylab: 10 keys, 0 error(s), 0 warning(s)
  comlab: 9 keys, 0 error(s), 0 warning(s)
```

The distinction matters. `dokku config:set` merges rather than replaces, so a key set by hand
never reaches the declared file and nothing reports the difference. The lab had exactly that:
three keys were live on the app and absent from the file, and only reading the app found them.

`status` asks each service what it says about itself and composes the stack:

```
mwlab  [dokku]  responding
  mwlab                   responding   88ms    no health endpoint
  paylab                  responding   85ms    HTTP 200, no readiness report
  comlab                  responding   85ms    HTTP 200, no readiness report
```

The states run worst to best: `unreachable`, `degraded`, `responding`, `ready`. A stack
reports the worst state among its services. `responding` means the service answered without
a readiness report, which is what an older image looks like — better than silence, worse than
an answer we can read. The exit code fails on `unreachable` or `degraded` only, so an image
without a health route does not fail a script.

Two details that came from the lab rather than from a document. A dokku service is probed at
the box with a `Host` header, because a lab vhost usually has no public DNS record. And the
readiness path follows the estate convention rather than a path hatchery invented: `/health`
for everything the shared microservice template generates, `/healthz` for gsx-gateway.

`deploy` moves a service to a new image *through the declaration that owns it*:

```
mwlab: mwlab_image
  mhehmsoth/mwserver2:arm64-0630f31-health -> mwserver2:arm64-abc1234
  manifest updated to mwserver2:arm64-abc1234
  tofu plan: changes pending
  ...
  nothing applied; re-run with --apply --yes
```

This is the part that most wants to be a shortcut and most must not be. The image is a
tofu-declared attribute, so setting it at the box would leave the declaration stale and
`tofu plan` permanently dirty — the same two-owners mistake `config sync` exists to undo. So
`deploy` writes the tofu variable, runs `tofu plan -detailed-exitcode`, and shows what that
would do. Nothing is applied unless `--apply --yes` says so.

Three things it will not do quietly:

- If the plan stops evaluating after the write, the variables file is **put back** and the
  failure is reported. A configuration that no longer parses blocks every other change to
  the stack, which is worse than an undeployed image.
- The manifest moves only *after* tofu agrees the write evaluates. Writing it first would
  leave the declaration claiming an image that never planned.
- If the manifest and the tofu variable already disagreed, it says so before overwriting —
  that means someone moved the image outside hatchery.

The edit to `variables.tf` is textual rather than a parse-and-reprint, because the comments in
that file explain how each image was built and where it came from. Exactly one line changes.

## Why this exists

A stack's configuration currently lives in at least five places that disagree with each
other: a DO app-spec template, gitignored dokku config dumps, `.auto.tfvars.json` files,
the DO console, and a password manager. Nothing reconciles them, and nothing tells you
whether a deployed app is actually *serving* — only whether its last deploy succeeded.

`hatchery config validate` is the first answer to that. It encodes the environment
contract per service and backend, and it already catches a real latent failure: the
2026-07-28 cutover retired the discrete `DATABASE_HOST` / `DATABASE_PORT` / … keys on
App Platform, so a lab config promoted to production as-is would not boot.

## Design

### Layering

All logic lives in `HatcheryKit`. Frontends are thin, so everything of consequence is
reachable by tests. A future macOS GUI is a view layer over the same types — it does not
get its own logic.

### State ownership

hatchery owns the *declaration* — a committable manifest recording which stacks should
exist, which services they run, and where each service's config sidecar lives.

It deliberately does not own live state. What is actually running is queried from the
backend on demand. The two are kept apart because the alternative has already bitten us:
the mwlab OpenTofu state is local-only and unbacked-up, was once recovered from an
ephemeral scratch directory, and losing it would orphan three running apps.

Secrets live in sidecar files that are never committed. The manifest records *where*
config lives, never what it contains.

### Backends

| Backend | Target |
| --- | --- |
| `dokku` | Self-hosted — the opi box and the Raspberry Pi fleet, over SSH |
| `appPlatform` | DigitalOcean App Platform — the production tenant plane |

The two are not interchangeable. App Platform dropped discrete `DATABASE_*` keys in the
connection-string cutover; the lab still runs pre-cutover images, so the same keys remain
legal there. `EnvContract` encodes that difference rather than pretending one contract
fits both.

Neither AWS nor App Platform is implemented as an *action* backend yet — `EnvContract` knows
App Platform's config contract, but reading live config, lifecycle, and deploy are all dokku-only
today. AWS is wanted ahead of DigitalOcean; both are wanted eventually.

They arrive as implementations behind a protocol rather than as branches inside each verb, so a
new provider is a new file rather than an edit to seven of them.

### Relationship to roost

**roost owns machines. hatchery owns stacks.**

roost handles the host plane: the box itself, dokku, the Cloudflare tunnel, route
publishing, node telemetry. It never learns what MWServer is.

hatchery handles the application plane: the stack definition, the environment contract,
images, database wiring, lifecycle, application-level health.

When hatchery needs a URL to exist it asks roost (`roost route <sub>`) rather than
reimplementing route publishing. hatchery can be installed as `roost-hatch` so roost's
plugin dispatch picks it up.

### What hatchery does not rebuild

`MacWorkStack-infra` already solves local dev (`compose.yaml` + `db/init/`) and tenant
creation (`new-tenant.sh` — key generation, database and pool creation, spec render,
validate, create, poll). hatchery shells out to those rather than redesigning them.

Two deploy behaviours it must respect:

- An env-only spec update reuses the already-resolved image digest and does **not**
  re-pull the tag. Only `doctl apps create-deployment` re-resolves.
- Verify a deployment by digest, never by tag.

## Development

```sh
swift build
swift test
```

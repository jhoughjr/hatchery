# Exposure: the front door is part of the clone

A stack that runs but cannot be reached is not deployed — it is rehearsing. The clone
pipeline now delivers apps, config, keys and databases with zero keys left to a person;
this design extends the same contract to reachability. **Exposure is part of one click.**

## What the lab actually is (measured 2026-08-09)

- `mwlab.jimmyhoughjr.net` reaches the internet through a **locally-managed Cloudflare
  Tunnel**: `cloudflared` runs on the opi as root, `tunnel run a4f21cc2-…`, ingress rules
  in `/root/.cloudflared/config.yml`. DNS for each exposed hostname is a CNAME to the
  tunnel, creatable with `cloudflared tunnel route dns` — no API token involved.
- The clone `mwlab-2` has **no front door**: no DNS record, no ingress rule, and nothing
  on the LAN serves DNS for `.opi` names (they work only via Host header or a client's
  hosts file).
- The admin channel (`jimmy@opi`, the `db_admin` pattern) has **no passwordless sudo**,
  and the tunnel's config is root-owned. Whatever exposure does on this box, it must not
  require handing the admin channel general root.

Two truths fall out. First, exposure is **provider-shaped**: a Cloudflare tunnel, a LAN
resolver, and DigitalOcean's own domains are different machines with different capabilities
and different credentials. Second, exposure is **granted, not assumed**: each provider
declares what capability it needs (a wrapper the operator installs, a token in the
environment) and degrades to an honest plan-screen line when the grant is absent — the
same way database provisioning refuses rather than guesses.

## The model

`ExposureProvider`, the same pattern as `ServiceProvider` and the database transports:

```swift
public protocol ExposureProvider: Sendable {
    var name: String { get }                       // "cloudflare-local", "lan-dns", …
    /// What would happen to each domain, for the plan screen. Never acts.
    func plan(domains: [String], stack: StackSpec) async -> [ExposurePlan]
    /// Assert the plan, idempotently. Narrates through the job transcript.
    func expose(_ plans: [ExposurePlan], stack: StackSpec,
                onProgress: @Sendable (String) -> Void) async throws
    /// The symmetric teardown, called by destroy.
    func withdraw(domains: [String], stack: StackSpec,
                  onProgress: @Sendable (String) -> Void) async throws
}

public struct ExposurePlan: Sendable, Equatable {
    public let domain: String
    /// One sentence: "tunnel ingress + DNS via a4f21cc2" / "will not resolve anywhere".
    public let action: String
    /// False when the grant for this provider is missing; the plan still shows the line.
    public let actionable: Bool
}
```

Selection is a per-stack setting, `exposure`, declared by the backend like `db_admin` is —
stored in the manifest (never a secret), carried by clones, defaulting per backend:
`platform` for App Platform (the platform already owns domains), `none` for dokku until the
operator picks one.

### Where it hooks

Exactly where the database did:

- **Plan screen** (CLI + wizard): one line per domain, from `plan(domains:)` — beside the
  `db` lines. An unreachable future is a warning *before* the create click.
- **Jobs**: `expose` runs as a narrated phase of the clone/apply job, after tofu's apply
  succeeds (the app must exist before its door opens). `withdraw` runs inside the destroy
  job before the manifest forgets the stack.
- **Convergence**: every step asserts. Re-running exposure on an exposed stack changes
  nothing and says so; a half-finished exposure re-run completes.
- **Zero-keys invariant**: the plan's exposure lines are promises. Create either delivers
  them or the job transcript says exactly which grant was missing and how to make it.

## Providers

### `cloudflare-local` — the lab, first implementation

For locally-managed tunnels (ingress in a root-owned `config.yml`). The security boundary
is a **root-owned wrapper script**, not general sudo:

- Hatchery ships `Scripts/hatchery-expose` (installed once on the box, owned by root,
  mode 755). It accepts exactly three verbs:
  - `add <hostname> <target-port-or-service>` — insert an ingress rule above the
    catch-all 404, skip if present, `systemctl restart cloudflared`, then
    `cloudflared tunnel route dns <tunnel> <hostname>`.
  - `remove <hostname>` — delete the rule if present, restart. (DNS records are left; a
    dangling CNAME to the tunnel 404s harmlessly and deleting DNS needs an API token this
    provider deliberately does not have.)
  - `list` — print the current ingress hostnames, for the plan.
- The operator grants one sudoers line — the whole capability, nothing else:

  ```
  jimmy ALL=(root) NOPASSWD: /usr/local/bin/hatchery-expose
  ```

- The provider's setting is `exposure_admin` (an ssh target, defaulting to `db_admin`'s
  value). Absent grant → every plan line says
  `not actionable: install hatchery-expose and the sudoers grant on <host>`.

Ingress targets: dokku's nginx on the box answers by Host header, so every rule is
`hostname: <domain>` → `service: http://localhost:80` with `originRequest.httpHostHeader`
set to the same domain. One rule shape for every app.

### `cloudflare-api` — elsewhere, and the lab's eventual migration

For **remotely-managed** tunnels (ingress lives in Cloudflare's control plane): everything
via API — tunnel configuration PUT for ingress, DNS records API for CNAMEs, real deletes
on withdraw. Credential is `CF_API_TOKEN` from the environment at action time, the exact
pattern `DIGITALOCEAN_TOKEN` uses: never stored, checked by `doctor`. This is the answer
for machines that cannot ssh anywhere, and the migration target if the lab's tunnel ever
moves to remote management.

### `lan-dns`

Asserts `A <domain> → <box>` records on a LAN resolver (dnsmasq/Pi-hole) through the admin
channel, so `.opi` names resolve for every device using it. Until the lab runs one, the
provider exists to say honestly: `no LAN resolver configured; .opi names resolve only via
hosts files`.

### `platform`

Cloud backends where the platform assigns domains. `plan` reports what the platform will
do; `expose`/`withdraw` are no-ops with narration. Keeps the plan screen uniform across
backends instead of special-casing.

### `none`

Today, said out loud: every domain gets `will not resolve anywhere — pick an exposure
provider in the stack's settings`.

## Rollout

1. **Model + plan lines** — protocol, `exposure` setting, per-domain lines on both plan
   screens, `none`/`platform` behaviors. Pure display; no new capability needed.
2. **`cloudflare-local`** — the wrapper script, its installer note in onboarding, the
   provider, expose phase in clone/apply jobs. The lab's one-click becomes reachable.
3. **Withdraw on destroy** + wizard surfacing of not-actionable grants.
4. **`cloudflare-api`**, then `lan-dns` when a LAN resolver exists.

## What this deliberately does not do

- No TLS management on the box: Cloudflare terminates at the edge for tunnel traffic, which
  is the lab's model today. Origin certs are a later concern with the same provider shape.
- No exposure of production stacks from the browser: the same line every other write draws.
- No secrets in the manifest, ever: tokens live in the environment; the wrapper's power
  lives in one sudoers line the operator can read in full.
